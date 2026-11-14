import AppKit

/// Runs the rain easter egg: 9 quick clicks on Gooby start a drizzle that fills the
/// screen "bucket" with continuous (shallow-water) water over 4.5 minutes. Tilting the MacBook sloshes
/// the water around; shaking throws it. Water blocks clicks underneath it; rain does not.
/// Fail-safes: ⌃⌥⌘ Esc (global, no permission), `pkill -x Gooby`, and a 300 s hard cap.
@MainActor
final class StormController {
    static let frameInterval: TimeInterval = 1.0 / 60.0
    /// How far Gooby's canvas sits below the waterline when floating.
    static let floatSink: CGFloat = 20
    /// Gooby's float height follows the surface with this smoothing per frame.
    static let floatSmoothing: CGFloat = 0.2

    private(set) var model: StormModel?
    private(set) var water: ShallowWaterSim?
    private(set) var tilt = TiltInput()
    /// Fraction of the remaining shortfall added per rain landing frame (smooth catch-up).
    static let fillCatchUp: Float = 0.25
    private let accelerometer = AccelerometerReader()
    /// False on Macs without the motion sensor (the water then just falls straight down).
    private(set) var hasAccelerometer = false
    private var streak = ClickStreakDetector()
    private let host: GoobyWindowHost
    private weak var follower: TerminalFollower?
    private let hotKey = FailSafeHotKey()
    private let clock: () -> TimeInterval
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var lastStep: TimeInterval = 0
    private var floatY: CGFloat?
    private(set) var screenFrame: CGRect = .zero
    private(set) var waterPanel: StormOverlayPanel?
    private(set) var rainPanel: StormOverlayPanel?
    private var waterView: WaterView?
    private var rainView: RainView?

    var isActive: Bool { model?.isActive ?? false }
    var isFailSafeArmed: Bool { hotKey.isRegistered }

    init(
        host: GoobyWindowHost,
        follower: TerminalFollower?,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.host = host
        self.follower = follower
        self.clock = clock
    }

    // MARK: Input

    func handleCharacterClick() {
        let completedStreak = streak.register(at: clock())
        if isActive {
            model?.bail()
            if completedStreak { model?.fakeOut() }
            lastStep = 0
            render()
        } else if completedStreak {
            start()
        }
    }

    /// Feeds an accelerometer sample (also used by tests to simulate tilting).
    func ingest(_ sample: AccelSample) {
        tilt.ingest(sample)
    }

    // MARK: Lifecycle

    func start(on screen: NSScreen? = nil) {
        guard !isActive else { return }
        let target = screen ?? host.panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = target?.frame, frame.width > 0, frame.height > 0 else { return }
        screenFrame = frame

        var model = StormModel(screenHeight: frame.height)
        model.start()
        self.model = model
        water = ShallowWaterSim(width: Float(frame.width), height: Float(frame.height))
        tilt = TiltInput()
        floatY = nil

        let water = StormOverlayPanel(frame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1),
                                      level: StormLevels.water, clickThrough: false)
        let waterView = WaterView(frame: CGRect(x: 0, y: 0, width: frame.width, height: 1))
        water.contentView = waterView
        let rain = StormOverlayPanel(frame: frame, level: StormLevels.rain, clickThrough: true)
        let rainView = RainView(frame: CGRect(origin: .zero, size: frame.size))
        rain.contentView = rainView
        rain.orderFrontRegardless()
        waterPanel = water
        rainPanel = rain
        self.waterView = waterView
        self.rainView = rainView

        accelerometer.onSample = { [weak self] sample in self?.ingest(sample) }
        hasAccelerometer = accelerometer.start()
        host.setStormMode(true)
        follower?.originAdjuster = { [weak self] raw in self?.adjustGoobyOrigin(raw) ?? raw }
        hotKey.register { [weak self] in self?.stop() }

