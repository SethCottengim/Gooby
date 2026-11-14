import Foundation

/// Sends one prompt to Claude and returns the text reply.
protocol ClaudeCompleting: Sendable {
    func complete(_ prompt: String) async throws -> String
}

enum ClaudeCLIError: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case noResult(exitCode: Int32)
    case claudeError(String)
}

/// Runs `claude -p` through the user's interactive login shell, so a Gooby opened
/// from Finder still gets the PATH (nvm, Homebrew) and credentials set in ~/.zshrc.
/// GOOBY_INTERNAL=1 tells Gooby's own prompt hook to skip these calls.
struct ClaudeCLI: ClaudeCompleting {
    var model = "opus"
    var timeout: TimeInterval = 120

    var shellCommand: String {
        "exec claude -p --model \(model) --output-format json --tools '' --no-session-persistence"
    }

    func complete(_ prompt: String) async throws -> String {
        let command = shellCommand
        let timeout = timeout
        return try await Task.detached(priority: .utility) {
            try Self.run(command: command, input: prompt, timeout: timeout)
        }.value
    }

    private static func run(command: String, input: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        var env = ProcessInfo.processInfo.environment
        env["GOOBY_INTERNAL"] = "1"
        // Don't leak the XCTest host or Gooby debug flags into Claude.
        env.removeValue(forKey: "XCTestConfigurationFilePath")
        process.environment = env
        // A neutral folder, so no project CLAUDE.md is loaded.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClaudeCLIError.launchFailed(error.localizedDescription) }

        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()

        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let timedOut = !timer.isCancelled && process.terminationReason == .uncaughtSignal
        timer.cancel()
        if timedOut { throw ClaudeCLIError.timedOut }
        return try parseResult(String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
    }

    /// `--output-format json` prints one JSON object; shell startup may print other lines first.
    static func parseResult(_ output: String, exitCode: Int32) throws -> String {
        struct Envelope: Decodable {
            let result: String?
            let is_error: Bool?
        }
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(trimmed.utf8)),
                  let result = envelope.result else { continue }
            if envelope.is_error == true { throw ClaudeCLIError.claudeError(result) }
            return result
        }
        throw ClaudeCLIError.noResult(exitCode: exitCode)
    }
}

/// Pulls the first `{` … last `}` out of a reply (Claude sometimes adds code fences or prose).
enum JSONExtraction {
    static func object(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return Data(text[start...end].utf8)
    }
}
