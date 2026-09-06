import AppKit
import Carbon

// Isolated preferences. Never changes the installed app's settings.
final class AppSettings {
    static let shared = AppSettings()
    var hotkeyModifiers = UInt32(cmdKey | optionKey | controlKey)
    var hotkeyKeyCode = UInt32(kVK_F18)
}

@main struct HotkeyTests {
    static func main() {
        let settings = AppSettings.shared
        var occupied: EventHotKeyRef?
        let status = RegisterEventHotKey(settings.hotkeyKeyCode, settings.hotkeyModifiers,
            EventHotKeyID(signature: 0x54455354, id: 90), GetApplicationEventTarget(), 0, &occupied)
        precondition(status == noErr, "Couldn't reserve the test shortcut")
        defer { if let occupied { UnregisterEventHotKey(occupied) } }
        let handler = HotkeyHandler.shared
        handler.startListening()
        precondition(handler.isActive, "No working fallback shortcut")
        precondition(settings.hotkeyKeyCode == UInt32(kVK_ANSI_V))
        precondition(handler.registrationMessage != nil, "Conflict wasn't surfaced")
        handler.stopListening()
        precondition(!handler.isActive)
        handler.startListening()
        precondition(handler.isActive, "Shortcut didn't register again after stopping")
        handler.stopListening()
        print("Hotkey tests passed: collision fallback, visible status, stop and restart.")
    }
}
