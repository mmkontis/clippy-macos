import SwiftUI
import Carbon
import ClipboardKit
#if !APP_STORE
import Sparkle
#endif

/// Settings window view
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var isRecordingHotkey = false
    
    @State private var hasAccessibilityPermission = false
    @State private var showResetConfirmation = false
    @State private var openAIKey = ""
    @State private var keyStatus = ""
    @AppStorage("textAIProvider") private var textAIProvider = AIProvider.none.rawValue
    @AppStorage("openAITextModel") private var openAITextModel = "gpt-5.4-mini"
    @AppStorage("chatGPTTextModel") private var chatGPTTextModel = ""
    @ObservedObject private var modelCatalog = AIModelCatalog.shared
    @ObservedObject private var aiService = AIChatService.shared
    @ObservedObject private var codexConnection = CodexConnection.shared
    
    @ObservedObject private var navigation = SettingsNavigation.shared
    @ObservedObject private var hotkeys = HotkeyHandler.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings").font(.system(size: 30, weight: .bold))
                    Text("Make Clippy yours.").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 24)
                GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 36) {
                            ForEach(SettingsPage.allCases) { section in
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(section.title).font(.system(size: 20, weight: .semibold))
                                    sectionContent(section)
                                }
                                .frame(minHeight: section == .about ? max(0, viewport.size.height - 80) : 0, alignment: .topLeading)
                                .id(section)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: SettingsSectionPositions.self,
                                        value: [section: geometry.frame(in: .named("settingsScroll")).minY])
                                })
                            }
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 80)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: "settingsScroll")
                    .onPreferenceChange(SettingsSectionPositions.self) { positions in
                        let passed = positions.filter { $0.value <= 48 }
                        if let current = passed.max(by: { $0.value < $1.value })?.key {
                            navigation.page = current
                            if current != .shortcuts { isRecordingHotkey = false }
                        }
                    }
                    .onChange(of: navigation.scrollRequest) { _, _ in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(navigation.requestedPage, anchor: .top)
                        }
                    }
                    .onAppear { proxy.scrollTo(navigation.requestedPage, anchor: .top) }
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 800, minHeight: 580)
        .tint(CoworkerBrand.blue)
        .onAppear { checkPermissions() }
        .onChange(of: settings.maxHistoryItems) { _, _ in
            ClipboardManager.shared.enforceHistoryLimit()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image("ClippyLogo").resizable().scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clippy").font(.system(size: 18, weight: .bold))
                    Text("Your clipboard, with a memory.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            VStack(spacing: 4) {
                ForEach(SettingsPage.allCases) { page in
                    Button { navigation.scroll(to: page) } label: {
                        Label(page.title, systemImage: page.symbol)
                            .font(.system(size: 13, weight: navigation.page == page ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(navigation.page == page ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(navigation.page == page ? .isSelected : [])
                }
            }
            Spacer()
            Button { DictationPromo.shared.openDownloadPage() } label: {
                HStack(spacing: 10) {
                    Image("CoworkerLogo").resizable().scaledToFit().frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get Coworker").font(.system(size: 12, weight: .semibold))
                        Text("Free voice typing").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }.buttonStyle(.plain)
            Text("Free. Open source. Yours.").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
        .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 24)
        .frame(width: 204)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private func sectionContent(_ section: SettingsPage) -> some View {
        switch section {
        case .clipboard:
            card {
                settingsToggle("Launch at login", detail: "Keep Clippy ready when your Mac starts.", value: $settings.launchAtLogin)
                if let message = settings.launchAtLoginMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if ClipboardKitConfig.allowsSimulatedKeystrokes {
                    settingsToggle("Paste on select", detail: "Insert a selected clip into the previous app.", value: $settings.autoPaste)
                    Divider()
                } else {
                    Label("Choose a clip, then press Command-V to paste.", systemImage: "doc.on.clipboard")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                }
                settingsToggle("Media bar", detail: "Keep recent images and files within reach.", value: $settings.showMediaBar)
                Divider()
                settingsToggle("Dismiss recent tiles after paste", detail: "Clips remain in your history.", value: $settings.dismissRecentOnPaste)
            }
            card { historySection }
            #if !APP_STORE
            card { permissionsSection }
            #endif
        case .shortcuts:
            card { hotkeySection }
        case .textAI:
            card { cloudAISection }
        case .companion:
            card { penguinSection }
        case .about:
            card { aboutSection }
            card { resetSection }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.05)))
    }

    private func settingsToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch)
        }
    }

    private var cloudAISection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your connection").font(.headline)
            Picker("Use AI with", selection: $textAIProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.title).tag(provider.rawValue)
                }
            }
            .onChange(of: textAIProvider) { _, value in
                AIChatService.shared.clear()
                modelCatalog.invalidate()
                codexConnection.cancelLogin()
                if value == AIProvider.chatGPT.rawValue {
                    Task { await codexConnection.refreshAccount() }
                } else {
                    codexConnection.stop()
                    Task { await modelCatalog.refresh() }
                }
            }
            if textAIProvider == AIProvider.openAI.rawValue {
                SecureField("OpenAI API key", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key") {
                        let saved = OpenAICredentials.save(openAIKey)
                        keyStatus = saved ? "Saved in Keychain." : "Couldn't save the key."
                        openAIKey = ""
                        if saved {
                            aiService.clear()
                            modelCatalog.invalidate()
                            Task { await modelCatalog.refresh() }
                        }
                    }.disabled(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove key") {
                        AIChatService.shared.clear()
                        let removed = OpenAICredentials.save("")
                        keyStatus = removed ? "Key removed." : "Couldn't remove the key."
                        openAIKey = ""
                        if removed { modelCatalog.invalidate() }
                    }
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption) }
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
                        Button { Task { await codexConnection.connect() } } label: {
                            HStack(spacing: 9) {
                                Image("ChatGPTLogo").resizable().scaledToFit().frame(width: 20, height: 20)
                                Text("Connect ChatGPT").font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(.white, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Connect ChatGPT")
                    }
                    Button("Check connection") { Task { await codexConnection.refreshAccount() } }
                        .disabled(codexConnection.isConnecting)
                }
                Text("Uses Codex through your ChatGPT account. Your plan limits apply. Clippy has a separate sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if textAIProvider != AIProvider.none.rawValue {
                Divider()
                modelAndUsageSection
            }
            Text("Only the text you send is shared with OpenAI. No voice recording. Clipboard history stays on your Mac and works without AI.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open text AI") {
                SettingsWindowController.shared.hide()
                AppDelegate.shared?.showAIPanelNearCursor()
            }.buttonStyle(.borderedProminent)
                .disabled(textAIProvider == AIProvider.none.rawValue)
        }
        .task {
            if textAIProvider == AIProvider.chatGPT.rawValue { await codexConnection.refreshAccount() }
            else { await modelCatalog.refresh() }
        }
    }

    private var modelAndUsageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model & usage").font(.headline)
                Spacer()
                if modelCatalog.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await modelCatalog.refresh() } }
                    .disabled(modelCatalog.isRefreshing)
            }
            let selected = textAIProvider == AIProvider.chatGPT.rawValue ? chatGPTTextModel : openAITextModel
            Picker("Model", selection: Binding(
                get: { textAIProvider == AIProvider.chatGPT.rawValue ? chatGPTTextModel : openAITextModel },
                set: { if textAIProvider == AIProvider.chatGPT.rawValue { chatGPTTextModel = $0 } else { openAITextModel = $0 } }
            )) {
                if !modelCatalog.models.contains(where: { $0.id == selected }) {
                    Text(selected.isEmpty ? "Choose a connection first" : "\(selected) (saved)").tag(selected)
                }
                ForEach(modelCatalog.models) { model in Text(model.title).tag(model.id) }
            }
            .disabled(modelCatalog.models.isEmpty)
            Text("Models refresh automatically when Clippy starts.").font(.caption).foregroundStyle(.secondary)
            if let refreshed = modelCatalog.refreshedAt {
                Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
            if let error = modelCatalog.modelsError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if textAIProvider == AIProvider.chatGPT.rawValue {
                Text("Codex allowance · shared across your account").font(.subheadline)
                ForEach(modelCatalog.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(window.title)
                            Spacer()
                            Text("\(window.usedPercent)% used").monospacedDigit()
                        }.font(.caption)
                        ProgressView(value: Double(min(window.usedPercent, 100)), total: 100)
                        if let reset = window.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = modelCatalog.usageError { Text(error).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("API usage below covers your latest Clippy reply.").font(.caption).foregroundStyle(.secondary)
                Link("Open API usage dashboard", destination: URL(string: "https://platform.openai.com/usage")!).font(.caption)
            }
            if let usage = aiService.lastUsage, usage.provider.rawValue == textAIProvider {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last reply · \(usage.model)").font(.caption).fontWeight(.medium)
                    Text("\(usage.input.formatted()) input · \(usage.output.formatted()) output tokens (\(usage.cached.formatted()) input cached)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Token usage appears after your next reply.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Permissions Section
    
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Permissions", systemImage: "lock.shield")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            
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
                .foregroundColor(.primary)
            
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
            Text("Open from anywhere")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            
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
            
            if let message = hotkeys.registrationMessage {
                Text(message).font(.callout).foregroundStyle(hotkeys.isActive ? Color.secondary : .orange)
            }
            HStack {
                Button("Open clipboard") {
                    SettingsWindowController.shared.hide()
                    AppDelegate.shared?.showPanelNearCursor()
                }
                if !hotkeys.isActive {
                    Button("Use an available shortcut") { hotkeys.useAvailableShortcut() }
                }
            }
            Divider()
            HStack {
                Text("Open text AI")
                Spacer()
                Text(hotkeys.aiShortcutAvailable ? "⌘⇧C" : "Unavailable").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Show or hide companion")
                Spacer()
                Text(hotkeys.companionShortcutAvailable ? "⌘⇧P" : "Unavailable").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("Click the clipboard shortcut to change it. No permission is needed.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - History Section
    
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            
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
                .foregroundColor(.primary)
            
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
            
            Button {
                AppDelegate.shared?.checkForUpdates()
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Check for Updates...")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Link("Source code", destination: URL(string: "https://github.com/mmkontis/clippy-macos")!)
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
        HotkeyHandler.shared.reregisterHotkey()
        
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
                        .foregroundColor(.primary)
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
        .onDisappear { stopRecording(); isRecording = false }
        .onChange(of: isRecording) { _, recording in
            if !recording { stopRecording() }
        }
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
        HotkeyHandler.shared.stopListening()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                self.isRecording = false
                self.stopRecording()
                return nil
            }
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
                
            }
            
            return nil // Consume the event
        }
    }
    
    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
            HotkeyHandler.shared.startListening()
        }
    }
}

