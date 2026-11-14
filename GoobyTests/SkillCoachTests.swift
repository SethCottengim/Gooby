import AppKit
import XCTest
@testable import Gooby

/// Replays canned replies in order and records every prompt it was sent.
final class ScriptedClaude: ClaudeCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, Error>]
    private(set) var prompts: [String] = []

    init(_ replies: [Result<String, Error>]) { self.replies = replies }

    func complete(_ prompt: String) async throws -> String {
        let next: Result<String, Error> = lock.withLock {
            prompts.append(prompt)
            return replies.isEmpty ? .success(#"{"kind":"ignore"}"#) : replies.removeFirst()
        }
        return try next.get()
    }
}

/// Answers "match" with the only known intent's id, or "new" if none exists yet.
final class SameIntentClaude: ClaudeCompleting, @unchecked Sendable {
    func complete(_ prompt: String) async throws -> String {
        if prompt.hasPrefix("Write a Claude Code skill") { throw ClaudeCLIError.timedOut }
        if prompt.hasPrefix("A developer keeps asking") { return #"{"covered":false}"# }
        if !prompt.contains("Known intents (JSON): []"),
           let range = prompt.range(of: #""id":"([^"]+)""#, options: .regularExpression) {
            let id = prompt[range].dropFirst(6).dropLast()
            return #"{"kind":"match","id":"\#(id)","confidence":0.92}"#
        }
        return #"{"kind":"new","slug":"Commit and Push!","summary":"Commit all changes and push to the remote"}"#
    }
}

@MainActor
final class RecordingPresenter: SkillOfferPresenting {
    var offers: [SkillOffer] = []
    var messages: [String] = []
    var answer: (@MainActor (SkillOfferAnswer) -> Void)?

    func showOffer(_ offer: SkillOffer, onAnswer: @escaping @MainActor (SkillOfferAnswer) -> Void) {
        offers.append(offer)
        answer = onAnswer
    }

    func showMessage(_ text: String) { messages.append(text) }
}

final class SkillSlugTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(SkillSlug.sanitize("Commit and Push!"), "commit-and-push")
        XCTAssertEqual(SkillSlug.sanitize("  --run__tests--  "), "run-tests")
        XCTAssertEqual(SkillSlug.sanitize("gooby-deploy"), "deploy", "No double gooby- prefix")
        XCTAssertEqual(SkillSlug.sanitize("!!!"), "task", "Never empty")
        XCTAssertEqual(SkillSlug.sanitize("élan vital"), "lan-vital", "Non-ASCII letters dropped")
        XCTAssertLessThanOrEqual(SkillSlug.sanitize(String(repeating: "ab-", count: 40)).count, SkillSlug.maxLength)
        XCTAssertFalse(SkillSlug.sanitize(String(repeating: "ab-", count: 40)).hasSuffix("-"))
    }
}

final class IntentStoreTests: XCTestCase {
    func testThresholdIsFiveSessions() {
        XCTAssertEqual(IntentStore.offerThreshold, 5)
    }

    func testOffersOnlyAfterThresholdDistinctSessions() {
        var store = IntentStore()
        let id = store.addIntent(slug: "commit-and-push", summary: "Commit and push", prompt: "commit and push", sessionID: "S1", date: Date())
        for _ in 0..<10 { store.recordSighting(intentID: id, prompt: "commit and push", sessionID: "S1", date: Date()) }
        for n in 2..<IntentStore.offerThreshold {
            store.recordSighting(intentID: id, prompt: "commit and push", sessionID: "S\(n)", date: Date())
        }
        XCTAssertNil(store.nextOffer, "Many sightings, but one session short; repeats in one session count once")
        store.recordSighting(intentID: id, prompt: "commit all changes and push", sessionID: "S\(IntentStore.offerThreshold)", date: Date())
        XCTAssertEqual(store.nextOffer?.id, id)
        XCTAssertEqual(store.nextOffer?.distinctSessionCount, IntentStore.offerThreshold)
    }

    func testManyRepeatsInOneSessionNeverLowerTheSessionCount() {
        var store = IntentStore()
        let id = store.addIntent(slug: "x", summary: "X", prompt: "p", sessionID: "S1", date: Date())
        for n in 2..<IntentStore.offerThreshold { store.recordSighting(intentID: id, prompt: "p", sessionID: "S\(n)", date: Date()) }
        // Far more repeats than the sighting cap, all in the last session.
        for _ in 0..<(IntentStore.maxSightingsPerIntent * 2) {
            store.recordSighting(intentID: id, prompt: "p", sessionID: "S\(IntentStore.offerThreshold)", date: Date())
        }
        XCTAssertEqual(store.intent(id: id)?.sightings.count, IntentStore.maxSightingsPerIntent, "Examples still capped")
        XCTAssertEqual(store.intent(id: id)?.distinctSessionCount, IntentStore.offerThreshold, "Older sessions still counted")
        XCTAssertEqual(store.nextOffer?.id, id)
    }

    func testIntentsSavedBeforeSessionIDsFieldStillLoadAndCount() throws {
        let old = #"{"intents":[{"id":"a","slug":"x","summary":"X","status":"tracking","sightings":[{"prompt":"p","sessionID":"S1","date":"2026-11-11T00:00:00Z"},{"prompt":"p","sessionID":"S2","date":"2026-11-11T00:00:00Z"}]}]}"#
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = IntentStoreFile(url: dir.appendingPathComponent("intents.json"))
        try Data(old.utf8).write(to: file.url)
        var store = file.load()
        XCTAssertEqual(store.intents.count, 1, "Old file still decodes")
        XCTAssertEqual(store.intent(id: "a")?.distinctSessionCount, 2)
        store.recordSighting(intentID: "a", prompt: "p", sessionID: "S3", date: Date())
        XCTAssertEqual(store.intent(id: "a")?.sessionIDs, ["S1", "S2", "S3"], "Old sightings' sessions carried over")
    }

    func testDeclinedAndCreatedIntentsAreNeverOffered() {
        var store = IntentStore()
        let id = store.addIntent(slug: "x", summary: "X", prompt: "p", sessionID: "S1", date: Date())
        for n in 2...IntentStore.offerThreshold { store.recordSighting(intentID: id, prompt: "p", sessionID: "S\(n)", date: Date()) }
        XCTAssertEqual(store.nextOffer?.id, id)
        store.setStatus(.declined, for: id)
        XCTAssertNil(store.nextOffer)
        store.setStatus(.created, for: id)
        XCTAssertNil(store.nextOffer)
    }

    func testUnknownIDAndSightingCapAndTruncation() {
        var store = IntentStore()
        XCTAssertFalse(store.recordSighting(intentID: "nope", prompt: "p", sessionID: "A", date: Date()))
        let id = store.addIntent(slug: "x", summary: "X", prompt: String(repeating: "a", count: 999), sessionID: "A", date: Date())
        XCTAssertEqual(store.intent(id: id)?.sightings.first?.prompt.count, IntentStore.maxStoredPromptLength)
        for i in 0..<20 { store.recordSighting(intentID: id, prompt: "p\(i)", sessionID: "S\(i)", date: Date()) }
        XCTAssertEqual(store.intent(id: id)?.sightings.count, IntentStore.maxSightingsPerIntent)
        XCTAssertEqual(store.intent(id: id)?.sightings.last?.prompt, "p19", "Keeps the newest")
    }

