import Foundation

/// A prompt the user submitted in Claude Code, as dropped by hooks/gooby-capture-prompt.sh.
struct CapturedPrompt: Equatable {
    let prompt: String
    let sessionID: String
    let date: Date
    /// The session transcript (from the hook's `transcript_path`), used for context.
    var transcriptPath: String? = nil
    /// The folder the session runs in (hook's `cwd`), for finding project skills.
    var cwd: String? = nil
    /// The Terminal tab this chat runs in, e.g. "ttys002" (nil: unknown, or not in a terminal).
    var tty: String? = nil

    /// What Claude said just before this prompt, or nil if unknown.
    func precedingAssistantText() -> String? {
        guard let transcriptPath, !transcriptPath.isEmpty else { return nil }
        return TranscriptContext.lastAssistantText(transcript: URL(fileURLWithPath: transcriptPath), before: date)
    }
}

/// Claude finished replying in a session (Claude Code's Stop hook).
struct TurnEnded: Equatable {
    let sessionID: String
    let date: Date
    var transcriptPath: String? = nil
    var tty: String? = nil
    /// The hook's copy of the end of the session log (deleted once handled).
    var logCopyPath: String? = nil
}

enum InboxEvent: Equatable {
    case prompt(CapturedPrompt)
    case turnEnded(TurnEnded)
}

