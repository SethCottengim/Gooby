import Foundation

/// One request the user keeps making, e.g. "commit all changes and push".
struct TrackedIntent: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        /// Still counting sightings.
        case tracking
        /// The user said No; never offer again.
        case declined
        /// A /gooby-<slug> skill exists for it.
        case created
        /// An installed skill or command already does this; never offer.
        case covered
    }

    struct Sighting: Codable, Equatable {
        var prompt: String
        var sessionID: String
        var date: Date
        /// Session log, for reading what Claude did afterwards. Optional fields keep old files loading.
        var transcriptPath: String? = nil
        /// Folder the session ran in, for finding that project's own skills and commands.
        var cwd: String? = nil
        /// What Claude did for this request (tool calls + end of its reply), captured when the turn ended.
        var trace: String? = nil
    }

    var id: String
    var slug: String
    var summary: String
    var sightings: [Sighting]
    var status: Status
    /// Every session this intent was seen in. Kept apart from `sightings`, which is capped,
    /// so many repeats in one chat can't push older sessions out of the count.
    /// Optional so intents.json files written before this field still load.
    var sessionIDs: [String]? = nil
    /// The installed skill/command that already covers this intent (status `.covered`).
    var coveredBy: String? = nil

    /// Sessions are what count: asking several times in one chat is usually a retry, not a habit.
    var distinctSessionCount: Int { Set((sessionIDs ?? []) + sightings.map(\.sessionID)).count }
    var lastSeen: Date { sightings.map(\.date).max() ?? .distantPast }
}

/// The intents Gooby has seen, saved as JSON. Pure bookkeeping; no Claude calls.
struct IntentStore: Codable, Equatable {
    /// Distinct sessions an intent needs before Gooby offers a skill (product owner: 5, 2026-11-11).
    static let offerThreshold = 5
    /// Example prompts kept per intent (oldest dropped first).
    static let maxSightingsPerIntent = 8
    /// Prompts are truncated to this many characters before saving.
    static let maxStoredPromptLength = 300
    static let maxIntents = 200

    var intents: [TrackedIntent] = []

    func intent(id: String) -> TrackedIntent? { intents.first { $0.id == id } }

    /// Adds a sighting to an existing intent. Returns false if the id is unknown.
    @discardableResult
    mutating func recordSighting(intentID: String, prompt: String, sessionID: String, date: Date,
                                 transcriptPath: String? = nil, cwd: String? = nil) -> Bool {
        guard let i = intents.firstIndex(where: { $0.id == intentID }) else { return false }
        // Before capping: carry every session seen so far (incl. ones only in old sightings).
        var sessions = intents[i].sessionIDs ?? []
        for s in intents[i].sightings.map(\.sessionID) + [sessionID] where !sessions.contains(s) { sessions.append(s) }
        intents[i].sessionIDs = sessions
        intents[i].sightings.append(.init(prompt: Self.trim(prompt), sessionID: sessionID, date: date,
                                          transcriptPath: transcriptPath, cwd: cwd))
        if intents[i].sightings.count > Self.maxSightingsPerIntent {
            intents[i].sightings.removeFirst(intents[i].sightings.count - Self.maxSightingsPerIntent)
        }
        return true
    }

    /// Starts tracking a new intent and returns its id.
    @discardableResult
    mutating func addIntent(slug: String, summary: String, prompt: String, sessionID: String, date: Date,
                            transcriptPath: String? = nil, cwd: String? = nil) -> String {
        let id = UUID().uuidString
        intents.append(TrackedIntent(
            id: id,
            slug: SkillSlug.sanitize(slug),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            sightings: [.init(prompt: Self.trim(prompt), sessionID: sessionID, date: date,
                              transcriptPath: transcriptPath, cwd: cwd)],
            status: .tracking,
            sessionIDs: [sessionID]
        ))
        prune()
        return id
    }

    mutating func setStatus(_ status: TrackedIntent.Status, for id: String) {
        guard let i = intents.firstIndex(where: { $0.id == id }) else { return }
        intents[i].status = status
    }

    mutating func markCovered(_ id: String, by name: String) {
        guard let i = intents.firstIndex(where: { $0.id == id }) else { return }
        intents[i].status = .covered
        intents[i].coveredBy = name
    }

    /// Stores what Claude did for one sighting. Returns false if that sighting is gone (capped) or unknown.
    @discardableResult
    mutating func setTrace(_ trace: String, intentID: String, sessionID: String, date: Date) -> Bool {
        guard let i = intents.firstIndex(where: { $0.id == intentID }),
              let j = intents[i].sightings.firstIndex(where: { $0.sessionID == sessionID && $0.date == date })
        else { return false }
        intents[i].sightings[j].trace = trace
        return true
    }

    /// True when this intent has reached the threshold and is still waiting for an answer.
    func isReadyToOffer(_ id: String) -> Bool {
        guard let intent = intent(id: id) else { return false }
        return intent.status == .tracking && intent.distinctSessionCount >= Self.offerThreshold
    }

    /// The first intent ready to offer: still tracking and seen in enough distinct sessions.
    var nextOffer: TrackedIntent? {
        intents.first { isReadyToOffer($0.id) }
    }

    /// Intents worth sending to the classifier (declined/created ones still match,
    /// so a repeat of them is absorbed instead of starting a duplicate intent).
    var candidatesForMatching: [TrackedIntent] { intents }

    /// Keeps the store bounded: drops the stalest single-sighting intents first.
    private mutating func prune() {
        guard intents.count > Self.maxIntents else { return }
        let removable = intents
            .filter { $0.status == .tracking && $0.sightings.count == 1 }
            .sorted { $0.lastSeen < $1.lastSeen }
        var excess = intents.count - Self.maxIntents
        var dropIDs = Set<String>()
        for intent in removable where excess > 0 {
            dropIDs.insert(intent.id)
            excess -= 1
        }
        intents.removeAll { dropIDs.contains($0.id) }
    }

    private static func trim(_ prompt: String) -> String {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > maxStoredPromptLength ? String(t.prefix(maxStoredPromptLength)) : t
    }
}

/// Reads and writes the store atomically. A missing or corrupt file starts empty.
struct IntentStoreFile {
    let url: URL

    func load() -> IntentStore {
        guard let data = try? Data(contentsOf: url) else { return IntentStore() }
        return (try? Self.decoder.decode(IntentStore.self, from: data)) ?? IntentStore()
    }

    func save(_ store: IntentStore) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

enum SkillSlug {
    static let maxLength = 40

    /// Lowercase letters, digits and single hyphens; never empty.
    static func sanitize(_ raw: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else if !out.isEmpty && out.last != "-" {
                out.append("-")
            }
        }
        if out.hasPrefix("gooby-") { out.removeFirst("gooby-".count) }
        out = String(out.prefix(maxLength))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "task" : out
    }
}
