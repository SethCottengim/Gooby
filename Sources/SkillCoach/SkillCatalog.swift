import Foundation

/// An installed skill or slash command the user can already run.
struct InstalledSkill: Equatable {
    /// What the user types after "/", e.g. "commit" or "gooby-commit-and-push".
    let name: String
    let description: String
    let path: String
}

/// Lists the skills and commands already available, so Gooby never offers a duplicate.
/// Looks at: ~/.claude/skills, ~/.claude/commands, installed plugins' skills and commands,
/// and each project folder's .claude/skills and .claude/commands.
enum SkillCatalog {
    static let maxEntries = 400
    static let maxDescriptionLength = 200

    static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          projectDirectories: [String] = []) -> [InstalledSkill] {
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        var roots = [claude]
        roots += projectDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(".claude", isDirectory: true) }
        var out: [InstalledSkill] = []
        var seen = Set<String>()
        func add(_ s: InstalledSkill?) {
            guard let s, out.count < maxEntries, seen.insert(s.path).inserted else { return }
            out.append(s)
        }
        for root in roots {
            for url in skillFiles(in: root.appendingPathComponent("skills")) { add(read(skill: url)) }
            for url in commandFiles(in: root.appendingPathComponent("commands")) { add(read(command: url)) }
        }
        // Plugins keep skills/commands a few levels down (…/plugins/<…>/skills/<name>/SKILL.md).
        let plugins = claude.appendingPathComponent("plugins")
        if let walker = FileManager.default.enumerator(at: plugins, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if url.pathComponents.contains("node_modules") { walker.skipDescendants(); continue }
                if url.lastPathComponent == "SKILL.md" { add(read(skill: url)) }
                else if url.pathExtension == "md", url.deletingLastPathComponent().lastPathComponent == "commands" {
                    add(read(command: url))
                }
                if out.count >= maxEntries { break }
            }
        }
        return out
    }

    private static func skillFiles(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().map { dir.appendingPathComponent($0).appendingPathComponent("SKILL.md") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func commandFiles(in dir: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
            .sorted { $0.path < $1.path }
    }

    static func read(skill url: URL) -> InstalledSkill? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let meta = frontmatter(text)
        let name = meta["name"] ?? url.deletingLastPathComponent().lastPathComponent
        return InstalledSkill(name: name, description: clip(meta["description"] ?? firstLine(text)), path: url.path)
    }

    static func read(command url: URL) -> InstalledSkill? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let meta = frontmatter(text)
        let name = url.deletingPathExtension().lastPathComponent
        return InstalledSkill(name: name, description: clip(meta["description"] ?? firstLine(text)), path: url.path)
    }

    /// `key: value` lines between the first two `---` lines.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return [:] }
        var out: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, (q == "\"" || q == "'"), value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { out[key] = value }
        }
        return out
    }

    private static func firstLine(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines = Array(lines[(end + 1)...]) }
        return lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func clip(_ s: String) -> String {
        s.count > maxDescriptionLength ? String(s.prefix(maxDescriptionLength)) + "…" : s
    }
}

/// Asks Claude whether an installed skill or command already does an intent's task.
struct CoverageChecker {
    enum Verdict: Equatable {
        case covered(by: String)
        case notCovered
        /// Claude failed or replied with something unreadable; try again later.
        case unknown
    }

    let claude: ClaudeCompleting

    func check(_ intent: TrackedIntent, against installed: [InstalledSkill]) async -> Verdict {
        guard !installed.isEmpty else { return .notCovered }
        guard let reply = try? await claude.complete(Self.instructions(intent: intent, installed: installed)) else {
            return .unknown
        }
        return Self.parse(reply, names: Set(installed.map(\.name)))
    }

    static func instructions(intent: TrackedIntent, installed: [InstalledSkill]) -> String {
        let examples = intent.sightings.suffix(5).map { "- \"\($0.prompt)\"" }.joined(separator: "\n")
        let list = installed.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        return """
        A developer keeps asking an AI coding assistant to do this task:
        \(intent.summary)
        In their words:
        \(examples)

        These skills and slash commands are already installed:
        \(list)

        Does one of them already do this task, so the developer could just run it instead? \
        Only say yes if it has the same goal, not merely a related topic.

        Reply with ONLY one JSON object:
        {"covered":true,"by":"<exact name from the list>"}
        {"covered":false}
        """
    }

    static func parse(_ reply: String, names: Set<String>) -> Verdict {
        struct Raw: Decodable {
            let covered: Bool
            let by: String?
        }
        guard let data = JSONExtraction.object(in: reply),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return .unknown }
        guard raw.covered else { return .notCovered }
        // A name that isn't installed is a made-up answer; don't trust it either way.
        guard let by = raw.by?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), names.contains(by) else {
            return .unknown
        }
        return .covered(by: by)
    }
}
