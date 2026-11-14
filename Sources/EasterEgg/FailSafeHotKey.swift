import Carbon.HIToolbox
import Foundation

/// Global fail-safe shortcut: ⌃⌥⌘ Esc. Uses Carbon RegisterEventHotKey, which needs
/// no Accessibility / Input Monitoring permission and works while Gooby is inactive.
/// Registered only while a storm is active.
@MainActor
final class FailSafeHotKey {
    static let keyCode = UInt32(kVK_Escape)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let displayName = "⌃⌥⌘ Esc"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// The C callback can't capture context, so the action lives here.
    fileprivate static var action: (@MainActor () -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

    @discardableResult
    func register(action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), failSafeHotKeyHandler, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x474F_4F42), id: 1)   // "GOOB"
        let registerStatus = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if installStatus != noErr || registerStatus != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        Self.action = nil
    }

    /// Lets tests trigger the same path the shortcut uses.
    static func fireForTesting() { action?() }
}

private func failSafeHotKeyHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { FailSafeHotKey.action?() }
    }
    return noErr
}