    func testPruneDropsStalestSingletonsFirst() {
        var store = IntentStore()
        let keeper = store.addIntent(slug: "keep", summary: "K", prompt: "p", sessionID: "A", date: .distantPast)
        store.recordSighting(intentID: keeper, prompt: "p", sessionID: "B", date: .distantPast)
        for i in 0..<IntentStore.maxIntents {
            store.addIntent(slug: "s\(i)", summary: "S", prompt: "p", sessionID: "A", date: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(store.intents.count, IntentStore.maxIntents)
        XCTAssertNotNil(store.intent(id: keeper), "Multi-sighting intents survive pruning")
        XCTAssertFalse(store.intents.contains { $0.slug == "s0" }, "Oldest singleton dropped")
    }

    func testFileRoundTripAndCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = IntentStoreFile(url: dir.appendingPathComponent("intents.json"))
        XCTAssertEqual(file.load(), IntentStore(), "Missing file starts empty")
        var store = IntentStore()
        store.addIntent(slug: "x", summary: "X", prompt: "p", sessionID: "A", date: Date(timeIntervalSince1970: 1_700_000_000))
        file.save(store)
        XCTAssertEqual(file.load(), store)
        try Data("not json".utf8).write(to: file.url)
        XCTAssertEqual(file.load(), IntentStore(), "Corrupt file starts empty")
    }
}

final class ClaudeCLITests: XCTestCase {
    func testParsesLastJSONLineAndSkipsShellNoise() throws {
        let output = "Welcome to zsh\n{not json\n{\"type\":\"result\",\"is_error\":false,\"result\":\"{\\\"kind\\\":\\\"ignore\\\"}\"}\n"
        XCTAssertEqual(try ClaudeCLI.parseResult(output, exitCode: 0), #"{"kind":"ignore"}"#)
    }

    func testErrorsAndMissingResult() {
        XCTAssertThrowsError(try ClaudeCLI.parseResult(#"{"is_error":true,"result":"bad auth"}"#, exitCode: 1)) {
            XCTAssertEqual($0 as? ClaudeCLIError, .claudeError("bad auth"))
        }
        XCTAssertThrowsError(try ClaudeCLI.parseResult("zsh: command not found: claude", exitCode: 127)) {
            XCTAssertEqual($0 as? ClaudeCLIError, .noResult(exitCode: 127))
        }
    }

    func testCommandDisablesToolsAndSessionSaving() {
        let cmd = ClaudeCLI().shellCommand
        XCTAssertTrue(cmd.contains("--tools ''"))
        XCTAssertTrue(cmd.contains("--no-session-persistence"))
        XCTAssertTrue(cmd.contains("--model opus"))
    }
}

final class IntentClassifierTests: XCTestCase {
    let known: Set<String> = ["abc"]

    func testParse() {
        XCTAssertEqual(IntentClassifier.parse(#"{"kind":"ignore"}"#, knownIDs: known).verdict, .ignore)
        XCTAssertEqual(IntentClassifier.parse("```json\n{\"kind\":\"match\",\"id\":\"abc\",\"confidence\":0.9}\n```", knownIDs: known).verdict,
                       .match(id: "abc", confidence: 0.9), "Code fences tolerated")
        XCTAssertEqual(IntentClassifier.parse(#"{"kind":"new","slug":"run-tests","summary":"Run the tests"}"#, knownIDs: known).verdict,
                       .new(slug: "run-tests", summary: "Run the tests"))
    }

    func testRejectsBadReplies() {
        XCTAssertEqual(IntentClassifier.parse("sure!", knownIDs: known).verdict, .ignore)
        XCTAssertEqual(IntentClassifier.parse(#"{"kind":"match","id":"zzz","confidence":0.99}"#, knownIDs: known).verdict, .ignore, "Unknown id")
        XCTAssertEqual(IntentClassifier.parse(#"{"kind":"match","id":"abc","confidence":0.5}"#, knownIDs: known).verdict, .ignore, "Low confidence")
        XCTAssertEqual(IntentClassifier.parse(#"{"kind":"match","id":"abc","confidence":0.74,"slug":"s","summary":"S"}"#, knownIDs: known).verdict,
                       .new(slug: "s", summary: "S"), "Low confidence with a slug starts a new intent")
        XCTAssertEqual(IntentClassifier.parse(#"{"kind":"new","slug":"s","summary":"  "}"#, knownIDs: known).verdict, .ignore)
    }

    func testInstructionsSayQuestionsAreNotTasks() {
        let text = IntentClassifier.instructions(prompt: "what does this tool do?", intents: [])
        XCTAssertTrue(text.contains("A reusable task is something the assistant DOES"))
        XCTAssertTrue(text.contains("simple lookups"))
        XCTAssertTrue(text.contains("even if the developer asks such questions often"))
    }

    func testInstructionsIncludeKnownIntentsAndClipLongPrompts() {
        let intent = TrackedIntent(id: "abc", slug: "x", summary: "Commit and push",
                                   sightings: [.init(prompt: "commit and push", sessionID: "A", date: Date())], status: .tracking)
        let text = IntentClassifier.instructions(prompt: String(repeating: "z", count: 5000), intents: [intent])
        XCTAssertTrue(text.contains(#""id":"abc""#))
        XCTAssertTrue(text.contains("commit and push"))
        XCTAssertFalse(text.contains(String(repeating: "z", count: IntentClassifier.maxPromptLength + 1)))
    }
}

final class PromptInboxTests: XCTestCase {
    func testDrainReadsInOrderDeletesAndSkipsTempFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ json: String, _ name: String, at t: TimeInterval) throws {
            let url = dir.appendingPathComponent(name)
            try Data(json.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: url.path)
        }
        // Same whole second in the name; file time decides the order.
        try write(#"{"session_id":"s1","hook_event_name":"Stop","transcript_path":"/t.jsonl"}"#, "100-2.json", at: 1003)
        try write(#"{"session_id":"s1","prompt":"first","cwd":"/repo","transcript_path":"/t.jsonl"}"#, "100-9.json", at: 1001)
        try write(#"{"session_id":"s2","prompt":"second"}"#, "100-1.json", at: 1004)
        try write("garbage", "100-5.json", at: 1002)
        try Data(#"{"prompt":"partial"}"#.utf8).write(to: dir.appendingPathComponent(".tmp-9"))

        let events = PromptInbox(directory: dir).drain()
        XCTAssertEqual(events, [
            .prompt(CapturedPrompt(prompt: "first", sessionID: "s1", date: Date(timeIntervalSince1970: 1001),
                                   transcriptPath: "/t.jsonl", cwd: "/repo")),
            .turnEnded(TurnEnded(sessionID: "s1", date: Date(timeIntervalSince1970: 1003), transcriptPath: "/t.jsonl")),
            .prompt(CapturedPrompt(prompt: "second", sessionID: "s2", date: Date(timeIntervalSince1970: 1004))),
        ])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [".tmp-9"], "Read files deleted, incl. garbage")
        XCTAssertEqual(PromptInbox(directory: dir.appendingPathComponent("missing")).drain(), [])
    }

    func testCheapFilter() {
        let offer = "Done. Want me to commit and push?"
        let statement = "Done. All 49 tests pass."
        // Never: empty, skills, shell commands.
        XCTAssertFalse(PromptInbox.isWorthClassifying("   ", context: offer))
        XCTAssertFalse(PromptInbox.isWorthClassifying("/gooby-commit-and-push", context: offer))
        XCTAssertFalse(PromptInbox.isWorthClassifying("! git status", context: offer))
        // Short approvals count only when Claude offered or asked something.
        XCTAssertFalse(PromptInbox.isWorthClassifying("yes", context: nil))
        XCTAssertTrue(PromptInbox.isWorthClassifying("yes", context: offer), "Yes to an offer is that request")
        XCTAssertTrue(PromptInbox.isWorthClassifying("Sure, go ahead!", context: offer))
        XCTAssertTrue(PromptInbox.isWorthClassifying("yes please do it", context: "I can update the README if you want."))
        XCTAssertFalse(PromptInbox.isWorthClassifying("yes", context: statement), "Yes after a plain statement: no call")
        XCTAssertFalse(PromptInbox.isWorthClassifying("ok go ahead", context: statement))
        // Thanks, praise, and no: never (even after an offer).
        for reply in ["thanks", "Thank you!", "perfect", "cool, works great", "nope", "no, not now", "wait"] {
            XCTAssertFalse(PromptInbox.isWorthClassifying(reply, context: offer), reply)
        }
        // Real requests: as before.
        XCTAssertTrue(PromptInbox.isWorthClassifying("commit and push", context: nil))
        XCTAssertTrue(PromptInbox.isWorthClassifying("perfect. commit and push", context: statement))
        XCTAssertTrue(PromptInbox.isWorthClassifying("push", context: statement), "Short command with context")
        XCTAssertFalse(PromptInbox.isWorthClassifying("push", context: nil))
    }

    func testReplyKinds() {
        XCTAssertEqual(PromptInbox.replyKind("yes"), .approval)
        XCTAssertEqual(PromptInbox.replyKind("go for it"), .approval)
        XCTAssertEqual(PromptInbox.replyKind("ok cool"), .approval, "ok + cool can still answer an offer")
        XCTAssertEqual(PromptInbox.replyKind("cool"), .acknowledgement)
        XCTAssertEqual(PromptInbox.replyKind("no thanks"), .acknowledgement)
        XCTAssertEqual(PromptInbox.replyKind("yes but use rebase"), .request)
        XCTAssertEqual(PromptInbox.replyKind("thanks a lot for all of this today"), .request, "Long: let Claude decide")
        XCTAssertTrue(PromptInbox.contextOffersSomething("Should I merge it into main"))
        XCTAssertFalse(PromptInbox.contextOffersSomething("Merged into main."))
    }
}

final class SkillWriterTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    let intent = TrackedIntent(id: "1", slug: "commit-and-push", summary: "Commit all changes and push",
                               sightings: [.init(prompt: "commit and push", sessionID: "A", date: Date())], status: .tracking)

    func testUsesClaudeDraftAndForcesName() async throws {
        let draft = "```markdown\n---\nname: something-else\ndescription: Commits and pushes.\n---\n1. Run git status.\n```"
        let writer = SkillWriter(skillsDirectory: dir, claude: ScriptedClaude([.success(draft)]))
        let name = try await writer.write(for: intent)
        XCTAssertEqual(name, "gooby-commit-and-push")
        let text = try String(contentsOf: dir.appendingPathComponent("gooby-commit-and-push/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(text, "---\nname: gooby-commit-and-push\ndescription: Commits and pushes.\n---\n1. Run git status.\n")
    }

    func testFallsBackToTemplateAndNeverOverwrites() async throws {
        let failing = SkillWriter(skillsDirectory: dir, claude: ScriptedClaude([.failure(ClaudeCLIError.timedOut)]))
        let first = try await failing.write(for: intent)
        let noFrontmatter = SkillWriter(skillsDirectory: dir, claude: ScriptedClaude([.success("Here you go: do git stuff")]))
        let second = try await noFrontmatter.write(for: intent)
        XCTAssertEqual([first, second], ["gooby-commit-and-push", "gooby-commit-and-push-2"])
        let text = try String(contentsOf: dir.appendingPathComponent("gooby-commit-and-push-2/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: gooby-commit-and-push-2\ndescription: Commit all changes and push"))
        XCTAssertTrue(text.contains("- \"commit and push\""))
    }
}

@MainActor
final class SkillCoachTests: XCTestCase {
    var dir: URL!
    /// Event times: base + n seconds, so order and offer windows are deterministic.
    let base: TimeInterval = 1_900_000_000

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("inbox"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ input: [String: String], n: Int, at seconds: TimeInterval? = nil) throws {
        let url = dir.appendingPathComponent("inbox/\(n)-1.json")
        try JSONSerialization.data(withJSONObject: input).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: base + (seconds ?? Double(n)))],
                                              ofItemAtPath: url.path)
    }

    private func drop(_ prompt: String, session: String, n: Int, transcript: URL? = nil, at seconds: TimeInterval? = nil,
                      tty: String? = nil) throws {
        var input = ["session_id": session, "prompt": prompt, "cwd": dir.path]
        if let transcript { input["transcript_path"] = transcript.path }
        guard let tty else { return try write(input, n: n, at: seconds) }
        // The current hook wraps the hook JSON with the chat's Terminal tab.
        let url = dir.appendingPathComponent("inbox/\(n)-1.json")
        let wrapped: [String: Any] = ["gooby_tty": tty, "hook": input]
        try JSONSerialization.data(withJSONObject: wrapped).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: base + (seconds ?? Double(n)))],
                                              ofItemAtPath: url.path)
    }

    /// Claude finished replying in `session` (Stop hook).
    private func dropStop(session: String, n: Int, transcript: URL? = nil, at seconds: TimeInterval? = nil) throws {
        var input = ["session_id": session, "hook_event_name": "Stop"]
        if let transcript { input["transcript_path"] = transcript.path }
        try write(input, n: n, at: seconds)
    }

    /// What the coach thinks "now" is (event times are base + n).
    var now: TimeInterval = 0

    private func makeCoach(claude: ClaudeCompleting, presenter: RecordingPresenter,
                           installed: [InstalledSkill] = [], locator: TerminalTabLocating? = nil) -> SkillCoach {
        SkillCoach(
            inbox: PromptInbox(directory: dir.appendingPathComponent("inbox")),
            storeFile: IntentStoreFile(url: dir.appendingPathComponent("intents.json")),
            retryFile: RetryQueueFile(url: dir.appendingPathComponent("retry.json")),
            classifier: IntentClassifier(claude: claude),
            writer: SkillWriter(skillsDirectory: dir.appendingPathComponent("skills"), claude: claude),
            coverage: CoverageChecker(claude: claude),
            installedSkills: { _ in installed },
            tabLocator: locator,
            clock: { [unowned self] in Date(timeIntervalSince1970: self.base + self.now) },
            presenter: presenter
        )
    }

    /// Asks for commit-and-push in sessions 1...count (one prompt + Stop each).
    private func repeatInSessions(_ count: Int, startN: Int = 0) throws {
        for i in 1...count {
            try drop("commit and push", session: "s\(i)", n: startN + i * 10)
            try dropStop(session: "s\(i)", n: startN + i * 10 + 1)
        }
    }

    /// The product owner's example wordings, spread over independent sessions until the threshold (5).
    func testRewordedRequestsAcrossSessionsOfferAndCreateSkill() async throws {
        let presenter = RecordingPresenter()
        let coach = makeCoach(claude: SameIntentClaude(), presenter: presenter)
        let wordings = ["commit and push to my repo", "commit and push", "commit all changes and push",
                        "commit everything and push it", "please commit and push"]
        XCTAssertEqual(wordings.count, IntentStore.offerThreshold)

        try drop(wordings[0], session: "session-1", n: 1)
        try drop(wordings[1], session: "session-2", n: 2)
        try drop("yes", session: "session-2", n: 3) // filtered locally (no transcript)
        try drop(wordings[1], session: "session-2", n: 4) // same session again: counts once
        for i in 2..<(wordings.count - 1) { try drop(wordings[i], session: "session-\(i + 1)", n: 10 + i) }
        try dropStop(session: "session-4", n: 20)
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty, "One session short of the threshold")

        try drop(wordings.last!, session: "session-\(wordings.count)", n: 99)
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty, "Threshold reached, but Claude hasn't finished yet")
        try dropStop(session: "session-\(wordings.count)", n: 100)
        await coach.processInbox()
        XCTAssertEqual(presenter.offers.count, 1, "Offered right after Claude finished the 5th repeat")
        XCTAssertEqual(presenter.offers.first?.skillName, "gooby-commit-and-push")
        XCTAssertEqual(presenter.offers.first?.sessionCount, IntentStore.offerThreshold)

        let offer = try XCTUnwrap(presenter.offers.first)
        await coach.answer(intentID: offer.intentID, .accept)
        XCTAssertEqual(presenter.messages.last, "Made /gooby-commit-and-push. Try it in a new chat!")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("skills/gooby-commit-and-push/SKILL.md").path))

        // Saved across launches, and another repeat never re-offers.
        let relaunched = makeCoach(claude: SameIntentClaude(), presenter: RecordingPresenter())
        XCTAssertEqual(relaunched.store.intents.first?.status, .created)
        try drop("commit and push pls", session: "session-later", n: 200)
        try dropStop(session: "session-later", n: 201)
        await relaunched.processInbox()
        XCTAssertEqual(relaunched.store.intents.count, 1, "Repeat absorbed, no duplicate intent")
    }

    func testOfferWaitsForTheRightSessionAndMoment() async throws {
        let presenter = RecordingPresenter()
        let coach = makeCoach(claude: SameIntentClaude(), presenter: presenter)
        try repeatInSessions(IntentStore.offerThreshold - 1)
        try drop("commit and push", session: "s5", n: 500)
        try dropStop(session: "other-session", n: 501) // Claude finished somewhere else
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty, "A Stop in an unrelated session doesn't trigger the offer")

        try dropStop(session: "s5", n: 502, at: 500 + SkillCoach.offerWindow + 1)
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty, "Too long after the repeat: the moment has passed")

        try drop("commit and push", session: "s6", n: 600, at: 10_000)
        try dropStop(session: "s6", n: 601, at: 10_030)
        await coach.processInbox()
        XCTAssertEqual(presenter.offers.count, 1, "Offered at the next repeat instead")
    }

    func testExpiredOfferIsNotADeclineAndComesBack() async throws {
        let presenter = RecordingPresenter()
        let coach = makeCoach(claude: SameIntentClaude(), presenter: presenter)
        try repeatInSessions(IntentStore.offerThreshold)
        await coach.processInbox()
        let offer = try XCTUnwrap(presenter.offers.first)
        await coach.answer(intentID: offer.intentID, .expired)
        XCTAssertEqual(coach.store.intent(id: offer.intentID)?.status, .tracking)
        XCTAssertNil(coach.offerOnScreen)

        try drop("commit and push", session: "s9", n: 900)
        try dropStop(session: "s9", n: 901)
        await coach.processInbox()
        XCTAssertEqual(presenter.offers.count, 2)
    }

    func testAlreadyCoveredSkillIsNeverOffered() async throws {
        let presenter = RecordingPresenter()
        let installed = [InstalledSkill(name: "ship-it", description: "Commit everything and push", path: "/x/SKILL.md")]
        let claude = ScriptedCoverageClaude(coverageReply: #"{"covered":true,"by":"ship-it"}"#)
        let coach = makeCoach(claude: claude, presenter: presenter, installed: installed)
        try repeatInSessions(IntentStore.offerThreshold)
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty)
        let intent = try XCTUnwrap(coach.store.intents.first)
        XCTAssertEqual(intent.status, .covered)
        XCTAssertEqual(intent.coveredBy, "ship-it")
        XCTAssertTrue(claude.coveragePrompts.first?.contains("- ship-it: Commit everything and push") == true)
    }

    func testUnreadableCoverageAnswerHoldsTheOfferForLater() async throws {
        let presenter = RecordingPresenter()
        let installed = [InstalledSkill(name: "ship-it", description: "Deploys", path: "/x/SKILL.md")]
        let claude = ScriptedCoverageClaude(coverageReply: "hmm, not sure")
        let coach = makeCoach(claude: claude, presenter: presenter, installed: installed)
        try repeatInSessions(IntentStore.offerThreshold)
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty, "Unknown: don't offer now")
        XCTAssertEqual(coach.store.intents.first?.status, .tracking, "…but don't give up either")

        claude.coverageReply = #"{"covered":false}"#
        try drop("commit and push", session: "s7", n: 700)
        try dropStop(session: "s7", n: 701)
        await coach.processInbox()
        XCTAssertEqual(presenter.offers.count, 1)
    }

    func testTraceOfWhatClaudeDidIsCapturedAndUsedForTheSkill() async throws {
        let transcript = dir.appendingPathComponent("s1.jsonl")
        func iso(_ t: TimeInterval) -> String {
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: base + t))
        }
        let log = [
            #"{"type":"user","timestamp":"\#(iso(10))","message":{"role":"user","content":"commit and push"}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(11))","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status --short"}}]}}"#,
            #"{"type":"user","timestamp":"\#(iso(12))","message":{"content":[{"type":"tool_result","content":"M a.swift"}]}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(13))","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git add -A && git commit -m \"wip\" && git push"}}]}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(14))","message":{"content":[{"type":"text","text":"Committed and pushed to origin/main."}]}}"#,
        ].joined(separator: "\n")
        try Data(log.utf8).write(to: transcript)

        let claude = TraceCheckingClaude()
        let presenter = RecordingPresenter()
        let coach = makeCoach(claude: claude, presenter: presenter)
        try drop("commit and push", session: "s1", n: 10, transcript: transcript)
        try dropStop(session: "s1", n: 15, transcript: transcript)
        for i in 2...IntentStore.offerThreshold {
            try drop("commit and push", session: "s\(i)", n: i * 100)
            try dropStop(session: "s\(i)", n: i * 100 + 1)
        }
        await coach.processInbox()
        let trace = try XCTUnwrap(coach.store.intents.first?.sightings.first?.trace)
        XCTAssertEqual(trace, """
        - Bash: git status --short
        - Bash: git add -A && git commit -m "wip" && git push
        Final reply (end): Committed and pushed to origin/main.
        """)

        let offer = try XCTUnwrap(presenter.offers.first)
        await coach.answer(intentID: offer.intentID, .accept)
        let draftPrompt = try XCTUnwrap(claude.draftPrompts.first)
        XCTAssertTrue(draftPrompt.contains("What the assistant did that time:\n- Bash: git status --short"))
        XCTAssertTrue(draftPrompt.contains("global skill used in many different projects"))
    }

    func testOfferWaitsUntilTheChatsOwnTabIsInFront() async throws {
        let presenter = RecordingPresenter()
        let locator = FakeTabLocator(.elsewhere)
        let transcript = dir.appendingPathComponent("s5.jsonl")
        try Data(#"{"type":"ai-title","aiTitle":"Ship the release"}"#.utf8).write(to: transcript)
        let coach = makeCoach(claude: SameIntentClaude(), presenter: presenter, locator: locator)
        try repeatInSessions(IntentStore.offerThreshold - 1)
        try drop("commit and push", session: "s5", n: 500, transcript: transcript, tty: "ttys007")
        try dropStop(session: "s5", n: 501)
        now = 501
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty, "Chat's tab isn't in front: wait")
        XCTAssertNotNil(coach.pending)
        XCTAssertEqual(locator.asked.last, "ttys007")

        now = 600
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty, "Still elsewhere")

        locator.placement = .front
        now = 700
        await coach.processInbox()
        XCTAssertEqual(presenter.offers.count, 1, "Shown once the user is back in that chat")
        XCTAssertNil(coach.pending)
        XCTAssertEqual(presenter.offers.first?.chatLabel, "In your “Ship the release” chat (\(dir.lastPathComponent))")
    }

