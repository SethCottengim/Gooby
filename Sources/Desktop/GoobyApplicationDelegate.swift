import AppKit

/// Sets the accessory activation policy before showing Gooby, keeps the host
/// alive for the process lifetime, and releases it on termination.
/// Only one Gooby runs at a time: a later launch quits itself.
@MainActor
final class GoobyApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var host: GoobyWindowHost?
    private var follower: TerminalFollower?
    private(set) var storm: StormController?
    private var skillBubble: SkillOfferBubble?
    private(set) var skillCoach: SkillCoach?
    private var signalSources: [DispatchSourceSignal] = []

    struct InstanceInfo: Equatable {
        let pid: pid_t
        let launchDate: Date?
    }

    /// True when another instance launched before `current` (ties broken by lower pid),
    /// so simultaneous launches never both quit.
    nonisolated static func shouldYield(current: InstanceInfo, others: [InstanceInfo]) -> Bool {
        others.contains { other in
            guard other.pid != current.pid else { return false }
            if let a = other.launchDate, let b = current.launchDate, a != b { return a < b }
            return other.pid < current.pid
        }
    }

    /// The XCTest host is this app; never let a running Gooby kill the test run.
    private var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func anotherGoobyIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        let current = InstanceInfo(pid: me.processIdentifier, launchDate: me.launchDate)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .map { InstanceInfo(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        return Self.shouldYield(current: current, others: others)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Clean up after a previous force-killed run, then make `pkill` quit gracefully
        // (so a storm's windows, hotkey and motion sensor are always released).
        AccelerometerReader.resetSensorToOff()
        installGracefulQuitOnSignals()
    }

    private func installGracefulQuitOnSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isTestHost && anotherGoobyIsRunning() {
            NSApplication.shared.terminate(nil)
            return
        }
        let host = GoobyWindowHost()
        host.prepare()
        self.host = host
        // Gooby appears beside the front Terminal window and hides otherwise.
        // Beside Claude chats; peeking from a screen edge everywhere else.
        let follower = TerminalFollower(presenter: host, peeksWhenAway: true, peekHeight: UserDefaultsPeekHeight())
        host.controls.onPeekDoubleClick = { [weak follower] in follower?.hideUntilClaudeReturns() }
        // While peeking, drag Gooby up or down its edge; that height is kept for later peeks.
        host.controls.onDragBegan = { [weak follower, weak host] in
            host?.cancelGlide()
            follower?.userDragBegan()
        }
        host.controls.onDragEnded = { [weak follower] origin in follower?.userDragEnded(at: origin) }
        follower.start()
        self.follower = follower
        // Easter egg: 9 quick clicks on Gooby make it rain.
        var stormClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        #if DEBUG
        // GOOBY_DEBUG_STORM_SPEED=10 runs the storm 10× faster (developer testing only).
        if let speed = Double(ProcessInfo.processInfo.environment["GOOBY_DEBUG_STORM_SPEED"] ?? ""), speed > 0 {
            stormClock = { ProcessInfo.processInfo.systemUptime * speed }
        }
        #endif
        let storm = StormController(host: host, follower: follower, clock: stormClock)
        host.controls.onCharacterClick = { [weak storm] in storm?.handleCharacterClick() }
        self.storm = storm
        // Repeated Claude Code requests become /gooby-<name> skill offers.
        // Off in the test host so tests never read the real inbox or call Claude.
        if !isTestHost { startSkillCoach(host: host) }
        #if DEBUG
        // Developer shortcut for live testing: GOOBY_DEBUG_STORM=1 starts the storm at launch.
        if ProcessInfo.processInfo.environment["GOOBY_DEBUG_STORM"] == "1" { storm.start() }
        // GOOBY_DEBUG_TILT=1 logs accelerometer roll once per second (no storm).
        if ProcessInfo.processInfo.environment["GOOBY_DEBUG_TILT"] == "1" { startTiltDebugLog() }
        // GOOBY_DEBUG_OFFER=1 shows a sample skill offer 3 s after launch (writes no skill).
        // GOOBY_DEBUG_TTY=ttys002 also asks Terminal where that tab is (triggers the
        // Automation permission prompt the first time) and logs the answer to stderr.
        if ProcessInfo.processInfo.environment["GOOBY_DEBUG_OFFER"] == "1" { scheduleDebugOffer() }
        #endif
    }

    #if DEBUG
    private func scheduleDebugOffer() {
        let tty = ProcessInfo.processInfo.environment["GOOBY_DEBUG_TTY"]
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor in
                guard let self, let bubble = self.skillBubble else {
                    FileHandle.standardError.write("debug-offer: no bubble (test host?)\n".data(using: .utf8)!)
                    return
                }
                // What a real user sees; Terminal's answer goes only to the log.
                let label = "In your “Fix the MR pipeline” chat (notes-app)"
                if let tty {
                    let placement = await TerminalTabLocator().placement(ofTTY: tty)
                    FileHandle.standardError.write("debug-offer: \(tty) placement = \(placement)\n".data(using: .utf8)!)
                }
                let offer = SkillOffer(intentID: "debug", skillName: "gooby-commit-and-push",
                                       summary: "Commit all changes and push to the remote",
                                       sessionCount: IntentStore.offerThreshold, chatLabel: label)
                bubble.showOffer(offer) { [weak bubble] answer in
                    FileHandle.standardError.write("debug-offer: answer = \(answer)\n".data(using: .utf8)!)
                    if answer != .expired { bubble?.showMessage("Debug offer: you chose \(answer). No skill was written.") }
                }
            }
        }
    }

    private var debugReader: AccelerometerReader?
    private var debugTilt = TiltInput()
    private var debugCount = 0

    private func startTiltDebugLog() {
        let reader = AccelerometerReader()
        reader.onSample = { [weak self] sample in
            guard let self else { return }
            self.debugTilt.ingest(sample)
            self.debugCount += 1
            if self.debugCount % 100 == 0 {
                let g = self.debugTilt.gravity ?? sample
                FileHandle.standardError.write(String(format: "tilt-debug samples=%d x=%.3f y=%.3f z=%.3f roll=%.1f°\n",
                    self.debugCount, g.x, g.y, g.z, TiltInput.roll(of: g) * 180 / .pi).data(using: .utf8)!)
            }
        }
        FileHandle.standardError.write("tilt-debug accelerometer started: \(reader.start())\n".data(using: .utf8)!)
        debugReader = reader
    }
    #endif

    private func startSkillCoach(host: GoobyWindowHost) {
        let bubble = SkillOfferBubble(anchor: { [weak host] in host?.panel })
        let claude = ClaudeCLI()
        let coach = SkillCoach(
            inbox: PromptInbox(directory: PromptInbox.defaultDirectory),
            storeFile: IntentStoreFile(url: PromptInbox.supportDirectory.appendingPathComponent("intents.json")),
            retryFile: RetryQueueFile(url: PromptInbox.supportDirectory.appendingPathComponent("retry.json")),
            classifier: IntentClassifier(claude: claude),
            writer: SkillWriter(skillsDirectory: SkillWriter.defaultSkillsDirectory, claude: claude),
            coverage: CoverageChecker(claude: claude),
            presenter: bubble
        )
        coach.start()
        skillBubble = bubble
        skillCoach = coach
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        debugReader?.stop()
        #endif
        skillCoach?.stop()
        skillCoach = nil
        skillBubble?.dismiss()
        skillBubble = nil
        storm?.stop()
        storm = nil
        follower?.stop()
        follower = nil
        host?.tearDown()
        host = nil
    }
}
