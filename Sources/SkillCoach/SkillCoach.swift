import Foundation

struct SkillOffer: Equatable {
    let intentID: String
    let skillName: String
    let summary: String
    let sessionCount: Int
    /// Which chat the offer is about, in plain words, e.g.
    /// "In your “Fix the MR pipeline” chat (notes-app)" (nil if unknown).
    var chatLabel: String? = nil
}

enum SkillOfferAnswer: Equatable {
    case accept
    case decline
    /// The bubble closed unanswered (timeout). Not a No: offered again at the next repeat.
    case expired
}

/// Shows Gooby's speech bubble.
@MainActor
protocol SkillOfferPresenting: AnyObject {
    func showOffer(_ offer: SkillOffer, onAnswer: @escaping @MainActor (SkillOfferAnswer) -> Void)
    func showMessage(_ text: String)
}

/// Watches the hook inbox, groups prompts into intents with Claude's help, and offers a
/// /gooby-<slug> skill once an intent shows up in IntentStore.offerThreshold sessions.
///
/// Context-aware, per the product owner:
/// - Right moment: only when Claude has just finished (Stop hook) in the session where the
///   intent was just asked for, within `offerWindow`.
/// - From what Claude did: each sighting keeps a trace of Claude's tool calls, captured when
///   that turn ends; the skill is drafted from those traces.
/// - Not already covered: installed skills/commands are checked before offering.
/// - Right window: with several Terminal windows, the offer waits until the chat's own tab is
///   the selected tab of the front window (needs Automation permission for Terminal). If that
///   can't be known (permission denied, tmux, not Terminal), it shows anyway, labeled with the chat.
@MainActor
final class SkillCoach {
    /// How long after the repeat an offer may still appear (the user has likely moved on after this).
    static let offerWindow: TimeInterval = 30 * 60
    /// Sightings with no trace after this long stop being retried (session log likely gone).
    static let traceGiveUpAge: TimeInterval = 7 * 24 * 60 * 60
    /// A trace still growing (no next prompt, no Stop) is taken anyway after this long.
    static let traceSettleAge: TimeInterval = 10 * 60
    /// How often sightings still missing a trace are retried (also once at launch).
    static let traceSweepInterval: TimeInterval = 10 * 60

    /// An offer that passed every check and is waiting for the chat to be in front.
    struct PendingOffer: Equatable {
        let intentID: String
        let sessionID: String
        let tty: String?
        let askedAt: Date
        let chatLabel: String?
    }

    private let inbox: PromptInbox
    private let storeFile: IntentStoreFile
    /// Prompts whose Claude call failed, retried with backoff (nil: failures are dropped).
    private let retryFile: RetryQueueFile?
    private(set) var retries = RetryQueue()
    /// After a failed Claude call, new prompts are queued without calling Claude until
    /// this time (a broken Claude can take the full timeout per call).
    private(set) var claudeUnavailableUntil: Date?
    private let classifier: IntentClassifier
    private let writer: SkillWriter
    private let coverage: CoverageChecker?
    private let installedSkills: ([String]) -> [InstalledSkill]
    private let tabLocator: TerminalTabLocating?
    private let clock: @MainActor () -> Date
    private var lastTraceSweep: Date?
    private(set) var pending: PendingOffer?
    private weak var presenter: SkillOfferPresenting?
    private let pollInterval: TimeInterval
    private(set) var store: IntentStore
    private var timer: Timer?
    private var isWorking = false
    private(set) var offerOnScreen: String?
    /// Per session: the intent most recently asked for, when, and in which Terminal tab.
    private var lastSighting: [String: (intentID: String, date: Date, tty: String?)] = [:]

    init(
        inbox: PromptInbox,
        storeFile: IntentStoreFile,
        retryFile: RetryQueueFile? = nil,
        classifier: IntentClassifier,
        writer: SkillWriter,
        coverage: CoverageChecker?,
        installedSkills: @escaping ([String]) -> [InstalledSkill] = { SkillCatalog.installed(projectDirectories: $0) },
        tabLocator: TerminalTabLocating? = TerminalTabLocator(),
        clock: @escaping @MainActor () -> Date = { Date() },
        presenter: SkillOfferPresenting?,
        pollInterval: TimeInterval = 2
    ) {
        self.tabLocator = tabLocator
        self.clock = clock
        self.inbox = inbox
        self.storeFile = storeFile
        self.retryFile = retryFile
        self.retries = retryFile?.load() ?? RetryQueue()
        self.classifier = classifier
        self.writer = writer
        self.coverage = coverage
        self.installedSkills = installedSkills
        self.presenter = presenter
        self.pollInterval = pollInterval
        self.store = storeFile.load()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !isWorking else { return }
        isWorking = true
        Task { [weak self] in
            await self?.processInbox()
            self?.isWorking = false
        }
    }