// MARK: - Settings Window Controller

enum SettingsPage: String, CaseIterable, Identifiable {
    case clipboard, shortcuts, textAI, companion, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        case .clipboard: return "Clipboard"
        case .textAI: return "Text AI"
        case .companion: return "Companion"
        case .about: return "About Clippy"
        }
    }
    var subtitle: String {
        switch self {
        case .shortcuts: return "A quicker way to get there."
        case .clipboard: return "A little less searching. A little more doing."
        case .textAI: return "Write, rewrite and summarize. Always optional."
        case .companion: return "A little personality for your desktop."
        case .about: return "Your clipboard, with a memory."
        }
    }
    var symbol: String {
        switch self {
        case .shortcuts: return "keyboard"
        case .clipboard: return "clipboard"
        case .textAI: return "sparkles"
        case .companion: return "bird"
        case .about: return "info.circle"
        }
    }
}

@MainActor final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var page: SettingsPage = .clipboard
    @Published private(set) var scrollRequest = UUID()
    private(set) var requestedPage: SettingsPage = .clipboard

    func scroll(to page: SettingsPage) {
        requestedPage = page
        self.page = page
        scrollRequest = UUID()
    }
}

private struct SettingsSectionPositions: PreferenceKey {
    static let defaultValue: [SettingsPage: CGFloat] = [:]
    static func reduce(value: inout [SettingsPage: CGFloat], nextValue: () -> [SettingsPage: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func showSettings(page: SettingsPage? = nil) {
        if let page { SettingsNavigation.shared.scroll(to: page) }
        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            newWindow.contentViewController = NSHostingController(rootView: SettingsView())
            newWindow.title = "Clippy Settings"
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.titlebarSeparatorStyle = .none
            newWindow.isMovableByWindowBackground = true
            newWindow.minSize = NSSize(width: 800, height: 580)
            newWindow.setFrameAutosaveName("ClippyDesktopSettings")
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }
}

#Preview {
    SettingsView()
}
