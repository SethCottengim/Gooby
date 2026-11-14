import AppKit

/// Where a chat's Terminal tab is right now.
enum TabPlacement: Equatable {
    /// The selected tab of Terminal's front window: the user is looking at this chat.
    case front
    /// Open in Terminal, but not the front window's selected tab.
    case elsewhere
    /// No Terminal tab has this tty (e.g. tmux, VS Code, the tab was closed).
    case notInTerminal
    /// Couldn't ask Terminal (Automation permission denied, Terminal not running, error).
    case unavailable
}

protocol TerminalTabLocating: Sendable {
    func placement(ofTTY tty: String) async -> TabPlacement
}

/// Asks Terminal via AppleScript which tab owns a tty. Needs macOS Automation permission
/// for Terminal (one-time system prompt; Info.plist NSAppleEventsUsageDescription).
/// Runs /usr/bin/osascript in its own process so a slow reply or the permission prompt
/// never blocks Gooby.
struct TerminalTabLocator: TerminalTabLocating {
    var timeout: TimeInterval = 5

    static let script = """
    on run argv
        set target to item 1 of argv
        tell application "Terminal"
            if (count of windows) = 0 then return "none,"
            set found to "none"
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is target then set found to "open"
                end repeat
            end repeat
            set frontTTY to tty of selected tab of front window
        end tell
        return found & "," & frontTTY
    end run
    """

    func placement(ofTTY tty: String) async -> TabPlacement {
        let target = Self.devicePath(tty)
        let timeout = timeout
        // Don't launch Terminal just to ask; it isn't running, so the tab can't be in it.
        guard Self.terminalIsRunning() else { return .unavailable }
        return await Task.detached(priority: .utility) {
            guard let output = Self.run(script: Self.script, argument: target, timeout: timeout) else { return .unavailable }
            return Self.parse(output, target: target)
        }.value
    }

    /// "ttys002" -> "/dev/ttys002" (Terminal reports full device paths).
    static func devicePath(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
    }

    /// Output is "open|none,<front tab tty>".
    static func parse(_ output: String, target: String) -> TabPlacement {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",", maxSplits: 1,
                                                                                  omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .unavailable }
        if String(parts[1]) == target { return .front }
        switch parts[0] {
        case "open": return .elsewhere
        case "none": return .notInTerminal
        default: return .unavailable
        }
    }

    static let terminalBundleID = "com.apple.Terminal"

    /// Asks macOS's list of running apps (not `pgrep`, whose name matching missed Terminal).
    private static func terminalIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: terminalBundleID).isEmpty
    }

    /// Nil on any failure (incl. permission denied, error -1743) or timeout.
    private static func run(script: String, argument: String, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-", argument]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try? stdin.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
