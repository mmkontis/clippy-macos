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
        var delivered = false
        handler.onHotkeyPressed = { delivered = true }
        var event: EventRef?
        precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
        if let event {
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: 0x434C5059, id: 1)
            precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
            precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
            let deadline = Date().addingTimeInterval(1)
            while !delivered && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        precondition(delivered, "Registered event didn't reach the clipboard callback")
        handler.stopListening()
        precondition(!handler.isActive)
        handler.startListening()
        precondition(handler.isActive, "Shortcut didn't register again after stopping")
        handler.stopListening()
        print("Hotkey tests passed: collision fallback, event delivery, visible status, stop and restart.")
    }
}
