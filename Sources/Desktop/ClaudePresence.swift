import AppKit
import Darwin

/// One running Claude Code session: its Terminal tab and working folder.
struct ClaudeSession: Equatable, Sendable {
    /// e.g. "ttys002"
    let tty: String
    let pid: pid_t
    /// The session's working folder, nil if unreadable.
    let cwd: String?
}

/// What Gooby knows about Terminal's front tab.
enum FrontTabStatus: Equatable, Sendable {
    /// Claude Code runs in it. `project` is the folder name for the hover tag (nil if unknown).
    case claude(project: String?)
    /// A tab without Claude (plain shell, another program).
    case notClaude
    /// Can't tell (Automation permission denied, Terminal error): behave as before
    /// and treat any Terminal window as a Claude window.
    case unknown
}

protocol ClaudeSessionSource {
    func sessions() -> [ClaudeSession]
}

/// Finds Claude Code processes with libproc (own-user processes only; no permission).
/// Reads only each process's name, controlling terminal and working folder.
struct LibprocClaudeSessions: ClaudeSessionSource {
    /// Claude Code's native binary shows up as "claude.exe"; older installs as "claude".
    static let processNames: Set<String> = ["claude.exe", "claude"]

    func sessions() -> [ClaudeSession] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count)))
        var out: [ClaudeSession] = []
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            let name = withUnsafePointer(to: &info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            guard Self.processNames.contains(name), let tty = Self.ttyName(info.e_tdev) else { continue }
            out.append(ClaudeSession(tty: tty, pid: pid, cwd: Self.cwd(of: pid)))
        }
        return out
    }

    /// "ttys002" for a controlling terminal, nil for none (background `claude -p`, daemons).
    static func ttyName(_ tdev: UInt32) -> String? {
        guard tdev != 0, tdev != UInt32.max else { return nil }
        guard let c = devname(Int32(bitPattern: tdev), mode_t(S_IFCHR)) else { return nil }
        let s = String(cString: c)
        return s.isEmpty || s == "??" ? nil : s
    }

    static func cwd(of pid: pid_t) -> String? {
        var vnode = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else {
            return nil
        }
        let path = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}

/// Short folder name for the hover tag: "~" for home, the last path component otherwise.
/// Nil when the folder no longer exists (its path is unreliable then).
enum ProjectName {
    static func of(cwd: String?, home: String = NSHomeDirectory(),
                   exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard let cwd, !cwd.isEmpty, exists(cwd) else { return nil }
        let trimmed = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if trimmed == home { return "~" }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

/// Reads the tty of Terminal's front window's selected tab via AppleScript.
/// Needs Automation permission for Terminal (already used for skill offers).
@MainActor
protocol FrontTabReading {
    /// .success("ttys002"), .success(nil) when Terminal has no windows, .failure on any error.
    func frontTabTTY() -> Result<String?, FrontTabError>
}

enum FrontTabError: Error, Equatable {
    case denied
    case failed
}

/// In-process AppleScript, compiled once. Must run on the main thread; each call takes
/// a few milliseconds, so callers sample it about once a second, not every frame.
@MainActor
final class AppleScriptFrontTabReader: FrontTabReading {
    private lazy var script = NSAppleScript(source: """
    tell application "Terminal"
        if (count of windows) = 0 then return ""
        return tty of selected tab of front window
    end tell
    """)

    func frontTabTTY() -> Result<String?, FrontTabError> {
        guard let script else { return .failure(.failed) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            return .failure(code == -1743 ? .denied : .failed) // -1743: not authorized
        }
        let tty = (result.stringValue ?? "").replacingOccurrences(of: "/dev/", with: "")
        return .success(tty.isEmpty ? nil : tty)
    }
}

/// Combines Claude sessions and Terminal's front tab into a FrontTabStatus, sampled
/// at most every `refreshInterval`, or right away when the front window changes.
@MainActor
final class ClaudePresence {
    static let refreshInterval: TimeInterval = 1
    /// After a denial, ask Terminal again this rarely (the user may grant it in Settings).
    static let deniedRetryInterval: TimeInterval = 60

    private let sessions: ClaudeSessionSource
    private let frontTab: FrontTabReading
    private let clock: () -> Date
    private var cached: FrontTabStatus = .unknown
    private var lastRefresh: Date?
    private var lastWindowKey: Int?
    private var deniedUntil: Date?

    init(sessions: ClaudeSessionSource = LibprocClaudeSessions(),
         frontTab: FrontTabReading = AppleScriptFrontTabReader(),
         clock: @escaping () -> Date = { Date() }) {
        self.sessions = sessions
        self.frontTab = frontTab
        self.clock = clock
    }

    /// `windowKey` identifies the front Terminal window (changes when the user switches windows).
    func status(frontWindowKey windowKey: Int?) -> FrontTabStatus {
        let now = clock()
        let due = lastRefresh.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
        if due || windowKey != lastWindowKey {
            lastRefresh = now
            lastWindowKey = windowKey
            cached = compute(now: now)
        }
        return cached
    }

    /// Forces the next status() call to resample.
    func invalidate() { lastRefresh = nil }

    private func compute(now: Date) -> FrontTabStatus {
        let running = sessions.sessions()
        if let until = deniedUntil, now < until { return fallback(running) }
        switch frontTab.frontTabTTY() {
        case let .success(tty?):
            deniedUntil = nil
            guard let session = running.first(where: { $0.tty == tty }) else { return .notClaude }
            return .claude(project: ProjectName.of(cwd: session.cwd))
        case .success(nil):
            return .notClaude
        case .failure(.denied):
            deniedUntil = now.addingTimeInterval(Self.deniedRetryInterval)
            return fallback(running)
        case .failure(.failed):
            return fallback(running)
        }
    }

    /// Without Terminal's answer: any Terminal window counts if some Claude session runs.
    private func fallback(_ running: [ClaudeSession]) -> FrontTabStatus {
        running.isEmpty ? .notClaude : .unknown
    }
}