        lastTick = clock()
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        render()
    }

    /// Fail-safe and normal end: removes every storm window immediately.
    func stop() {
        timer?.invalidate()
        timer = nil
        hotKey.unregister()
        accelerometer.stop()
        accelerometer.onSample = nil
        tilt = TiltInput()
        rainView?.clear()
        waterPanel?.orderOut(nil)
        waterPanel?.close()
        rainPanel?.orderOut(nil)
        rainPanel?.close()
        waterPanel = nil
        rainPanel = nil
        waterView = nil
        rainView = nil
        model = nil
        water = nil
        floatY = nil
        streak.reset()
        host.setStormMode(false)
        follower?.originAdjuster = nil
        follower?.tick()
    }

    // MARK: Frame loop

    /// Advances the storm by `dt` seconds (also used directly by tests).
    func advance(by dt: TimeInterval) {
        guard var model else { return }
        lastStep = dt
        model.tick(dt)
        self.model = model
        if !model.isActive {
            stop()
            return
        }
        water?.step(dt, gravity: tilt.screenGravity)
        render()
    }

    private func step() {
        let now = clock()
        let dt = min(max(now - lastTick, 0), 0.25)   // clamp long stalls (sleep, debugger)
        lastTick = now
        advance(by: dt)
    }

    /// Screen area the water should cover now (pt²).
    var targetWaterArea: CGFloat {
        CGFloat(model?.level ?? 0) * screenFrame.width * screenFrame.height
    }

    /// Screen area the water covers now (pt²).
    var visibleWaterArea: CGFloat { CGFloat(water?.volume ?? 0) }

    /// Water surface height (pt above the screen bottom) at a screen-relative x.
    func surfaceHeight(atX x: CGFloat) -> CGFloat {
        CGFloat(water?.surface(atX: Float(x)) ?? 0)
    }

    /// Top of the water anywhere on screen (pt above the screen bottom).
    var waterTopHeight: CGFloat { CGFloat(water?.maxSurface ?? 0) }

    private func render() {
        guard let model, var water, let waterPanel, let rainView else { return }

        // Fill control by exact water volume, so the 4.5-minute schedule holds.
        // Rain feeds the bucket: each landing drop adds a small bump where it hits
        // (it spreads out as ripples). Draining/bailing removes water evenly.
        let shortfall = Float(targetWaterArea) - water.volume
        if shortfall > 0 {
            let landings = rainView.model.splashes.filter { $0.age == 0 }
            if !landings.isEmpty {
                let each = shortfall * Self.fillCatchUp / Float(landings.count)
                for splash in landings { water.addVolume(each, atX: Float(splash.x)) }
            } else if !model.isRaining {
                water.addVolumeEvenly(shortfall * Self.fillCatchUp)
            }
        } else if shortfall < 0 {
            water.removeVolume(-shortfall)
        }
        if model.level >= 0.999 { water.addVolumeEvenly(max(0, Float(screenFrame.width * screenFrame.height) - water.volume)) }
        self.water = water

        let full = model.level >= 0.999
        let top = full ? screenFrame.height : min(screenFrame.height, waterTopHeight + 4)
        if top >= 1 {
            let frame = CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: top)
            if waterPanel.frame != frame { waterPanel.setFrame(frame, display: false) }
            if !waterPanel.isVisible { waterPanel.orderFrontRegardless() }
            waterView?.frame = CGRect(origin: .zero, size: frame.size)
            let snapshot = water
            waterView?.update(width: frame.width) { x in full ? frame.height : CGFloat(snapshot.surface(atX: Float(x))) }
        } else if waterPanel.isVisible {
            waterPanel.orderOut(nil)
        }

        // Rain covers the whole screen; drops land on the water surface and splash.
        if rainView.frame.size != screenFrame.size {
            rainView.frame = CGRect(origin: .zero, size: screenFrame.size)
        }
        let snapshot = water
        rainView.step(lastStep, floor: { x in CGFloat(snapshot.surface(atX: Float(x))) }, raining: model.isRaining)
        follower?.tick()
    }

    /// While the storm runs Gooby always stays visible and floats on the water under him.
    func adjustGoobyOrigin(_ raw: CGPoint?) -> CGPoint? {
        guard isActive else { return raw }
        let base = raw ?? host.panel?.frame.origin ?? CGPoint(x: screenFrame.midX, y: screenFrame.minY)
        let centerX = base.x + GoobyVisualMetrics.canvasSize.width / 2 - screenFrame.minX
        let target = screenFrame.minY + surfaceHeight(atX: centerX) - Self.floatSink
        let smoothed = floatY.map { $0 + (target - $0) * Self.floatSmoothing } ?? target
        floatY = smoothed
        let maxY = screenFrame.maxY - GoobyVisualMetrics.canvasSize.height
        return CGPoint(x: base.x, y: min(max(base.y, smoothed), maxY))
    }
}
