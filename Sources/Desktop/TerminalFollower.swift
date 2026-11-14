import AppKit

/// Something that can show Gooby at an origin or hide it.
@MainActor
protocol GoobyPresenter: AnyObject {
    /// `animated`: glide there (the user switched windows); otherwise move at once
    /// (following a window the user is dragging).
    func present(at origin: CGPoint, animated: Bool)
    func conceal()
    /// The project of the Claude chat Gooby sits beside (hover tag), nil if unknown.
    func showProject(_ name: String?)
    /// No Claude chat in front: peek around a screen edge from `origin`.
    func peek(at origin: CGPoint, edge: PeekEdge, animated: Bool)
}

extension GoobyPresenter {
    func present(at origin: CGPoint) { present(at: origin, animated: false) }
    func showProject(_ name: String?) {}
    func peek(at origin: CGPoint, edge: PeekEdge, animated: Bool) { conceal() }
}

/// Polls (macOS posts no "window moved" event for other apps) and keeps Gooby beside
/// the front Terminal window when Claude Code runs in its front tab; hides Gooby otherwise.
@MainActor
final class TerminalFollower {
    struct Environment {
        var frontmost: @MainActor () -> (bundleID: String?, pid: pid_t?)
        var windows: @MainActor () -> [WindowSnapshot]
        var screens: @MainActor () -> [CGRect]
        var primaryScreenHeight: @MainActor () -> CGFloat
        /// Is Claude running in the front tab? Called every tick with the front window's
        /// number; implementations sample slowly (see ClaudePresence). Default: unknown,
        /// which keeps the old "any Terminal window" behavior.
        var frontTab: @MainActor (Int?) -> FrontTabStatus = { _ in .unknown }
        /// Displays with their full frames (for the Dock side when peeking). Empty: use `screens`.
        var screenInfos: @MainActor () -> [ScreenInfo] = { [] }

