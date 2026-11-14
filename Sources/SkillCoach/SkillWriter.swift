import Foundation

/// Writes ~/.claude/skills/gooby-<slug>/SKILL.md for an intent.
/// Claude drafts the body; if that fails, a plain template is used. Never overwrites.
struct SkillWriter {
    let skillsDirectory: URL
    let claude: ClaudeCompleting?

    static var defaultSkillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// The first free name: gooby-<slug>, then gooby-<slug>-2, -3, ...
    func availableName(for slug: String) -> String {
        let base = "gooby-" + SkillSlug.sanitize(slug)
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: skillsDirectory.appendingPathComponent(name).path) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    /// Returns the skill name (what the user types after "/").
    func write(for intent: TrackedIntent) async throws -> String {
        let name = availableName(for: intent.slug)
        var content = Self.template(name: name, intent: intent)
        if let claude, let drafted = try? await claude.complete(Self.draftingPrompt(name: name, intent: intent)),
           let cleaned = Self.validated(drafted, name: name) {
            content = cleaned
        }
        let folder = skillsDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: folder.appendingPathComponent("SKILL.md"), options: .withoutOverwriting)
        return name
    }

    /// Each past request, with what Claude actually did that time when it was captured.
    static func examplesBlock(_ intent: TrackedIntent) -> String {
        intent.sightings.enumerated().map { n, s in
            var block = "Request \(n + 1): \"\(s.prompt)\""
            if let trace = s.trace, !trace.isEmpty {
                block += "\nWhat the assistant did that time:\n" + trace
            }
            return block
        }.joined(separator: "\n\n")
    }

    static func draftingPrompt(name: String, intent: TrackedIntent) -> String {
        let traced = intent.sightings.filter { !($0.trace ?? "").isEmpty }.count
        return """
        Write a Claude Code skill file (SKILL.md) for a task a developer keeps asking for.

        Skill name: \(name)
        Task: \(intent.summary)

        The developer's past requests, and (for \(traced) of \(intent.sightings.count)) the steps the assistant \
        actually took each time:

        \(examplesBlock(intent))

        Requirements:
        - Start with YAML frontmatter containing exactly `name: \(name)` and a one-line `description:` \
        saying what the skill does and when to use it.
        - Then short, numbered steps telling Claude how to do the task. Base them on the steps the assistant \
        actually took above: keep what happened every time, note what varied, and leave out one-off detours.
        - This is a global skill used in many different projects: no paths, repo names, branch names or file \
        names from the examples unless every example shares them. Turn project-specific values into \
        "find out X first" steps.
        - Include the checks a careful engineer would do (look before overwriting or force-pushing, \
        confirm before anything destructive, report what was done).
        - Under 50 lines.

        Reply with ONLY the file content. No code fences, no commentary.
        """
    }

    /// Accepts a draft only if it has frontmatter; forces the correct name line.
    static func validated(_ draft: String, name: String) -> String? {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines = text.components(separatedBy: "\n")
        guard lines.first == "---",
              let close = lines.dropFirst().firstIndex(of: "---"),
              lines[1..<close].contains(where: { $0.hasPrefix("description:") }) else { return nil }
        if let nameLine = lines[1..<close].firstIndex(where: { $0.hasPrefix("name:") }) {
            lines[nameLine] = "name: \(name)"
        } else {
            lines.insert("name: \(name)", at: 1)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func template(name: String, intent: TrackedIntent) -> String {
        let summary = intent.summary.replacingOccurrences(of: "\n", with: " ")
        let examples = intent.sightings.map { "- \"\($0.prompt.replacingOccurrences(of: "\n", with: " "))\"" }
            .joined(separator: "\n")
        let traceList = intent.sightings.compactMap(\.trace).filter { !$0.isEmpty }
        let traces = traceList.isEmpty ? "- (none captured)" : traceList.enumerated()
            .map { "Time \($0 + 1):\n\($1)" }.joined(separator: "\n")
        return """
        ---
        name: \(name)
        description: \(summary) (Made by Gooby from requests you repeated.)
        ---

        # \(summary)

        Do this task for the user in the current project: \(summary)

        They have asked for it in these words:
        \(examples)

        Steps taken in those past requests (generalize; paths are from specific projects):
        \(traces)

        Check the current state before changing anything, then report what you did.

        """
    }
}
