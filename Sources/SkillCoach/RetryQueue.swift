import Foundation

/// A prompt whose Claude call failed (offline, login expired, timeout), kept for retry.
/// The context is stored too: the session log may be gone by the time we retry.
struct RetryEntry: Codable, Equatable {
    var prompt: String
    var sessionID: String
    var date: Date
    var transcriptPath: String?
    var cwd: String?
    var tty: String?
    var context: String?
    /// Failed Claude calls so far for this prompt.
    var attempts: Int
    var nextAttempt: Date

    var captured: CapturedPrompt {
        CapturedPrompt(prompt: prompt, sessionID: sessionID, date: date,
                       transcriptPath: transcriptPath, cwd: cwd, tty: tty)
    }
}

/// Prompts waiting to be classified again, with backoff and caps so a broken Claude
/// never piles up work or retries forever.
struct RetryQueue: Codable, Equatable {
    /// Wait after the 1st, 2nd, and 3rd failure. A 4th failure drops the prompt.
    static let backoff: [TimeInterval] = [60, 5 * 60, 30 * 60]
    static let maxEntries = 50
    /// Prompts older than this are dropped, retried or not.
    static let maxAge: TimeInterval = 24 * 60 * 60

    private(set) var entries: [RetryEntry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Delay before the next try after `attempts` failures, or nil once retries are used up.
    static func delay(afterFailures attempts: Int) -> TimeInterval? {
        guard attempts >= 1, attempts <= backoff.count else { return nil }
        return backoff[attempts - 1]
    }

    /// Queues a prompt. `attempts` = failed calls so far (0 when it was only deferred
    /// because Claude was known to be down). Returns false if it was dropped.
    @discardableResult
    mutating func add(_ captured: CapturedPrompt, context: String?, attempts: Int, nextAttempt: Date) -> Bool {
        guard attempts <= Self.backoff.count else { return false }
        entries.append(RetryEntry(prompt: captured.prompt, sessionID: captured.sessionID, date: captured.date,
                                  transcriptPath: captured.transcriptPath, cwd: captured.cwd, tty: captured.tty,
                                  context: context, attempts: attempts, nextAttempt: nextAttempt))
        entries.sort { $0.date < $1.date }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        return true
    }

    /// Removes and returns entries due at `now` (oldest prompt first); drops expired ones.
    mutating func takeDue(now: Date) -> [RetryEntry] {
        entries.removeAll { now.timeIntervalSince($0.date) > Self.maxAge }
        let due = entries.filter { $0.nextAttempt <= now }
        entries.removeAll { $0.nextAttempt <= now }
        return due
    }

    var nextAttempt: Date? { entries.map(\.nextAttempt).min() }
}

/// RetryQueue persisted as JSON next to the intent store (survives quitting Gooby).
struct RetryQueueFile {
    let url: URL

    func load() -> RetryQueue {
        guard let data = try? Data(contentsOf: url) else { return RetryQueue() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(RetryQueue.self, from: data)) ?? RetryQueue()
    }

    func save(_ queue: RetryQueue) {
        let fm = FileManager.default
        if queue.isEmpty { try? fm.removeItem(at: url); return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(queue) { try? data.write(to: url, options: .atomic) }
    }
}
