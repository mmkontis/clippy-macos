import SwiftUI
import Carbon
import AVFoundation
import ClipboardKit
#if !APP_STORE
import Sparkle
#endif

/// Settings window view
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var isRecordingHotkey = false
    @State private var recordedModifiers: NSEvent.ModifierFlags = []
    @State private var recordedKeyCode: UInt16 = 0
    
    @State private var hasAccessibilityPermission = false
    @State private var showResetConfirmation = false
    @State private var openAIKey = ""
    @State private var keyStatus = ""
    @AppStorage("textAIProvider") private var textAIProvider = AIProvider.none.rawValue
    @AppStorage("openAITextModel") private var openAITextModel = "gpt-5.4-mini"
    @ObservedObject private var codexConnection = CodexConnection.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 16) {
                // App Icon
                if let image = NSImage(named: "AppIcon") {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                } else {
                    // Fallback
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "clipboard")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                        )
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clippy")
                        .font(.system(size: 20, weight: .bold))
                    Text("Clipboard Manager")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Settings content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // General section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("General", systemImage: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.blue)
                        
                        HStack {
                            Text("Auto-paste on select:")
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                                Toggle("", isOn: $settings.autoPaste)
                                    .disabled(!ClipboardKitConfig.allowsSimulatedKeystrokes)
                                    .toggleStyle(.switch)
                                    .tint(.blue)
                        }
                        
                        Text(ClipboardKitConfig.allowsSimulatedKeystrokes ? "Automatically paste the selected item into the previously active app" : "Select an item, then press Command-V in your destination app.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                        
                        Divider()
                            .padding(.vertical, 4)
                            
                        HStack {
                            Text("Show Media Bar:")
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                                Toggle("", isOn: $settings.showMediaBar)
                                    .toggleStyle(.switch)
                                    .tint(.blue)
                        }
                        
                        Text("Display a bar at the bottom with recent images and files")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))

                        Divider()
                            .padding(.vertical, 4)

                        HStack {
                            Text("Dismiss recent stack after paste:")
                                .foregroundColor(.secondary)

                            Spacer()

                                Toggle("", isOn: $settings.dismissRecentOnPaste)
                                    .toggleStyle(.switch)
                                    .tint(.blue)
                        }

                        Text("When you press ⌘V or ⌃V in another app, remove the top tile from the bottom-left stack. The item stays in your clipboard history.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))

                        Divider()
                            .padding(.vertical, 4)

                        HStack {
                            Text("Launch at login:")
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                                Toggle("", isOn: $settings.launchAtLogin)
                                    .toggleStyle(.switch)
                                    .tint(.blue)
                        }
                        
                        Text("Automatically start Clippy when you log in")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    
                    Divider()
                    
                    // Permissions section
                    #if !APP_STORE
                    permissionsSection
                    #endif
                    
                    Divider()
                    
                    cloudAISection
                    Divider()
                    // Penguin section
                    penguinSection

                    Divider()

                    // Dictation section
                    dictationSection

                    Divider()

                    // Hotkey section
                    hotkeySection
                    
                    Divider()
                    
                    // History section
                    historySection
                    
                    Divider()
                    
                    // About section
                    aboutSection
                    
                    Divider()
                    
                    // Reset section
                    resetSection
                }
                .padding(20)
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
            .padding(16)
        }
        .frame(width: 500, height: 650)
        .onAppear {
            checkPermissions()
        }
        .onChange(of: settings.maxHistoryItems) { _, _ in
            ClipboardManager.shared.enforceHistoryLimit()
        }
    }
    
    private var cloudAISection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Optional text AI", systemImage: "sparkles").font(.headline)
            Picker("Use AI with", selection: $textAIProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.title).tag(provider.rawValue)
                }
            }
            .onChange(of: textAIProvider) { _, value in
                AIChatService.shared.clear()
                codexConnection.cancelLogin()
                if value == AIProvider.chatGPT.rawValue {
                    Task { await codexConnection.refreshAccount() }
                } else {
                    codexConnection.stop()
                }
            }
            if textAIProvider == AIProvider.openAI.rawValue {
                SecureField("OpenAI API key", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key") {
                        keyStatus = OpenAICredentials.save(openAIKey) ? "Saved in Keychain." : "Couldn't save the key."
                        openAIKey = ""
                    }.disabled(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove key") {
                        AIChatService.shared.clear()
                        keyStatus = OpenAICredentials.save("") ? "Key removed." : "Couldn't remove the key."
                        openAIKey = ""
                    }
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption) }
                DisclosureGroup("Model") {
                    TextField("OpenAI model", text: $openAITextModel).textFieldStyle(.roundedBorder)
                }
                Text("Uses your OpenAI API billing, separately from ChatGPT. Your key stays in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if textAIProvider == AIProvider.chatGPT.rawValue {
                Text(codexConnection.status).font(.callout)
                if codexConnection.isConnecting, let url = codexConnection.verificationURL {
                    Link("Continue sign-in", destination: url)
                }
                HStack {
                    if codexConnection.isConnecting {
                        ProgressView().controlSize(.small)
                        Button("Cancel sign-in") { codexConnection.cancelLogin() }
                    } else if codexConnection.isConnected {
                        Button("Disconnect") { Task { await codexConnection.disconnectAccount() } }
                    } else {
                        Button("Connect ChatGPT") { Task { await codexConnection.connect() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Check connection") { Task { await codexConnection.refreshAccount() } }
                        .disabled(codexConnection.isConnecting)
                }
                Text("Uses Codex through your ChatGPT account. Your plan limits apply. Clippy has a separate sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Only the text you send is shared with OpenAI. No voice recording. Clipboard history stays on your Mac and works without AI.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open text AI") { AppDelegate.shared?.showAIPanelNearCursor() }
                .disabled(textAIProvider == AIProvider.none.rawValue)
        }
        .task {
            if textAIProvider == AIProvider.chatGPT.rawValue { await codexConnection.refreshAccount() }
        }
    }

    // MARK: - Permissions Section
    
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Permissions", systemImage: "lock.shield")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.blue)
            
            Text("Enable only the permissions for the features you use:")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            VStack(spacing: 10) {
                #if !APP_STORE
                // Accessibility Permission
                HStack {
                    Image(systemName: hasAccessibilityPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(hasAccessibilityPermission ? .green : .red)
                        .font(.system(size: 18))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 13, weight: .medium))
                        Text("Optional for automatic paste into other apps")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if !hasAccessibilityPermission {
                        Button("Grant Access") {
                            requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.small)
                    } else {
                        Text("Granted")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                
                #endif
            }
            
            HStack {
                Button("Refresh Status") {
                    checkPermissions()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("Open System Settings") {
                    openPrivacySettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }
    
    private func checkPermissions() {
        let trusted = AXIsProcessTrusted()
        hasAccessibilityPermission = trusted
        
    }
    
    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        
        // Check again after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            checkPermissions()
        }
    }
    
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Penguin Section
    
    private var penguinSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI Penguin", systemImage: "bird")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.blue)
            
            HStack(spacing: 16) {
                let theme = PenguinCustomization.shared.colorTheme
                PenguinSVGPreview(theme: theme)
                    .scaleEffect(0.55)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 3) {
                    if !PenguinCustomization.shared.name.isEmpty {
                        Text(PenguinCustomization.shared.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    } else {
                        Text("Unnamed Penguin")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    let traitsText = PenguinCustomization.shared.traits.map(\.name).joined(separator: ", ")
                    if !traitsText.isEmpty {
                        Text(traitsText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Button("Customize...") {
                    PenguinCreatorWindowController.shared.showCreator()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
    
    // MARK: - Dictation Section

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Coworker")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(CoworkerBrand.blue)
                DictationNewBadge()
            }

            HStack(spacing: 16) {
                Image("CoworkerLogo")
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Coworker")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Type with your voice")
                        .font(.system(size: 13, weight: .medium))
                    Text("Coworker turns speech into text in any app.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Get free") {
                    DictationPromo.shared.openDownloadPage()
                }
                .buttonStyle(.borderedProminent)
                .tint(CoworkerBrand.blue)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    // MARK: - Hotkey Section

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Keyboard Shortcut", systemImage: "keyboard")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.blue)
            
            HStack {
                Text("Open Clipboard History:")
                    .foregroundColor(.secondary)
                
                Spacer()
                
                HotkeyRecorderView(
                    modifiers: $settings.hotkeyModifiers,
                    keyCode: $settings.hotkeyKeyCode,
                    isRecording: $isRecordingHotkey
                )
            }
            
            Text("Click the shortcut field and press your desired key combination")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - History Section
    
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.blue)
            
            Text("Clippy and updated Coworker share up to 400 recent clips on this Mac. Deleting or clearing history affects both apps. Your display limit only changes this list.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Items shown:")
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Picker("", selection: $settings.maxHistoryItems) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            
            HStack {
                Text("Clear shared history on quit:")
                    .foregroundColor(.secondary)
                
                Spacer()
                
                                Toggle("", isOn: $settings.clearHistoryOnQuit)
                                    .toggleStyle(.switch)
                                    .tint(.blue)
            }
        }
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("About", systemImage: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.blue)
            
            HStack {
                Text("Clippy")
                    .font(.system(size: 13, weight: .medium))
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.2")")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            
            Text("Your clipboard, with a memory. Optional text AI and a penguin companion.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            #if !APP_STORE
            Button {
                if let appDelegate = AppDelegate.shared {
                    appDelegate.updaterController.checkForUpdates(nil)
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Check for Updates...")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            #endif
        }
    }
    
    // MARK: - Reset Section
    
    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.red)
            
            Text("Clear all settings and cached data")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            HStack {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear Cache & Reset")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                
                Spacer()
            }
            .alert("Reset Clippy?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    performReset()
                }
            } message: {
                Text("This will clear all settings, clipboard history, and cached data. Clippy will restart with the onboarding flow.")
            }
        }
    }
    
    private func performReset() {
        // Clear clipboard history
        Task { @MainActor in
            ClipboardManager.shared.clearHistory()
        }
        
        // Reset all settings
        AppSettings.shared.resetAllSettings()
        
        // Close settings window
        NSApp.keyWindow?.close()
        
        // Show onboarding again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            OnboardingWindowController.shared.showOnboarding()
        }
    }
}

// MARK: - Hotkey Recorder View

struct HotkeyRecorderView: View {
    @Binding var modifiers: UInt32
    @Binding var keyCode: UInt32
    @Binding var isRecording: Bool
    
    @State private var localMonitor: Any?
    
    var body: some View {
        Button(action: {
            isRecording.toggle()
            if isRecording {
                startRecording()
            } else {
                stopRecording()
            }
        }) {
            HStack(spacing: 4) {
                if isRecording {
                    Text("Press keys...")
                        .foregroundColor(.blue)
                } else {
                    Text(hotkeyDisplayString)
                        .foregroundColor(.primary)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isRecording ? Color.blue : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var hotkeyDisplayString: String {
        var parts: [String] = []
        
        if modifiers & UInt32(cmdKey) != 0 {
            parts.append("⌘")
        }
        if modifiers & UInt32(shiftKey) != 0 {
            parts.append("⇧")
        }
        if modifiers & UInt32(optionKey) != 0 {
            parts.append("⌥")
        }
        if modifiers & UInt32(controlKey) != 0 {
            parts.append("⌃")
        }
        
        if let keyName = keyCodeToString(keyCode) {
            parts.append(keyName)
        }
        
        return parts.isEmpty ? "Click to set" : parts.joined()
    }
    
    private func keyCodeToString(_ keyCode: UInt32) -> String? {
        let keyMap: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 36: "↵", 37: "L", 38: "J", 39: "'",
            40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 118: "F4", 119: "F2", 120: "F1", 122: "F1", 123: "←",
            124: "→", 125: "↓", 126: "↑"
        ]
        return keyMap[keyCode]
    }
    
    private func startRecording() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Get modifiers
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.command) {
                mods |= UInt32(cmdKey)
            }
            if event.modifierFlags.contains(.shift) {
                mods |= UInt32(shiftKey)
            }
            if event.modifierFlags.contains(.option) {
                mods |= UInt32(optionKey)
            }
            if event.modifierFlags.contains(.control) {
                mods |= UInt32(controlKey)
            }
            
            // Only accept if at least one modifier is pressed
            if mods != 0 {
                self.modifiers = mods
                self.keyCode = UInt32(event.keyCode)
                self.isRecording = false
                self.stopRecording()
                
                // Re-register the hotkey
                AppSettings.shared.saveSettings()
                HotkeyHandler.shared.reregisterHotkey()
            }
            
            return nil // Consume the event
        }
    }
    
    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController {
    static let shared = SettingsWindowController()
    
    private var window: NSWindow?
    
    func showSettings() {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        newWindow.contentViewController = hostingController
        newWindow.title = "Clippy Settings"
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
        
        window = newWindow
    }
}

#Preview {
    SettingsView()
}