        @MainActor static var live: Environment {
            let source = CGWindowInfoSource()
            let presence = ClaudePresence()
            return Environment(
                frontmost: {
                    let app = NSWorkspace.shared.frontmostApplication
                    return (app?.bundleIdentifier, app?.processIdentifier)
                },
                windows: { source.onScreenWindows() },
                screens: { NSScreen.screens.map(\.visibleFrame) },
                primaryScreenHeight: { NSScreen.screens.first?.frame.height ?? 0 },
                frontTab: { presence.status(frontWindowKey: $0) },
                screenInfos: { NSScreen.screens.map { ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame) } }
            )
        }
    }

    static let pollInterval: TimeInterval = 1.0 / 30.0
    /// Ignore sub-half-point jitter so the panel isn't moved needlessly.
    static let moveThreshold: CGFloat = 0.5

    private weak var presenter: GoobyPresenter?
    private let goobySize: CGSize
    private let environment: Environment
    private var timer: Timer?
    private(set) var presentedOrigin: CGPoint?
    /// Which Claude window/tab Gooby sits beside; a change means "glide there".
    private var presentedIdentity: String?
    private(set) var project: String?
    /// Optional override (used by the rain easter egg to float Gooby and keep him visible).
    var originAdjuster: (@MainActor (CGPoint?) -> CGPoint?)?

    var isPresented: Bool { presentedOrigin != nil }

    /// Peek from a screen edge when no Claude chat is in front (otherwise: hide).
    let peeksWhenAway: Bool
    /// Double-clicked while peeking: stay hidden until a Claude chat is in front again.
    private(set) var hiddenByUser = false
    private(set) var peeking: PeekEdge?
    /// Gooby's last spot beside a chat (its center): where to peek from, at about that height.
    private var lastBesideCenter: CGPoint?

    init(presenter: GoobyPresenter, goobySize: CGSize = GoobyVisualMetrics.canvasSize,
         environment: Environment = .live, peeksWhenAway: Bool = false,
         peekHeight: PeekHeightStoring = InMemoryPeekHeight()) {
        self.peekHeight = peekHeight
        self.presenter = presenter
        self.goobySize = goobySize
        self.environment = environment
        self.peeksWhenAway = peeksWhenAway
    }

    /// Being dragged up/down the peek edge: don't move Gooby.
    private(set) var isBeingDragged = false
    /// The peek height the user dragged Gooby to, saved across launches (fraction of the
    /// screen's usable height); used for every later peek.
    private let peekHeight: PeekHeightStoring
    var userPeekFraction: Double? { peekHeight.fraction }

    func userDragBegan() {
        guard peeking != nil else { return }
        isBeingDragged = true
    }

    /// Peeking Gooby was dropped at `origin`: keep that height for this and later peeks.
    func userDragEnded(at origin: CGPoint) {
        isBeingDragged = false
        guard peeking != nil else { return }
        let screens = peekScreens()
        if let screen = PeekPlacement.screen(containing: CGPoint(x: origin.x + goobySize.width / 2, y: origin.y + goobySize.height / 2),
                                             in: screens) {
            peekHeight.fraction = PeekPlacement.fraction(ofOriginY: origin.y, height: goobySize.height, in: screen.visibleFrame)
        }
        presentedOrigin = origin
    }

    /// Double-click while peeking: hide until a Claude chat is in front.
    func hideUntilClaudeReturns() {
        guard peeking != nil else { return }
        hiddenByUser = true
        tick()
    }

    func start() {
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = Self.pollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One placement decision. Cheap when Terminal isn't in front: no window query.
    func tick() {
        guard !isBeingDragged else { return }
        let found = target()
        let raw = found?.origin
        let adjusted = originAdjuster.map { $0(raw) } ?? raw
        guard let target = adjusted else {
            if peeksWhenAway && originAdjuster == nil && !hiddenByUser {
                peekFromEdge()
                return
            }
            if isPresented || peeking != nil {
                presenter?.conceal()
                presentedOrigin = nil
                presentedIdentity = nil
                peeking = nil
            }
            return
        }
        hiddenByUser = false // a Claude chat is in front again
        let wasPeeking = peeking != nil
        peeking = nil
        lastBesideCenter = CGPoint(x: target.x + goobySize.width / 2, y: target.y + goobySize.height / 2)
        let identity = found?.identity
        if identity != presentedIdentity {
            presentedIdentity = identity
            project = found?.project
            presenter?.showProject(project)
        }
        if let current = presentedOrigin,
           abs(current.x - target.x) < Self.moveThreshold,
           abs(current.y - target.y) < Self.moveThreshold {
            return
        }
        // Glide when moving to a different window/tab; follow drags of the same window at once.
        let switched = presentedOrigin != nil && (identity != lastMovedIdentity || wasPeeking)
        presenter?.present(at: target, animated: switched && originAdjuster == nil)
        presentedOrigin = target
        lastMovedIdentity = identity
    }

    private var lastMovedIdentity: String?

    /// Peek around the nearest allowed side edge, near where Gooby last sat.
    private func peekScreens() -> [ScreenInfo] {
        let infos = environment.screenInfos()
        return infos.isEmpty ? environment.screens().map { ScreenInfo(frame: $0, visibleFrame: $0) } : infos
    }

    private func peekFromEdge() {
        let screens = peekScreens()
        var anchor = lastBesideCenter ?? presentedOrigin.map {
            CGPoint(x: $0.x + goobySize.width / 2, y: $0.y + goobySize.height / 2)
        } ?? screens.first.map { CGPoint(x: $0.visibleFrame.maxX, y: $0.visibleFrame.minY + goobySize.height) }
        if let f = peekHeight.fraction, let point = anchor,
           let screen = PeekPlacement.screen(containing: point, in: screens) { // the height the user chose
            anchor?.y = PeekPlacement.originY(forFraction: f, height: goobySize.height, in: screen.visibleFrame) + goobySize.height / 2
        }
        guard let anchor, let spot = PeekPlacement.place(canvas: goobySize, near: anchor, screens: screens) else { return }
        let moved = presentedOrigin.map { abs($0.x - spot.origin.x) >= Self.moveThreshold || abs($0.y - spot.origin.y) >= Self.moveThreshold } ?? true
        guard moved || peeking != spot.edge else { return }
        let animated = presentedOrigin != nil // glide over from beside the chat (or along the edge)
        peeking = spot.edge
        presentedIdentity = nil
        lastMovedIdentity = nil
        presenter?.showProject(nil)
        presenter?.peek(at: spot.origin, edge: spot.edge, animated: animated)
        presentedOrigin = spot.origin
    }

    func targetOrigin() -> CGPoint? { target()?.origin }

    /// Where Gooby belongs, which window/tab that is, and its project; nil when Gooby should hide.
    func target() -> (origin: CGPoint, identity: String, project: String?)? {
        let front = environment.frontmost()
        guard let id = front.bundleID, TerminalWindowLocator.terminalBundleIDs.contains(id) else { return nil }
        guard let window = TerminalWindowLocator.frontTerminalSnapshot(
            frontmostBundleID: id, frontmostPID: front.pid, windows: environment.windows()
        ) else { return nil }
        let project: String?
        switch environment.frontTab(window.number) {
        case .notClaude: return nil
        case let .claude(name): project = name
        case .unknown: project = nil
        }
        let terminal = TerminalRelativePlacement.appKitRect(
            fromCGBounds: window.bounds, primaryScreenHeight: environment.primaryScreenHeight()
        )
        let origin = TerminalRelativePlacement.origin(goobySize: goobySize, terminal: terminal, screens: environment.screens())
        return (origin, "\(window.ownerPID)/\(window.number)/\(project ?? "")", project)
    }
}
