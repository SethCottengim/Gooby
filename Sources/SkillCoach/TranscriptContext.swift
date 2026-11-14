import Foundation

/// Reads what Claude said right before the user's prompt, from the session
/// transcript Claude Code names in the hook input (`transcript_path`).
/// Lets "yes go ahead" be understood as the action Claude just offered.
/// The transcript format isn't documented, so any surprise just means "no context".
enum TranscriptContext {
    /// Only the end of the file is read; long sessions can be many MB.
    static let maxBytesRead = 512 * 1024
    /// The question being answered is usually at the end of Claude's message.
    static let maxContextLength = 1500

    static func lastAssistantText(transcript url: URL, before date: Date) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytesRead) ? size - UInt64(maxBytesRead) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return lastAssistantText(inJSONL: String(decoding: data, as: UTF8.self), before: date)
    }

    static func lastAssistantText(inJSONL text: String, before date: Date) -> String? {
        struct Entry: Decodable {
            struct Message: Decodable {
                struct Block: Decodable {
                    let type: String
                    let text: String?
                }
                let content: [Block]?
            }
            let type: String?
            let timestamp: String?
            let isSidechain: Bool?
            let message: Message?
        }
        let decoder = JSONDecoder()
        // Newest first; the first line may be cut in half by the byte limit and simply fails to decode.
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard line.contains("\"assistant\""),
                  let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)),
                  entry.type == "assistant", entry.isSidechain != true,
                  let stamp = entry.timestamp.flatMap(parseDate), stamp <= date else { continue }
            let joined = (entry.message?.content ?? [])
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Tool-only or thinking-only turns carry no text; keep looking further back.
            guard !joined.isEmpty else { continue }
            return joined.count > maxContextLength ? "…" + String(joined.suffix(maxContextLength)) : joined
        }
        return nil
    }

    // MARK: - Chat title

    /// The latest title Claude Code gave the session (`ai-title` entries), or nil.
    static func lastTitle(transcript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytesRead) ? size - UInt64(maxBytesRead) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return lastTitle(inJSONL: String(decoding: data, as: UTF8.self))
    }

    static func lastTitle(inJSONL text: String) -> String? {
        struct Entry: Decodable {
            let type: String?
            let aiTitle: String?
        }
        for line in text.split(whereSeparator: \.isNewline).reversed() where line.contains("\"ai-title\"") {
            if let e = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)), e.type == "ai-title",
               let t = e.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t.count > 60 ? String(t.prefix(60)) + "…" : t
            }
        }
        return nil
    }

    // MARK: - What Claude did after a prompt

    /// How much of a session log is read when looking for actions (the prompt may be far back).
    static let maxBytesReadForTrace = 8 * 1024 * 1024
    static let maxTraceLines = 30
    static let maxTraceLength = 2500
    static let finalReplyLength = 400
    /// Hook time and the log's timestamp for the same prompt can differ slightly.
    static let promptMatchSlack: TimeInterval = 10

    struct ActionTrace: Equatable {
        /// e.g. "- Bash: git add -A && git commit -m …\n- Edit: Sources/App.swift\nFinal reply (end): …"
        let text: String
        /// True once the next user prompt appears, i.e. Claude's turn for this prompt is over.
        let reachedNextPrompt: Bool
    }

    /// The tool calls Claude made and the end of its last reply, for the first user prompt
    /// logged at or after `promptDate` (minus a small slack). Nil if that prompt isn't in the log.
    static func actionTrace(transcript url: URL, promptDate: Date) -> ActionTrace? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytesReadForTrace) ? size - UInt64(maxBytesReadForTrace) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return actionTrace(inJSONL: String(decoding: data, as: UTF8.self), promptDate: promptDate)
    }

    static func actionTrace(inJSONL text: String, promptDate: Date) -> ActionTrace? {
        var found = false
        var lines: [String] = []
        var lastText: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  (obj["isSidechain"] as? Bool) != true else { continue }
            let type = obj["type"] as? String
            let message = obj["message"] as? [String: Any]
            if type == "user", (obj["isMeta"] as? Bool) != true, (obj["isCompactSummary"] as? Bool) != true,
               message?["content"] is String {
                if found {
                    return ActionTrace(text: format(lines, lastText), reachedNextPrompt: true)
                }
                if let stamp = (obj["timestamp"] as? String).flatMap(parseDate),
                   stamp >= promptDate.addingTimeInterval(-promptMatchSlack) {
                    found = true
                }
                continue
            }
            guard found, type == "assistant", let blocks = message?["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    let line = describe(tool: block["name"] as? String ?? "?", input: block["input"] as? [String: Any] ?? [:])
                    if lines.last != line { lines.append(line) }
                case "text":
                    if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        lastText = t
                    }
                default:
                    break
                }
            }
        }
        return found ? ActionTrace(text: format(lines, lastText), reachedNextPrompt: false) : nil
    }

    private static func describe(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let cmd = input["command"] as? String {
            let firstLines = cmd.split(separator: "\n").prefix(3).joined(separator: " ⏎ ")
            return "- Bash: " + String(firstLines.prefix(200))
        }
        for key in ["file_path", "path", "pattern", "skill", "url", "query"] {
            if let v = input[key] as? String { return "- \(tool): " + String(v.prefix(160)) }
        }
        return "- \(tool)"
    }

    private static func format(_ lines: [String], _ lastText: String?) -> String {
        var out = Array(lines.prefix(maxTraceLines))
        if lines.count > maxTraceLines { out.append("- … \(lines.count - maxTraceLines) more steps") }
        if out.isEmpty { out.append("- (no tool calls)") }
        if let lastText {
            let end = lastText.count > finalReplyLength ? "…" + String(lastText.suffix(finalReplyLength)) : lastText
            out.append("Final reply (end): " + end.replacingOccurrences(of: "\n", with: " "))
        }
        let joined = out.joined(separator: "\n")
        return joined.count > maxTraceLength ? String(joined.prefix(maxTraceLength)) + "…" : joined
    }

    private static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