    func testWaitingOfferGivesUpAfterTheWindowAndReturnsLater() async throws {
        let presenter = RecordingPresenter()
        let locator = FakeTabLocator(.elsewhere)
        let coach = makeCoach(claude: SameIntentClaude(), presenter: presenter, locator: locator)
        try repeatInSessions(IntentStore.offerThreshold - 1)
        try drop("commit and push", session: "s5", n: 500, tty: "ttys007")
        try dropStop(session: "s5", n: 501)
        now = 501
        await coach.processInbox()
        now = 500 + SkillCoach.offerWindow + 1
        locator.placement = .front
        await coach.processInbox()
        XCTAssertTrue(presenter.offers.isEmpty, "Too late: dropped quietly")
        XCTAssertNil(coach.pending)
        XCTAssertEqual(coach.store.intents.first?.status, .tracking, "Not a decline")

        try drop("commit and push", session: "s6", n: 9000, tty: "ttys008")
        try dropStop(session: "s6", n: 9001)
        now = 9001
        await coach.processInbox()
        XCTAssertEqual(presenter.offers.count, 1, "Back at the next repeat")
    }

    func testUnknownPlacementShowsTheOfferLabeled() async throws {
        for placement in [TabPlacement.notInTerminal, .unavailable] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("intents.json"))
            let presenter = RecordingPresenter()
            let coach = makeCoach(claude: SameIntentClaude(), presenter: presenter, locator: FakeTabLocator(placement))
            try repeatInSessions(IntentStore.offerThreshold - 1)
            try drop("commit and push", session: "s5", n: 500, tty: "ttys009")
            try dropStop(session: "s5", n: 501)
            now = 501
            await coach.processInbox()
            XCTAssertEqual(presenter.offers.count, 1, "\(placement): can't tell where the chat is, so show it")
            XCTAssertEqual(presenter.offers.first?.chatLabel, "In a chat in \(dir.lastPathComponent)", "Labeled with the folder")
        }
    }

    func testTraceComesFromTheHooksLogCopyWhenTheRealLogIsGone() async throws {
        let gone = dir.appendingPathComponent("deleted.jsonl").path
        func iso(_ t: TimeInterval) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: base + t)) }
        let copy = [
            #"{"type":"user","timestamp":"\#(iso(10))","message":{"content":"commit and push"}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(11))","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git push"}}]}}"#,
        ].joined(separator: "\n")
        let coach = makeCoach(claude: SameIntentClaude(), presenter: RecordingPresenter())
        try drop("commit and push", session: "s1", n: 10, transcript: URL(fileURLWithPath: gone))
        try dropStop(session: "s1", n: 12, transcript: URL(fileURLWithPath: gone))
        try Data(copy.utf8).write(to: dir.appendingPathComponent("inbox/12-1.tail.jsonl"))
        await coach.processInbox()
        XCTAssertEqual(coach.store.intents.first?.sightings.first?.trace, "- Bash: git push")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("inbox/12-1.tail.jsonl").path),
                       "Log copy deleted once used")
    }

    func testShortYesAfterClaudesOfferCountsAsThatRequest() async throws {
        let transcript = dir.appendingPathComponent("s2.jsonl")
        try Data(#"{"type":"assistant","timestamp":"2020-01-01T00:00:00Z","message":{"content":[{"type":"text","text":"Want me to commit and push?"}]}}"#.utf8)
            .write(to: transcript)
        let claude = ScriptedClaude([
            .success(#"{"kind":"new","slug":"commit-and-push","summary":"Commit and push","request":"commit and push"}"#),
        ])
        let coach = makeCoach(claude: claude, presenter: RecordingPresenter())
        try drop("commit and push", session: "s1", n: 1)
        await coach.processInbox()
        let id = try XCTUnwrap(coach.store.intents.first?.id)
        let matchReply = #"{"kind":"match","id":"\#(id)","confidence":0.95,"request":"commit and push"}"#
        let second = ScriptedClaude([.success(matchReply)])
        let coach2 = makeCoach(claude: second, presenter: RecordingPresenter())
        try drop("yes", session: "s2", n: 2, transcript: transcript)
        try drop("ok", session: "s3", n: 3) // no transcript: filtered, no Claude call
        await coach2.processInbox()
        XCTAssertEqual(coach2.store.intent(id: id)?.distinctSessionCount, 2)
        XCTAssertEqual(coach2.store.intent(id: id)?.sightings.last?.prompt, "commit and push")
        XCTAssertEqual(second.prompts.count, 1, "Bare \"ok\" with no context never reaches Claude")
        XCTAssertTrue(second.prompts.first?.contains("Want me to commit and push?") == true, "Claude saw the context")
    }

    func testDeclineStopsOffers() async throws {
        let presenter = RecordingPresenter()
        let coach = makeCoach(claude: SameIntentClaude(), presenter: presenter)
        try repeatInSessions(IntentStore.offerThreshold)
        await coach.processInbox()
        let offer = try XCTUnwrap(presenter.offers.first)
        await coach.answer(intentID: offer.intentID, .decline)
        try drop("commit and push", session: "s-extra", n: 999)
        try dropStop(session: "s-extra", n: 1000)
        await coach.processInbox()
        XCTAssertEqual(presenter.offers.count, 1)
        XCTAssertEqual(coach.store.intents.first?.status, .declined)
    }

    func testClaudeFailureQueuesThePromptAndRetriesLater() async throws {
        let failing = ScriptedClaude([.failure(ClaudeCLIError.claudeError("not logged in"))])
        let coach = makeCoach(claude: failing, presenter: RecordingPresenter())
        try drop("commit and push", session: "a", n: 1)
        await coach.processInbox()
        XCTAssertTrue(coach.store.intents.isEmpty)
        XCTAssertEqual(coach.retries.entries.count, 1, "Kept for retry, not dropped")
        XCTAssertEqual(coach.retries.entries.first?.attempts, 1)
        // Not due yet: no second call.
        now = 30
        await coach.processInbox()
        XCTAssertEqual(failing.prompts.count, 1)
        // 1 min later Claude works again (ScriptedClaude falls back to replies after the failure).
        now = 70
        await coach.processInbox()
        XCTAssertEqual(failing.prompts.count, 2, "Retried after the 1-minute backoff")
        XCTAssertTrue(coach.retries.isEmpty)
        XCTAssertNil(coach.claudeUnavailableUntil)
    }

    func testRetriedPromptCountsAsASighting() async throws {
        let claude = ScriptedClaude([
            .failure(ClaudeCLIError.timedOut),
            .success(#"{"kind":"new","slug":"commit-and-push","summary":"Commit and push","request":"commit and push"}"#),
        ])
        let coach = makeCoach(claude: claude, presenter: RecordingPresenter())
        try drop("commit and push", session: "a", n: 1)
        await coach.processInbox()
        now = 70
        await coach.processInbox()
        XCTAssertEqual(coach.store.intents.first?.slug, "commit-and-push")
        XCTAssertEqual(coach.store.intents.first?.sightings.first?.date, Date(timeIntervalSince1970: base + 1),
                       "Keeps the original ask time")
    }

    func testAfterAFailureNewPromptsWaitInsteadOfCallingClaude() async throws {
        let claude = ScriptedClaude([.failure(ClaudeCLIError.timedOut)])
        let coach = makeCoach(claude: claude, presenter: RecordingPresenter())
        try drop("commit and push", session: "a", n: 1)
        try drop("run the tests", session: "b", n: 2)
        try drop("open a merge request", session: "c", n: 3)
        await coach.processInbox()
        XCTAssertEqual(claude.prompts.count, 1, "Only one call waits out a broken Claude")
        XCTAssertEqual(coach.retries.entries.map(\.prompt), ["commit and push", "run the tests", "open a merge request"])
        XCTAssertEqual(coach.retries.entries.map(\.attempts), [1, 0, 0], "Deferred prompts didn't use a try")
    }

    func testGivesUpAfterFourFailedTries() async throws {
        let failures: [Result<String, Error>] = Array(repeating: .failure(ClaudeCLIError.noResult(exitCode: 127)), count: 6)
        let claude = ScriptedClaude(failures)
        let coach = makeCoach(claude: claude, presenter: RecordingPresenter())
        try drop("commit and push", session: "a", n: 1)
        let times: [TimeInterval] = [0, 61, 61 + 301, 61 + 301 + 1801, 61 + 301 + 1801 + 3600]
        for t in times {
            now = t
            await coach.processInbox()
        }
        XCTAssertEqual(claude.prompts.count, 4, "1 try + 3 retries (1 min, 5 min, 30 min)")
        XCTAssertTrue(coach.retries.isEmpty, "Dropped after the last retry")
    }

    func testRetriesSurviveRestartingGooby() async throws {
        let coach = makeCoach(claude: ScriptedClaude([.failure(ClaudeCLIError.timedOut)]), presenter: RecordingPresenter())
        try drop("commit and push", session: "a", n: 1)
        await coach.processInbox()
        let second = ScriptedClaude([])
        let restarted = makeCoach(claude: second, presenter: RecordingPresenter())
        XCTAssertEqual(restarted.retries.entries.count, 1, "Loaded from disk")
        now = 70
        await restarted.processInbox()
        XCTAssertEqual(second.prompts.count, 1)
        XCTAssertTrue(second.prompts[0].contains("commit and push"))
    }
}

final class FakeTabLocator: TerminalTabLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var _placement: TabPlacement
    private(set) var asked: [String] = []
    var placement: TabPlacement {
        get { lock.withLock { _placement } }
        set { lock.withLock { _placement = newValue } }
    }
    init(_ placement: TabPlacement) { _placement = placement }
    func placement(ofTTY tty: String) async -> TabPlacement {
        lock.withLock { asked.append(tty); return _placement }
    }
}

/// Like SameIntentClaude, but with a settable answer to the coverage question.
final class ScriptedCoverageClaude: ClaudeCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private let same = SameIntentClaude()
    private var _reply: String
    private(set) var coveragePrompts: [String] = []
    var coverageReply: String {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    init(coverageReply: String) { _reply = coverageReply }

    func complete(_ prompt: String) async throws -> String {
        if prompt.hasPrefix("A developer keeps asking") {
            return lock.withLock { coveragePrompts.append(prompt); return _reply }
        }
        return try await same.complete(prompt)
    }
}

/// Like SameIntentClaude, but records skill-drafting prompts.
final class TraceCheckingClaude: ClaudeCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private let same = SameIntentClaude()
    private(set) var draftPrompts: [String] = []

    func complete(_ prompt: String) async throws -> String {
        if prompt.hasPrefix("Write a Claude Code skill") {
            lock.withLock { draftPrompts.append(prompt) }
            return "---\nname: x\ndescription: Commit and push.\n---\n1. Check status.\n"
        }
        return try await same.complete(prompt)
    }
}