    /// One pass: waiting events in the order they happened, then the trace sweep and any
    /// offer waiting for the right moment.
    func processInbox() async {
        // Earlier prompts whose Claude call failed come first (they happened earlier).
        let due = retries.takeDue(now: clock())
        if !due.isEmpty { retryFile?.save(retries) }
        for entry in due {
            await handle(entry.captured, context: entry.context, failedAttempts: entry.attempts)
        }
        for event in inbox.drain() {
            switch event {
            case let .prompt(captured):
                let context = captured.precedingAssistantText()
                guard PromptInbox.isWorthClassifying(captured.prompt, context: context) else { continue }
                await handle(captured, context: context)
            case let .turnEnded(turn):
                await turnEnded(turn)
            }
        }
        let now = clock()
        if lastTraceSweep.map({ now.timeIntervalSince($0) >= Self.traceSweepInterval }) ?? true {
            lastTraceSweep = now
            captureTraces(inSession: nil, turnEnded: false, now: now)
        }
        await presentPendingIfRightMoment(now: now)
    }

    /// `failedAttempts`: Claude calls that already failed for this prompt (retries).
    func handle(_ captured: CapturedPrompt, context: String? = nil, failedAttempts: Int = 0) async {
        let now = clock()
        // Claude just failed: queue instead of waiting out another timeout.
        if let until = claudeUnavailableUntil, now < until {
            retries.add(captured, context: context, attempts: failedAttempts, nextAttempt: until)
            retryFile?.save(retries)
            return
        }
        let result: IntentClassification
        do {
            result = try await classifier.classify(prompt: captured.prompt, context: context, against: store.candidatesForMatching)
            claudeUnavailableUntil = nil
        } catch {
            let attempts = failedAttempts + 1
            if let delay = RetryQueue.delay(afterFailures: attempts) {
                let next = clock().addingTimeInterval(delay)
                retries.add(captured, context: context, attempts: attempts, nextAttempt: next)
                claudeUnavailableUntil = next
                NSLog("Gooby: couldn't classify a prompt (try \(attempts)); retrying in \(Int(delay)) s: \(error)")
            } else {
                claudeUnavailableUntil = clock().addingTimeInterval(RetryQueue.backoff[0])
                NSLog("Gooby: gave up on a prompt after \(failedAttempts) failed tries: \(error)")
            }
            retryFile?.save(retries)
            return
        }
        // Save the restated request ("commit and push"), not a bare "yes go ahead".
        let example = result.request ?? captured.prompt
        let intentID: String
        switch result.verdict {
        case .ignore:
            return
        case let .match(id, _):
            store.recordSighting(intentID: id, prompt: example, sessionID: captured.sessionID, date: captured.date,
                                 transcriptPath: captured.transcriptPath, cwd: captured.cwd)
            intentID = id
        case let .new(slug, summary):
            intentID = store.addIntent(slug: slug, summary: summary, prompt: example, sessionID: captured.sessionID,
                                       date: captured.date, transcriptPath: captured.transcriptPath, cwd: captured.cwd)
        }
        // A late retry must not replace a newer ask in the same chat (offer timing).
        if let latest = lastSighting[captured.sessionID], latest.date > captured.date {
        } else {
            lastSighting[captured.sessionID] = (intentID, captured.date, captured.tty)
        }
        storeFile.save(store)
    }

    /// Claude finished replying in a session: record what it did, then maybe offer.
    func turnEnded(_ turn: TurnEnded) async {
        let copy = turn.logCopyPath.map { URL(fileURLWithPath: $0) }
        captureTraces(inSession: turn.sessionID, turnEnded: true, now: turn.date, logCopy: copy)
        if let copy { try? FileManager.default.removeItem(at: copy) }
        await offerIfDue(session: turn.sessionID, now: turn.date)
    }

    /// Fills in traces for sightings that don't have one yet.
    /// `turnEnded`: Claude's turn is over for the latest prompt of that session, so a trace
    /// that runs to the end of the log is complete.
    /// `logCopy`: the hook's copy of the end of that session's log, used when the real log
    /// is gone or no longer holds the prompt.
    func captureTraces(inSession session: String?, turnEnded: Bool, now: Date = Date(), logCopy: URL? = nil) {
        var changed = false
        for intent in store.intents {
            for s in intent.sightings where s.trace == nil && (session == nil || s.sessionID == session) {
                let original = s.transcriptPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                guard original != nil || logCopy != nil else { continue }
                let age = now.timeIntervalSince(s.date)
                let found = original.flatMap { TranscriptContext.actionTrace(transcript: $0, promptDate: s.date) }
                    ?? logCopy.flatMap { TranscriptContext.actionTrace(transcript: $0, promptDate: s.date) }
                if let trace = found, trace.reachedNextPrompt || turnEnded || age > Self.traceSettleAge {
                    store.setTrace(trace.text, intentID: intent.id, sessionID: s.sessionID, date: s.date)
                    changed = true
                } else if age > Self.traceGiveUpAge {
                    store.setTrace("", intentID: intent.id, sessionID: s.sessionID, date: s.date) // gave up
                    changed = true
                }
            }
        }
        if changed { storeFile.save(store) }
    }

