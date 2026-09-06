import Foundation
import AppKit
import Carbon

/// Handles global keyboard shortcuts for the app
class HotkeyHandler: ObservableObject {
    static let shared = HotkeyHandler()
    
    /// Callback when the clipboard hotkey is triggered
    var onHotkeyPressed: (() -> Void)?
    
    /// Callback when the text AI hotkey is triggered (Cmd+Shift+C)
    var onAIHotkeyPressed: (() -> Void)?
    
    /// Callback when the penguin hotkey is triggered (Cmd+Shift+P)
    var onPenguinHotkeyPressed: (() -> Void)?
    
    /// Whether the handler is active
    @Published private(set) var isActive = false
    @Published private(set) var registrationMessage: String?
    
    /// Reference to the registered clipboard hotkey
    private var hotKeyRef: EventHotKeyRef?
    
    /// Reference to the registered AI hotkey
    private var aiHotKeyRef: EventHotKeyRef?
    
    /// Reference to the registered Penguin hotkey
    private var penguinHotKeyRef: EventHotKeyRef?
    
    /// Event handler reference
    private var eventHandlerRef: EventHandlerRef?
    private var isListening = false
    
    private init() {}
    
    /// Starts listening for the global hotkeys
    func startListening() {
        guard !isListening else { return }
        isListening = true
        
        // Register the Carbon hotkeys (no permission prompt)
        registerHotkey()
        if !isActive { useAvailableShortcut() }
        registerAIHotkey()
        registerPenguinHotkey()
        print("HotkeyHandler: Started listening")
    }
    
    /// Stops listening for the global hotkeys
    func stopListening() {
        unregisterHotkey()
        unregisterAIHotkey()
        unregisterPenguinHotkey()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        eventHandlerRef = nil
        isListening = false
        isActive = false
        print("HotkeyHandler: Stopped listening")
    }
    
    /// Re-registers the hotkey with current settings
    func reregisterHotkey() {
        unregisterHotkey()
        registerHotkey()
        print("HotkeyHandler: Re-registered hotkey")
    }
    
    /// A second clipboard app may already own the preferred shortcut.
    /// Persist a working alternative so Settings always shows the real binding.
    func useAvailableShortcut() {
        unregisterHotkey()
        let settings = AppSettings.shared
        let oldModifiers = settings.hotkeyModifiers
        let oldCode = settings.hotkeyKeyCode
        for candidate in [UInt32(cmdKey | optionKey), UInt32(cmdKey | controlKey), UInt32(controlKey | optionKey)] {
            settings.hotkeyModifiers = candidate
            settings.hotkeyKeyCode = UInt32(kVK_ANSI_V)
            registerHotkey()
            if isActive {
                registrationMessage = "The previous shortcut was unavailable. Clippy is using the shortcut shown above."
                return
            }
        }
        settings.hotkeyModifiers = oldModifiers
        settings.hotkeyKeyCode = oldCode
        registrationMessage = "Another app is using this shortcut. Choose a different combination."
    }

    /// Unregisters the current clipboard hotkey
    private func unregisterHotkey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        isActive = false
    }
    
    /// Unregisters the AI hotkey
    private func unregisterAIHotkey() {
        if let aiHotKeyRef = aiHotKeyRef {
            UnregisterEventHotKey(aiHotKeyRef)
            self.aiHotKeyRef = nil
        }
    }
    
    /// Unregisters the Penguin hotkey
    private func unregisterPenguinHotkey() {
        if let penguinHotKeyRef = penguinHotKeyRef {
            UnregisterEventHotKey(penguinHotKeyRef)
            self.penguinHotKeyRef = nil
        }
    }
    
    /// Registers the Carbon-based global hotkey for clipboard
    private func registerHotkey() {
        // Only install event handler once
        if eventHandlerRef == nil {
            installEventHandler()
        }
        
        // Get settings
        guard eventHandlerRef != nil else {
            registrationMessage = "Couldn't start keyboard shortcuts. Restart Clippy and try again."
            return
        }
        let settings = AppSettings.shared
        let keyCode = settings.hotkeyKeyCode
        let modifiers = settings.hotkeyModifiers
        
        // Register the hotkey with ID 1
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x434C5059), // "CLPY"
            id: 1
        )
        
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        isActive = registerStatus == noErr
        registrationMessage = isActive ? nil : "This shortcut is unavailable. Choose another combination."
        print("HotkeyHandler: Clipboard shortcut registration status: \(registerStatus)")
    }
    
    /// Registers the AI hotkey (Cmd+Shift+C)
    private func registerAIHotkey() {
        // Only install event handler once
        if eventHandlerRef == nil {
            installEventHandler()
        }
        
        // Cmd+Shift+C
        // C key code is 8 (kVK_ANSI_C)
        let keyCode: UInt32 = UInt32(kVK_ANSI_C)
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        
        // Register the AI hotkey with ID 2
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x434C5059), // "CLPY"
            id: 2
        )
        
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &aiHotKeyRef
        )
        
        if registerStatus != noErr {
            print("HotkeyHandler: Failed to register AI hotkey: \(registerStatus)")
        } else {
            print("HotkeyHandler: Successfully registered AI hotkey (Cmd+Shift+C)")
        }
    }
    
    /// Registers the Penguin hotkey (Cmd+Shift+P)
    private func registerPenguinHotkey() {
        // Only install event handler once
        if eventHandlerRef == nil {
            installEventHandler()
        }
        
        // Cmd+Shift+P
        let keyCode: UInt32 = UInt32(kVK_ANSI_P)
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        
        // Register the Penguin hotkey with ID 3
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x434C5059), // "CLPY"
            id: 3
        )
        
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &penguinHotKeyRef
        )
        
        if registerStatus != noErr {
            print("HotkeyHandler: Failed to register Penguin hotkey: \(registerStatus)")
        } else {
            print("HotkeyHandler: Successfully registered Penguin hotkey (Cmd+Shift+P)")
        }
    }
    
    /// Installs the event handler for hotkey events
    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (nextHandler, theEvent, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    theEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                
                guard status == noErr else { return status }
                
                let handler = Unmanaged<HotkeyHandler>.fromOpaque(userData).takeUnretainedValue()
                
                if hotKeyID.signature == OSType(0x434C5059) {
                    if hotKeyID.id == 1 {
                        // Clipboard hotkey
                        DispatchQueue.main.async {
                            print("HotkeyHandler: Clipboard hotkey triggered!")
                            handler.onHotkeyPressed?()
                        }
                        return noErr
                    } else if hotKeyID.id == 2 {
                        // AI hotkey
                        DispatchQueue.main.async {
                            print("HotkeyHandler: AI hotkey triggered!")
                            handler.onAIHotkeyPressed?()
                        }
                        return noErr
                    } else if hotKeyID.id == 3 {
                        DispatchQueue.main.async {
                            print("HotkeyHandler: Penguin hotkey triggered!")
                            handler.onPenguinHotkeyPressed?()
                        }
                        return noErr
                    }
                }
                
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        
        if status != noErr {
            print("HotkeyHandler: Failed to install event handler: \(status)")
        }
    }
    
    
    /// Checks if accessibility permissions are granted
    var hasAccessibilityPermissions: Bool {
        return AXIsProcessTrusted()
    }
}