final class SkillCatalogTests: XCTestCase {
    func testFindsUserPluginAndProjectSkillsAndCommands() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = home.appendingPathComponent("work/repo")
        defer { try? FileManager.default.removeItem(at: home) }
        func put(_ rel: String, _ text: String, under root: URL) throws {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try put(".claude/skills/ship/SKILL.md", "---\nname: ship\ndescription: \"Commit and push\"\n---\nbody", under: home)
        try put(".claude/commands/review.md", "# Review the diff\nsteps", under: home)
        try put(".claude/plugins/cache/acme/tools/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Deploy it\n---", under: home)
        try put(".claude/plugins/cache/acme/node_modules/x/skills/junk/SKILL.md", "---\nname: junk\n---", under: home)
        try put(".claude/skills/release/SKILL.md", "---\nname: release\ndescription: Cut a release\n---", under: project)

        let found = SkillCatalog.installed(home: home, projectDirectories: [project.path])
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.description) })
        XCTAssertEqual(byName["ship"], "Commit and push", "Quotes stripped")
        XCTAssertEqual(byName["review"], "Review the diff", "Command without frontmatter: first line")
        XCTAssertEqual(byName["deploy"], "Deploy it")
        XCTAssertEqual(byName["release"], "Cut a release", "Project skill")
        XCTAssertNil(byName["junk"], "node_modules skipped")
        XCTAssertTrue(SkillCatalog.installed(home: home.appendingPathComponent("nope")).isEmpty)
    }

    func testCoverageParse() {
        let names: Set<String> = ["ship"]
        XCTAssertEqual(CoverageChecker.parse(#"{"covered":true,"by":"/ship"}"#, names: names), .covered(by: "ship"))
        XCTAssertEqual(CoverageChecker.parse(#"{"covered":false}"#, names: names), .notCovered)
        XCTAssertEqual(CoverageChecker.parse(#"{"covered":true,"by":"made-up"}"#, names: names), .unknown, "Unknown name")
        XCTAssertEqual(CoverageChecker.parse("no idea", names: names), .unknown)
    }
}

final class SkillOfferBubbleTests: XCTestCase {
    func testOriginAboveGoobyClampedToScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let bubble = CGSize(width: 258, height: 100)
        let mid = SkillOfferBubble.origin(bubble: bubble, gooby: CGRect(x: 400, y: 100, width: 80, height: 80), screen: screen)
        XCTAssertEqual(mid, CGPoint(x: 311, y: 182))
        let right = SkillOfferBubble.origin(bubble: bubble, gooby: CGRect(x: 950, y: 100, width: 50, height: 50), screen: screen)
        XCTAssertEqual(right.x, 742, "Kept on screen")
        let top = SkillOfferBubble.origin(bubble: bubble, gooby: CGRect(x: 400, y: 750, width: 50, height: 50), screen: screen)
        XCTAssertEqual(top.y, 648, "Flips below when no room above")
    }
}

/// Calls real `claude -p`. Opt-in: TEST_RUNNER_GOOBY_LIVE_CLAUDE=1 xcodebuild ... test
@MainActor
final class LiveClaudeIntentTests: XCTestCase {
    func testProductOwnerExampleMatchesWithRealClaude() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOOBY_LIVE_CLAUDE"] == "1", "Live Claude test is opt-in")
        let classifier = IntentClassifier(claude: ClaudeCLI())
        var store = IntentStore()
        let offerToPush = "I fixed the failing test and the build passes. Want me to commit these changes and push them to your repo?"
        let script: [(prompt: String, session: String, context: String?)] = [
            ("commit and push to my repo", "s1", nil),
            ("can you explain what this regex does: ^a+$", "s1", nil),
            ("thanks!", "s1", "It matches one or more a's and nothing else."),
            ("run the unit tests and fix any failures", "s2", nil),
            ("yes go ahead", "s2", offerToPush),
            ("commit all changes and push", "s3", nil),
        ]
        for step in script {
            let result = try await classifier.classify(prompt: step.prompt, context: step.context, against: store.intents)
            print("LIVE: \(step.prompt) -> \(result)")
            let example = result.request ?? step.prompt
            switch result.verdict {
            case .ignore: break
            case let .match(id, _): store.recordSighting(intentID: id, prompt: example, sessionID: step.session, date: Date())
            case let .new(slug, summary): store.addIntent(slug: slug, summary: summary, prompt: example, sessionID: step.session, date: Date())
            }
        }
        XCTAssertFalse(store.intents.flatMap(\.sightings).contains { $0.prompt == "yes go ahead" }, "Saved restated, not raw")
        // Matching quality check (the offer itself needs IntentStore.offerThreshold sessions).
        let commit = try XCTUnwrap(store.intents.first { $0.slug.contains("commit") }, "A commit-and-push intent exists")
        print("LIVE intent: /gooby-\(commit.slug) — \(commit.summary), \(commit.distinctSessionCount) sessions")
        XCTAssertEqual(commit.distinctSessionCount, 3, "All three wordings, incl. \"yes go ahead\" in s2, matched")
        XCTAssertNil(store.nextOffer, "3 sessions is below the threshold of 5")
    }
}

final class TranscriptContextTests: XCTestCase {
    private func line(_ type: String, _ time: String, _ blocks: String, sidechain: Bool = false) -> String {
        #"{"type":"\#(type)","timestamp":"\#(time)","isSidechain":\#(sidechain),"message":{"role":"\#(type)","content":\#(blocks)}}"#
    }

    func testPicksLastMainAssistantTextBeforePrompt() throws {
        let promptTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-11T20:00:00Z"))
        let jsonl = [
            #"{"type":"assistant","timestam"#, // line cut by the byte limit
            line("assistant", "2026-11-11T19:58:00.100Z", #"[{"type":"text","text":"Old message"}]"#),
            line("assistant", "2026-11-11T19:59:00.250Z", #"[{"type":"text","text":"Tests pass."},{"type":"text","text":"Want me to commit and push?"}]"#),
            line("assistant", "2026-11-11T19:59:10.000Z", #"[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"t"}]"#),
            line("assistant", "2026-11-11T19:59:20.000Z", #"[{"type":"text","text":"subagent chatter"}]"#, sidechain: true),
            #"{"type":"user","timestamp":"2026-11-11T20:00:00Z","message":{"role":"user","content":"yes"}}"#,
            line("assistant", "2026-11-11T20:00:05.000Z", #"[{"type":"text","text":"Committed and pushed."}]"#),
        ].joined(separator: "\n")
        XCTAssertEqual(TranscriptContext.lastAssistantText(inJSONL: jsonl, before: promptTime),
                       "Tests pass.\nWant me to commit and push?", "Skips later, sidechain, text-less and cut lines")
        XCTAssertNil(TranscriptContext.lastAssistantText(inJSONL: jsonl, before: .distantPast))
        XCTAssertNil(TranscriptContext.lastAssistantText(inJSONL: "garbage", before: promptTime))
    }

    func testKeepsTheEndOfLongMessagesAndReadsFiles() throws {
        let long = String(repeating: "x", count: 5000) + " Want me to push?"
        let jsonl = line("assistant", "2026-11-11T19:59:00Z", #"[{"type":"text","text":"\#(long)"}]"#)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(jsonl.utf8).write(to: url)
        let text = try XCTUnwrap(TranscriptContext.lastAssistantText(transcript: url, before: Date()))
        XCTAssertEqual(text.count, TranscriptContext.maxContextLength + 1)
        XCTAssertTrue(text.hasSuffix("Want me to push?"))
        XCTAssertNil(TranscriptContext.lastAssistantText(transcript: url.appendingPathExtension("missing"), before: Date()))
    }

    func testInstructionsCarryContextOnlyWhenGiven() {
        XCTAssertTrue(IntentClassifier.instructions(prompt: "yes", context: "Want me to push?", intents: []).contains("Want me to push?"))
        XCTAssertFalse(IntentClassifier.instructions(prompt: "yes", intents: []).contains("message right before"))
    }

    func testParseKeepsRestatedRequest() {
        let r = IntentClassifier.parse(#"{"kind":"new","slug":"commit-and-push","summary":"Commit and push","request":"commit and push"}"#, knownIDs: [])
        XCTAssertEqual(r.request, "commit and push")
        XCTAssertNil(IntentClassifier.parse(#"{"kind":"new","slug":"s","summary":"S","request":"  "}"#, knownIDs: []).request)
    }
}

final class ActionTraceTests: XCTestCase {
    func testTraceStopsAtNextPromptAndSkipsSidechainsAndToolResults() throws {
        let jsonl = [
            #"{"type":"user","timestamp":"2026-11-11T10:00:00Z","message":{"content":"older prompt"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-11T10:00:01Z","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/old"}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-11T10:05:00.500Z","message":{"content":"commit and push"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-11T10:05:02Z","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"tool_use","name":"Bash","input":{"command":"git add -A\ngit commit -m x\ngit push\necho done"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-11T10:05:03Z","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"subagent stuff"}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-11T10:05:04Z","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-11T10:05:05Z","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/CHANGELOG.md"}},{"type":"text","text":"Done."}]}}"#,
            #"{"type":"user","timestamp":"2026-11-11T10:09:00Z","message":{"content":"next thing"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-11T10:09:01Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"later"}}]}}"#,
        ].joined(separator: "\n")
        let hookTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-11T10:05:01Z"))
        let trace = try XCTUnwrap(TranscriptContext.actionTrace(inJSONL: jsonl, promptDate: hookTime))
        XCTAssertTrue(trace.reachedNextPrompt)
        XCTAssertEqual(trace.text, """
        - Bash: git add -A ⏎ git commit -m x ⏎ git push
        - Edit: /repo/CHANGELOG.md
        Final reply (end): Done.
        """)
    }

    func testOpenTurnAndMissingPrompt() throws {
        let jsonl = #"{"type":"user","timestamp":"2026-11-11T10:05:00Z","message":{"content":"commit and push"}}"#
        let t = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-11T10:05:00Z"))
        let open = try XCTUnwrap(TranscriptContext.actionTrace(inJSONL: jsonl, promptDate: t))
        XCTAssertFalse(open.reachedNextPrompt)
        XCTAssertEqual(open.text, "- (no tool calls)")
        XCTAssertNil(TranscriptContext.actionTrace(inJSONL: jsonl, promptDate: t.addingTimeInterval(3600)), "Prompt not in log")
        XCTAssertNil(TranscriptContext.actionTrace(transcript: URL(fileURLWithPath: "/nope.jsonl"), promptDate: t))
    }

    func testLongTracesAreCapped() throws {
        var lines = [#"{"type":"user","timestamp":"2026-11-11T10:05:00Z","message":{"content":"go"}}"#]
        for i in 0..<50 {
            lines.append(#"{"type":"assistant","timestamp":"2026-11-11T10:05:01Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"step \#(i)"}}]}}"#)
        }
        let t = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-11T10:05:00Z"))
        let trace = try XCTUnwrap(TranscriptContext.actionTrace(inJSONL: lines.joined(separator: "\n"), promptDate: t))
        XCTAssertEqual(trace.text.split(separator: "\n").count, TranscriptContext.maxTraceLines + 1)
        XCTAssertTrue(trace.text.hasSuffix("- … 20 more steps"))
    }
}

final class TerminalTabLocatorTests: XCTestCase {
    func testParseAndDevicePath() {
        XCTAssertEqual(TerminalTabLocator.devicePath("ttys002"), "/dev/ttys002")
        XCTAssertEqual(TerminalTabLocator.devicePath("/dev/ttys002"), "/dev/ttys002")
        let t = "/dev/ttys002"
        XCTAssertEqual(TerminalTabLocator.parse("open,/dev/ttys002\n", target: t), .front)
        XCTAssertEqual(TerminalTabLocator.parse("open,/dev/ttys004", target: t), .elsewhere)
        XCTAssertEqual(TerminalTabLocator.parse("none,/dev/ttys004", target: t), .notInTerminal)
        XCTAssertEqual(TerminalTabLocator.parse("none,", target: t), .notInTerminal, "No Terminal windows")
        XCTAssertEqual(TerminalTabLocator.parse("", target: t), .unavailable)
        XCTAssertEqual(TerminalTabLocator.parse("weird,/dev/ttys004", target: t), .unavailable)
    }
}

final class InboxWrappedFormatTests: XCTestCase {
    func testReadsTTYAndAttachesLogCopiesOnlyToStop() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func put(_ name: String, _ text: String, at t: TimeInterval) throws {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: url.path)
        }
        try put("1-1.json", #"{"gooby_tty":"ttys002","hook":{"session_id":"s","prompt":"hi there","hook_event_name":"UserPromptSubmit"}}"#, at: 1)
        try put("1-1.tail.jsonl", "stray copy for a prompt event", at: 1)
        try put("2-1.json", #"{"gooby_tty":"","hook":{"session_id":"s","hook_event_name":"Stop"}}"#, at: 2)
        try put("2-1.tail.jsonl", "{}", at: 2)
        try put("9-9.tail.jsonl", "orphan", at: 3) // old, no event
        let events = PromptInbox(directory: dir).drain()
        guard events.count == 2, case let .prompt(p) = events[0], case let .turnEnded(t) = events[1] else {
            return XCTFail("unexpected \(events)")
        }
        XCTAssertEqual(p.tty, "ttys002")
        XCTAssertNil(t.tty, "Empty tty means unknown")
        XCTAssertEqual(t.logCopyPath, dir.appendingPathComponent("2-1.tail.jsonl").path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["2-1.tail.jsonl"],
                       "Prompt's stray copy and the old orphan removed; Stop's copy kept for the coach")
    }

    func testChatTitleAndLabel() throws {
        let jsonl = """
        {"type":"ai-title","aiTitle":"Old title"}
        {"type":"user","message":{"content":"x"}}
        {"type":"ai-title","aiTitle":"Fix the MR pipeline"}
        """
        XCTAssertEqual(TranscriptContext.lastTitle(inJSONL: jsonl), "Fix the MR pipeline")
        XCTAssertNil(TranscriptContext.lastTitle(inJSONL: "{}"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(jsonl.utf8).write(to: url)
        XCTAssertEqual(SkillCoach.chatLabel(cwd: "/Users/me/Gitlab/notes-app", transcriptPath: url.path),
                       "In your “Fix the MR pipeline” chat (notes-app)")
        XCTAssertEqual(SkillCoach.chatLabel(cwd: nil, transcriptPath: url.path), "In your “Fix the MR pipeline” chat")
        XCTAssertEqual(SkillCoach.chatLabel(cwd: "/Users/me/Gitlab/notes-app", transcriptPath: nil), "In a chat in notes-app")
        XCTAssertNil(SkillCoach.chatLabel(cwd: nil, transcriptPath: nil))
    }
}


final class RetryQueueTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    func prompt(_ n: Int) -> CapturedPrompt {
        CapturedPrompt(prompt: "p\(n)", sessionID: "s", date: t0.addingTimeInterval(Double(n)))
    }

    func testBackoffSchedule() {
        XCTAssertEqual(RetryQueue.delay(afterFailures: 1), 60)
        XCTAssertEqual(RetryQueue.delay(afterFailures: 2), 300)
        XCTAssertEqual(RetryQueue.delay(afterFailures: 3), 1800)
        XCTAssertNil(RetryQueue.delay(afterFailures: 4))
    }

    func testCapsAndExpiry() {
        var q = RetryQueue()
        for n in 0..<60 { q.add(prompt(n), context: nil, attempts: 1, nextAttempt: t0) }
        XCTAssertEqual(q.entries.count, RetryQueue.maxEntries, "Keeps the newest 50")
        XCTAssertEqual(q.entries.first?.prompt, "p10")
        XCTAssertTrue(q.takeDue(now: t0.addingTimeInterval(RetryQueue.maxAge + 100)).isEmpty, "All older than 24 h")
        XCTAssertTrue(q.isEmpty)
    }

    func testFileRoundTripAndEmptyQueueRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/retry.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = RetryQueueFile(url: url)
        var q = RetryQueue()
        q.add(prompt(1), context: "Want me to push?", attempts: 2, nextAttempt: t0)
        file.save(q)
        XCTAssertEqual(file.load(), q)
        file.save(RetryQueue())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