/// Folder of hook JSON files, one per event. Reading a file deletes it,
/// so prompt text stays on disk only until Gooby has looked at it.
struct PromptInbox {
    let directory: URL

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gooby", isDirectory: true)
    }

    static var defaultDirectory: URL { supportDirectory.appendingPathComponent("inbox", isDirectory: true) }

    /// Oldest first, by file time (file names only have whole seconds). Skips files still
    /// being written (dot-prefixed temp files). Unreadable or unknown files are deleted too.
    func drain() -> [InboxEvent] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let files: [(url: URL, date: Date)] = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { name in
                let url = directory.appendingPathComponent(name)
                let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
                return (url, date)
            }
            .sorted { ($0.date, $0.url.lastPathComponent) < ($1.date, $1.url.lastPathComponent) }
        var out: [InboxEvent] = []
        for file in files {
            let data = try? Data(contentsOf: file.url)
            try? fm.removeItem(at: file.url)
            let copy = Self.logCopyURL(for: file.url)
            guard let data, var event = Self.decode(data, date: file.date) else {
                try? fm.removeItem(at: copy)
                continue
            }
            if case var .turnEnded(turn) = event {
                if fm.fileExists(atPath: copy.path) { turn.logCopyPath = copy.path }
                event = .turnEnded(turn)
            } else {
                try? fm.removeItem(at: copy)
            }
            out.append(event)
        }
        let kept = Set(out.compactMap { event -> String? in
            if case let .turnEnded(t) = event { return t.logCopyPath }
            return nil
        })
        removeOrphanLogCopies(olderThan: 24 * 60 * 60, keeping: kept)
        return out
    }

    /// "<name>.json" -> "<name>.tail.jsonl", written by the hook on Stop.
    static func logCopyURL(for eventURL: URL) -> URL {
        eventURL.deletingPathExtension().appendingPathExtension("tail.jsonl")
    }

    /// Log copies whose event never arrived (e.g. hook killed mid-write).
    /// `keeping`: copies attached to events just returned (their .json is already gone).
    private func removeOrphanLogCopies(olderThan age: TimeInterval, keeping: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".tail.jsonl") {
            let url = directory.appendingPathComponent(name)
            let event = url.deletingPathExtension().deletingPathExtension().appendingPathExtension("json")
            guard !keeping.contains(url.path), !fm.fileExists(atPath: event.path),
                  let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
                  Date().timeIntervalSince(date) > age else { continue }
            try? fm.removeItem(at: url)
        }
    }

    static func decode(_ data: Data, date: Date) -> InboxEvent? {
        struct HookInput: Decodable {
            let session_id: String?
            let prompt: String?
            let transcript_path: String?
            let cwd: String?
            let hook_event_name: String?
        }
        /// Current hook output: the hook JSON wrapped with the chat's Terminal tab.
        struct Wrapped: Decodable {
            let gooby_tty: String?
            let hook: HookInput
        }
        let decoder = JSONDecoder()
        let input: HookInput
        var tty: String?
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            input = wrapped.hook
            tty = wrapped.gooby_tty
        } else if let plain = try? decoder.decode(HookInput.self, from: data) {
            input = plain // written by an older hook
        } else {
            return nil
        }
        tty = tty.flatMap { $0.isEmpty ? nil : $0 }
        let session = input.session_id ?? "unknown"
        if input.hook_event_name == "Stop" {
            return .turnEnded(TurnEnded(sessionID: session, date: date, transcriptPath: input.transcript_path, tty: tty))
        }
        guard let prompt = input.prompt else { return nil }
        return .prompt(CapturedPrompt(prompt: prompt, sessionID: session, date: date,
                                      transcriptPath: input.transcript_path, cwd: input.cwd, tty: tty))
    }

    /// Cheap local filter so obvious non-tasks never cost a Claude call.
    /// - Skills ("/…"), shell commands ("!…"), and empty prompts: never.
    /// - Pure thanks, praise, or no ("thanks", "perfect", "nope, not now"): never.
    /// - Short approvals ("yes", "ok", "go ahead"): only when Claude's message right before
    ///   offered or asked something, since "yes" to "Want me to commit and push?" is a
    ///   commit-and-push request, but "yes" after a plain statement is not a task.
    /// - Anything else: when it is at least 6 characters, or when Claude spoke first.
    static func isWorthClassifying(_ prompt: String, context: String?) -> Bool {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, first != "/", first != "!" else { return false }
        switch replyKind(t) {
        case .acknowledgement:
            return false
        case .approval:
            return context.map(contextOffersSomething) ?? false
        case .request:
            return t.count >= 6 || context != nil
        }
    }

    enum ReplyKind: Equatable {
        /// Thanks, praise, or no: never a task.
        case acknowledgement
        /// Agreeing to something ("yes", "sure, go ahead"): a task only if Claude offered one.
        case approval
        /// Anything with real content.
        case request
    }

    static let approvalWords: Set<String> = [
        "yes", "y", "yep", "yeah", "yup", "ya", "sure", "ok", "okay", "k", "kk", "go", "ahead", "do", "it",
        "please", "pls", "proceed", "continue", "approve", "approved", "confirm", "confirmed", "lgtm", "ship",
        "lets", "let's", "sounds", "that", "for", "alright", "fine", "absolutely", "definitely", "yea",
    ]
    static let acknowledgementWords: Set<String> = [
        "thanks", "thank", "you", "ty", "thx", "tysm", "nice", "great", "cool", "perfect", "awesome",
        "amazing", "excellent", "good", "job", "well", "done", "love", "looks", "lol", "haha", "wow",
        "sweet", "neat", "got", "hmm", "interesting", "beautiful", "works", "worked",
        "no", "nope", "nah", "not", "now", "stop", "wait", "cancel", "dont", "don't", "never", "mind",
    ]
    /// Agreeing words that alone make a reply an approval (not just "cool").
    static let strongApprovalWords: Set<String> = [
        "yes", "y", "yep", "yeah", "yup", "ya", "yea", "sure", "ok", "okay", "k", "kk", "go", "do", "please",
        "pls", "proceed", "continue", "approve", "approved", "confirm", "confirmed", "lgtm", "ship",
        "absolutely", "definitely", "alright",
    ]
    /// Longer than this is never "just a short reply".
    static let shortReplyMaxWords = 6

    static func replyKind(_ prompt: String) -> ReplyKind {
        let words = prompt.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
        guard !words.isEmpty, words.count <= shortReplyMaxWords else { return words.isEmpty ? .acknowledgement : .request }
        let known = approvalWords.union(acknowledgementWords)
        guard words.allSatisfy(known.contains) else { return .request }
        let negative: Set<String> = ["no", "nope", "nah", "not", "stop", "wait", "cancel", "dont", "don't", "never"]
        if words.contains(where: negative.contains) { return .acknowledgement }
        return words.contains(where: strongApprovalWords.contains) ? .approval : .acknowledgement
    }

    /// Did Claude's message end by offering or asking something? Looks at its last 400
    /// characters for a question mark or an offer phrase ("want me to", "should I", …).
    static func contextOffersSomething(_ context: String) -> Bool {
        let tail = String(context.suffix(400)).lowercased()
        if tail.contains("?") { return true }
        let phrases = ["want me to", "should i ", "shall i ", "do you want", "would you like", "ready to",
                       "ok to ", "okay to ", "let me know", "say the word", "if you want", "if you'd like",
                       "happy to", "i can "]
        return phrases.contains { tail.contains($0) }
    }
}