    func offerIfDue(session: String, now: Date = Date()) async {
        guard offerOnScreen == nil, presenter != nil,
              let last = lastSighting[session], now.timeIntervalSince(last.date) <= Self.offerWindow,
              store.isReadyToOffer(last.intentID), let intent = store.intent(id: last.intentID) else { return }

        if let coverage {
            let dirs = Array(Set(intent.sightings.compactMap(\.cwd))).sorted()
            switch await coverage.check(intent, against: installedSkills(dirs)) {
            case let .covered(by):
                store.markCovered(intent.id, by: by)
                storeFile.save(store)
                return
            case .unknown:
                return // try again at the next repeat
            case .notCovered:
                break
            }
        }
        // Another offer may have appeared while waiting for Claude.
        guard offerOnScreen == nil, pending == nil, store.isReadyToOffer(intent.id) else { return }
        lastSighting[session] = nil
        let sighting = intent.sightings.last { $0.sessionID == session }
        pending = PendingOffer(intentID: intent.id, sessionID: session, tty: last.tty, askedAt: last.date,
                               chatLabel: Self.chatLabel(cwd: sighting?.cwd, transcriptPath: sighting?.transcriptPath))
        await presentPendingIfRightMoment(now: now)
    }

    /// Shows the waiting offer once its chat is the one in front. Gives up quietly after
    /// `offerWindow`; the offer comes back at the next repeat.
    func presentPendingIfRightMoment(now: Date) async {
        guard let p = pending, offerOnScreen == nil, let presenter else { return }
        guard now.timeIntervalSince(p.askedAt) <= Self.offerWindow, store.isReadyToOffer(p.intentID),
              let intent = store.intent(id: p.intentID) else {
            pending = nil
            return
        }
        if let tty = p.tty, let tabLocator {
            switch await tabLocator.placement(ofTTY: tty) {
            case .front, .notInTerminal, .unavailable:
                break // show now (labeled, so it's clear which chat it's about)
            case .elsewhere:
                return // wait until the user is back in that chat
            }
        }
        guard pending == p, offerOnScreen == nil else { return } // changed while asking Terminal
        pending = nil
        offerOnScreen = intent.id
        let offer = SkillOffer(
            intentID: intent.id,
            skillName: writer.availableName(for: intent.slug),
            summary: intent.summary,
            sessionCount: intent.distinctSessionCount,
            chatLabel: p.chatLabel
        )
        presenter.showOffer(offer) { [weak self] answer in
            Task { await self?.answer(intentID: intent.id, answer) }
        }
    }

    /// A plain sentence naming the chat, from the sighting's folder and its session log:
    /// "In your “<title>” chat (<folder>)", "In your “<title>” chat", or "In a chat in <folder>".
    nonisolated static func chatLabel(cwd: String?, transcriptPath: String?) -> String? {
        let folder = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let title = transcriptPath.flatMap { TranscriptContext.lastTitle(transcript: URL(fileURLWithPath: $0)) }
        let parts = [folder, title].compactMap { $0 }
        switch (title, folder) {
        case let (title?, folder?): return "In your “\(title)” chat (\(folder))"
        case let (title?, nil): return "In your “\(title)” chat"
        case let (nil, folder?): return "In a chat in \(folder)"
        case (nil, nil): return nil
        }
    }

    func answer(intentID: String, _ answer: SkillOfferAnswer) async {
        defer { offerOnScreen = nil }
        guard store.intent(id: intentID) != nil else { return }
        switch answer {
        case .expired:
            return
        case .decline:
            store.setStatus(.declined, for: intentID)
            storeFile.save(store)
            return
        case .accept:
            break
        }
        presenter?.showMessage("Making your skill…")
        // Last chance to read what Claude did for sightings still missing a trace.
        captureTraces(inSession: nil, turnEnded: false)
        guard let intent = store.intent(id: intentID) else { return }
        do {
            let name = try await writer.write(for: intent)
            store.setStatus(.created, for: intentID)
            storeFile.save(store)
            presenter?.showMessage("Made /\(name). Try it in a new chat!")
        } catch {
            NSLog("Gooby: couldn't write skill: \(error)")
            presenter?.showMessage("Sorry, I couldn't make that skill.")
        }
    }
}
