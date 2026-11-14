import CoreGraphics
import Foundation

/// Position-only facts about one on-screen window. Window titles and contents are
/// never read (they would need Screen Recording permission and are user content).
struct WindowSnapshot: Equatable, Sendable {
    let ownerPID: pid_t
    let layer: Int
    /// Core Graphics global coordinates: origin at the primary screen's top-left, y grows down.
    let bounds: CGRect
    let alpha: Double
    /// Core Graphics window number: tells two windows with the same bounds apart.
    var number: Int = 0
}

protocol WindowInfoSource {
    /// On-screen windows, front to back.
    func onScreenWindows() -> [WindowSnapshot]
}

/// Reads window metadata (owner, layer, bounds, alpha) via CGWindowListCopyWindowInfo.
/// Requires no permission; does not capture any pixels.
struct CGWindowInfoSource: WindowInfoSource {
    func onScreenWindows() -> [WindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
            return WindowSnapshot(ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha, number: number)
        }
    }
}

enum TerminalWindowLocator {
    static let terminalBundleIDs: Set<String> = ["com.apple.Terminal"]
    /// Skips tiny helper windows (sheets, tooltips) that share the app's pid.
    static let minimumSize = CGSize(width: 200, height: 100)

    /// The frontmost Terminal window's bounds (CG coordinates), or nil when Terminal
    /// is not the front app or has no usable on-screen window.
    static func frontTerminalWindow(
        frontmostBundleID: String?,
        frontmostPID: pid_t?,
        windows: [WindowSnapshot]
    ) -> CGRect? {
        frontTerminalSnapshot(frontmostBundleID: frontmostBundleID, frontmostPID: frontmostPID, windows: windows)?.bounds
    }

    /// Like frontTerminalWindow, but with the window number too.
    static func frontTerminalSnapshot(
        frontmostBundleID: String?,
        frontmostPID: pid_t?,
        windows: [WindowSnapshot]
    ) -> WindowSnapshot? {
        guard let bundleID = frontmostBundleID, terminalBundleIDs.contains(bundleID),
              let pid = frontmostPID else { return nil }
        return windows.first { w in
            w.ownerPID == pid && w.layer == 0 && w.alpha > 0
                && w.bounds.width >= minimumSize.width && w.bounds.height >= minimumSize.height
        }
    }
}
