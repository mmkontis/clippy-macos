import Foundation
import Carbon
import ServiceManagement
import Security

// MARK: - App Settings

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    // Hotkey settings (default: Cmd+Shift+V)
    @Published var hotkeyModifiers: UInt32 {
        didSet { saveSettings() }
    }
    @Published var hotkeyKeyCode: UInt32 {
        didSet { saveSettings() }
    }
    
    // History settings
    @Published var maxHistoryItems: Int {
        didSet { saveSettings() }
    }
    @Published var clearHistoryOnQuit: Bool {
        didSet { saveSettings() }
    }
    @Published var autoPaste: Bool {
        didSet { saveSettings() }
    }
    @Published var showMediaBar: Bool {
        didSet { saveSettings() }
    }
    @Published var dismissRecentOnPaste: Bool {
        didSet { saveSettings() }
    }
    
    // Launch at login setting
    @Published var launchAtLogin: Bool {
        didSet {
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }
    
    // Whether to suppress the accessibility permission alert (user clicked "Later")
    @Published var suppressAccessibilityAlert: Bool {
        didSet { saveSettings() }
    }
    
    // Whether onboarding has been completed
    @Published var hasCompletedOnboarding: Bool {
        didSet { saveSettings() }
    }
    
    private init() {
        // Load saved settings or use defaults
        self.hotkeyModifiers = UInt32(defaults.integer(forKey: "hotkeyModifiers"))
        self.hotkeyKeyCode = UInt32(defaults.integer(forKey: "hotkeyKeyCode"))
        self.maxHistoryItems = defaults.integer(forKey: "maxHistoryItems")
        self.clearHistoryOnQuit = defaults.bool(forKey: "clearHistoryOnQuit")
        self.autoPaste = defaults.object(forKey: "autoPaste") != nil ? defaults.bool(forKey: "autoPaste") : true
        self.showMediaBar = defaults.object(forKey: "showMediaBar") != nil ? defaults.bool(forKey: "showMediaBar") : false
        self.dismissRecentOnPaste = defaults.object(forKey: "dismissRecentOnPaste") != nil ? defaults.bool(forKey: "dismissRecentOnPaste") : true
        self.suppressAccessibilityAlert = defaults.bool(forKey: "suppressAccessibilityAlert")
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        
        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        // Set defaults if not set
        if hotkeyModifiers == 0 {
            hotkeyModifiers = UInt32(cmdKey | shiftKey)
        }
        if hotkeyKeyCode == 0 {
            hotkeyKeyCode = UInt32(kVK_ANSI_V)
        }
        if maxHistoryItems == 0 {
            maxHistoryItems = 100
        }
    }
    
    func saveSettings() {
        defaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers")
        defaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode")
        defaults.set(maxHistoryItems, forKey: "maxHistoryItems")
        defaults.set(clearHistoryOnQuit, forKey: "clearHistoryOnQuit")
        defaults.set(autoPaste, forKey: "autoPaste")
        defaults.set(showMediaBar, forKey: "showMediaBar")
        defaults.set(dismissRecentOnPaste, forKey: "dismissRecentOnPaste")
        defaults.set(suppressAccessibilityAlert, forKey: "suppressAccessibilityAlert")
        defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
    }
    
    /// Resets all settings to defaults and clears all cached data
    func resetAllSettings() {
        // Clear all UserDefaults for this app
        if let bundleId = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleId)
        }
        
        // Unregister from login items
        try? SMAppService.mainApp.unregister()
        
        // Reset in-memory values to defaults
        hotkeyModifiers = UInt32(cmdKey | shiftKey)
        hotkeyKeyCode = UInt32(kVK_ANSI_V)
        maxHistoryItems = 100
        clearHistoryOnQuit = false
        autoPaste = true
        showMediaBar = false
        dismissRecentOnPaste = true
        launchAtLogin = false
        suppressAccessibilityAlert = false
        hasCompletedOnboarding = false
    }
}




// Optional OpenAI credentials are stored in the user's macOS Keychain.
enum OpenAICredentials {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.clippy.app.openai",
         kSecAttrAccount as String: "api-key"]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
