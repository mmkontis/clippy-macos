import SwiftUI
import AppKit
import ApplicationServices
#if DEBUG
@testable import ClipboardKit
#else
import ClipboardKit
#endif
#if !APP_STORE
import Sparkle
#endif

@main
struct ClippyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Empty settings scene - we use MenuBarExtra instead
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared instance for access from SwiftUI views
    static var shared: AppDelegate?
    
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var panelWindow: NSWindow?
    private var aiPanelWindow: NSWindow?
    private var mediaBarWindow: NSWindow?
    private var penguinWindow: FloatingPenguinWindow?
    private var eventMonitor: Any?
    private var localPanelMonitor: Any?
    private var mediaDismissScroll: CGFloat = 0
    private var aiEventMonitor: Any?
    
    #if !APP_STORE
    let updaterDelegate = UpdaterDelegate.shared
    lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
    }()
    
    #endif

    static var updateActionTitle: String {
        #if APP_STORE
        "Check App Store for Updates…"
        #else
        "Check for Updates…"
        #endif
    }

    static var distributionDescription: String {
        #if APP_STORE
        "App Store edition. Updates through the Mac App Store."
        #else
        "GitHub edition. Updates through Sparkle."
        #endif
    }

    /// The application that was active before showing the panel
    static var previousActiveApp: NSRunningApplication?
    
    @MainActor
    private lazy var clipboardManager = ClipboardManager.shared
    @MainActor
    private lazy var clipboardMonitor = ClipboardMonitor.shared
    private var hotkeyHandler = HotkeyHandler.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--self-test-windows") {
            setbuf(stdout, nil)
            AppDelegate.shared = self
            ClipboardKitConfig.sharedHistoryEnabled = false
            ClipboardKitConfig.storageFolderName = "ClippyWindowTests-\(UUID().uuidString)"
            UserDefaults.standard.setVolatileDomain(["textAIProvider": "none", "showMediaBar": false], forName: UserDefaults.argumentDomain)
            Task { await runWindowRegressionChecks() }
            return
        }
        if CommandLine.arguments.contains("--preview-text-ai") {
            setbuf(stdout, nil)
            AppDelegate.shared = self
            ClipboardKitConfig.storageFolderName = "ClippyTextAIPreview"
            #if APP_STORE
            ClipboardKitConfig.allowsSimulatedKeystrokes = false
            #endif
            #if !APP_STORE
            _ = updaterController
            #endif
            setupStatusItem()
            setupHotkey()
            if CommandLine.arguments.contains("--preview-onboarding") {
                OnboardingWindowController.shared.showOnboarding()
            } else {
                SettingsWindowController.shared.showSettings()
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-listing"), CommandLine.arguments.count > index + 1 {
            captureListing(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        #endif
        // Set shared instance for access from SwiftUI views
        AppDelegate.shared = self

        // Point ClipboardKit at Clippy's storage folder and route the
        // dismiss-on-paste setting through the host's AppSettings.
        ClipboardKitConfig.storageFolderName = "Clippy"
        #if APP_STORE
        // Store builds must use the provisioned App Group, never an unrelated sandbox path.
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ClippyAppGroup") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            let alert = NSAlert()
            alert.messageText = "Clippy needs its shared storage configuration"
            alert.informativeText = "This build is not configured for distribution. Please install a verified release."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        ClipboardKitConfig.sharedContainerURL = container
        ClipboardKitConfig.allowsSimulatedKeystrokes = false
        #endif
        AppSettings.shared.configureLaunchAtLogin()
        ClipboardKitConfig.enableSharedHistory(client: "clippy")
        ClipboardKitConfig.maximumHistoryItems = { AppSettings.shared.maxHistoryItems }
        ClipboardKitConfig.dismissOnPasteEnabled = { AppSettings.shared.dismissRecentOnPaste }

        // Initialize Sparkle updater and start feed checks
        #if !APP_STORE
        _ = updaterController
        #endif
        
        setupStatusItem()
        setupHotkey()
        Task { await AIModelCatalog.shared.refresh() }
        
        Task { @MainActor in
            clipboardMonitor.startMonitoring()
            RecentMediaWindowController.shared.start()
        }
        
        // Show onboarding if not completed
        if !AppSettings.shared.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OnboardingWindowController.shared.showOnboarding()
            }
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OnboardingWindowController.shared.isVisible {
            OnboardingWindowController.shared.showOnboarding()
        } else if flag {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            SettingsWindowController.shared.showSettings()
        }
        return true
    }

    /// Checks if accessibility permission is granted
    /// Returns true if permission is granted (no prompt shown)
    @discardableResult
    func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        print("🔐 Clippy Accessibility Permission: \(trusted ? "✅ GRANTED" : "❌ NOT GRANTED")")
        return trusted
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        AIChatService.shared.cancel()
        CodexConnection.shared.cancelLogin()
        CodexConnection.shared.stop()
        // Check if we should clear history on quit
        if AppSettings.shared.clearHistoryOnQuit {
            clipboardManager.clearHistory()
        }
        
        clipboardMonitor.stopMonitoring()
        hotkeyHandler.stopListening()
    }
    
    // MARK: - Status Item Setup
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clippy")
        statusItem?.button?.toolTip = "Clippy"
        let menu = NSMenu(title: "Clippy")
        func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(entry)
            return entry
        }
        _ = item("Clipboard", #selector(showPanel), symbol: "clipboard")
        _ = item("Ask Clippy…", #selector(openTextAI), symbol: "sparkles")
        menu.addItem(.separator())
        _ = item("Settings…", #selector(openSettings), key: ",", symbol: "gearshape")
        _ = item(Self.updateActionTitle, #selector(checkForUpdates), symbol: "arrow.down.circle")
        _ = item("About Clippy", #selector(openAbout), symbol: "info.circle")
        menu.addItem(.separator())
        let coworker = item("Get Coworker", #selector(openDictationMode))
        if let logo = NSImage(named: "CoworkerLogo")?.copy() as? NSImage {
            logo.size = NSSize(width: 18, height: 18)
            coworker.image = logo
        }
        menu.addItem(.separator())
        _ = item("Quit Clippy", #selector(quitApp), key: "q")
        statusItem?.menu = menu
    }

    @objc func checkForUpdates() {
        #if APP_STORE
        if let url = URL(string: "macappstore://apps.apple.com/app/id6809036065") { NSWorkspace.shared.open(url) }
        #else
        updaterController.checkForUpdates(nil)
        #endif
    }

    @objc private func openAbout() {
        hidePanel()
        hideAIPanel()
        SettingsWindowController.shared.showSettings(page: .about)
    }

    private func togglePanel() {
        if let window = panelWindow, window.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }
    
    @objc private func showPanel() {
        showPanelWindow(nearCursor: false)
    }

    @objc private func openDictationMode() {
        DictationPromo.shared.openDownloadPage()
    }
    
    func showPanelNearCursor() {
        showPanelWindow(nearCursor: true)
    }
    
    @MainActor
    private func showPanelWindow(nearCursor: Bool = false) {
        #if DEBUG
        print("Clippy: opening clipboard window")
        #endif
        // Store the currently active application before we take focus
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            AppDelegate.previousActiveApp = frontApp
        }
        
        // Close existing window and remove both kinds of event monitor.
        panelWindow?.close()
        if let monitor = localPanelMonitor {
            NSEvent.removeMonitor(monitor)
            localPanelMonitor = nil
        }
        
        // Remove old monitor if exists
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        // Create the panel content with AI prompt and switch callbacks
        let panelView = ClipboardPanel(
            clipboardManager: clipboardManager,
            isPresented: Binding(
                get: { self.panelWindow?.isVisible ?? false },
                set: { if !$0 { self.hidePanel() } }
            ),
            onSubmitAIPrompt: { [weak self] prompt in
                self?.hidePanel()
                self?.showAIPanelAndSubmit(prompt)
            },
            onSwitchToAI: { [weak self] in
                self?.hidePanel()
                self?.showAIPanelNearCursor()
            }
        )
        
        // Create a hosting controller
        let hostingController = NSHostingController(rootView: panelView)
        
        // Create a borderless panel window
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .mainMenu + 1
        panel.hasShadow = false // Disable system shadow as we draw our own
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Position panel
        positionPanel(panel, nearCursor: nearCursor)
        
        // Activate explicitly so the shortcut also works after every window closes.
        panel.title = "Clippy Clipboard"
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        
        panelWindow = panel
        #if DEBUG
        print("Clippy: clipboard window visible: \(panel.isVisible)")
        #endif
        
        // Show media bar at bottom of screen
        showMediaBar()
        
        // Global monitors only see other apps. Local events include Settings
        // and must pass through after dismissing the clipboard.
        mediaDismissScroll = 0
        localPanelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .scrollWheel {
                if let media = self.mediaBarWindow, event.window === media,
                   abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                    self.mediaDismissScroll += abs(event.scrollingDeltaY)
                    if self.mediaDismissScroll >= 20 { self.hideMediaBar() }
                    return nil
                }
                self.mediaDismissScroll = 0
                return event
            }
            if let panel = self.panelWindow, event.window !== panel,
               event.window?.parent !== panel, event.window !== self.mediaBarWindow {
                self.hidePanel()
            }
            return event
        }

        // Monitor for clicks outside to close
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Check if click is inside media bar
            if let mediaWindow = self?.mediaBarWindow, mediaWindow.isVisible {
                let screenLocation = NSEvent.mouseLocation
                let mediaFrame = mediaWindow.frame
                if NSPointInRect(screenLocation, mediaFrame) {
                    return // Don't close if clicking media bar
                }
            }
            self?.hidePanel()
        }
    }
    
    @MainActor
    private func showMediaBar() {
        guard AppSettings.shared.showMediaBar else { return }
        // Hide existing media bar first
        hideMediaBar()
        
        // Check if there are any media items
        let mediaItems = clipboardManager.items.filter { $0.contentType == .image || $0.contentType == .fileURL }
        guard !mediaItems.isEmpty else { return }
        
        // Get screen info
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        
        guard let screen = screen else { return }
        
        let screenFrame = screen.visibleFrame
        let screenWidth = screenFrame.width
        
        // Create the view with screen width for sizing
        let mediaBarView = MediaBarView(
            clipboardManager: clipboardManager,
            onPasteItem: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.pasteAndHide()
                }
            },
            screenWidth: screenWidth
        )
        
        let hostingController = NSHostingController(rootView: mediaBarView)
        
        // Full width bar - window must be tall enough for expanded state + offset room
        let barWidth = screenWidth - 20
        let barHeight: CGFloat = 140  // Extra height for expansion room
        
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: barWidth, height: barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.contentViewController = hostingController
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .mainMenu + 2
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        window.becomesKeyOnlyIfNeeded = true
        
        // Position edge-to-edge at very bottom of screen
        let x = screenFrame.minX + 10  // 10px from left edge
        let y = screenFrame.minY + 12  // Lift up slightly to avoid edge clipping
        window.setFrameOrigin(NSPoint(x: x, y: y))
        
        window.orderFront(nil)
        mediaBarWindow = window
    }
    
    private func hideMediaBar() {
        if let window = mediaBarWindow {
            window.orderOut(nil)
            window.contentViewController = nil  // Clear view controller first
            mediaBarWindow = nil
        }
    }
    
    private func positionPanel(_ panel: NSWindow, nearCursor: Bool = false) {
        // Use known panel dimensions (from ClipboardPanel.swift .frame(width: 420, height: 480))
        let panelWidth: CGFloat = 420
        let panelHeight: CGFloat = 480
        
        // Find screen using mouse location (most reliable)
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        
        guard let screen = screen else { return }
        
        let visibleFrame = screen.visibleFrame
        
        // Calculate valid position ranges (panel origin is bottom-left)
        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - panelWidth
        let minY = visibleFrame.minY
        let maxY = visibleFrame.maxY - panelHeight
        
        var x: CGFloat
        var y: CGFloat
        
        if nearCursor {
            // Position centered on cursor, below cursor
            x = mouseLocation.x - panelWidth / 2
            y = mouseLocation.y - panelHeight - 20
        } else {
            // Position below menu bar, centered on mouse X
            x = mouseLocation.x - panelWidth / 2
            y = maxY  // Top of visible area
        }
        
        // Clamp to valid ranges
        x = max(minX, min(x, maxX))
        y = max(minY, min(y, maxY))
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    func hidePanel() {
        if let monitor = localPanelMonitor {
            NSEvent.removeMonitor(monitor)
            localPanelMonitor = nil
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        if let panel = panelWindow {
            // Detach immediately. An old fade-out must not clear a newly opened panel.
            panelWindow = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.close()
            })
        }
        
        hideMediaBar()
    }
    
    /// Helper to write debug logs
    private func debugLog(_ message: String) {
        // Clipboard content and app activity must not be persisted in debug logs.
    }
    
    /// Hides the panel, reactivates the previous app, and triggers paste if enabled
    /// Uses the same approach as Avra's pasteText() function
    func pasteAndHide() {
        let previousApp = AppDelegate.previousActiveApp
        let shouldAutoPaste = AppSettings.shared.autoPaste && ClipboardKitConfig.allowsSimulatedKeystrokes
        
        debugLog("pasteAndHide called - previousApp: \(previousApp?.localizedName ?? "nil"), autoPaste: \(shouldAutoPaste)")
        
        // Step 1: Close the panel window immediately
        if let panel = panelWindow {
            panel.orderOut(nil)
        }
        hidePanel()
        
        // Step 2: Activate the previous app (don't use NSApp.hide - it breaks delayed closures)
        if let app = previousApp {
            debugLog("Activating previous app: \(app.localizedName ?? "unknown")")
            app.activate()
        }
        
        // Step 3: Trigger paste if enabled (using same timing as Avra - 0.2s delay)
        debugLog("shouldAutoPaste: \(shouldAutoPaste)")
        if shouldAutoPaste {
            // Check accessibility permission before attempting paste
            // Only show alert for new users who haven't completed onboarding
            // and haven't dismissed the alert before
            let hasAccessibility = AXIsProcessTrusted()
            let suppressAlert = AppSettings.shared.suppressAccessibilityAlert

            if !hasAccessibility {
                // Show permission alert on main thread for new users only
                if !suppressAlert {
                    DispatchQueue.main.async { self.showAccessibilityPermissionAlert() }
                }
                // Resume monitoring without pasting
                Task { @MainActor in
                    ClipboardMonitor.shared.resumeMonitoring()
                }
                return
            }
            
            // Use DispatchQueue.global to ensure the closure runs even if main queue is busy
            // Try to paste anyway - the paste function has AppleScript fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.debugLog("Triggering paste now...")
                ClipboardManager.shared.simulatePaste()
                
                // Resume monitoring after paste completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    Task { @MainActor in
                        ClipboardMonitor.shared.resumeMonitoring()
                    }
                }
            }
        } else {
            Task { @MainActor in
                ClipboardMonitor.shared.resumeMonitoring()
            }
        }
    }
    
    /// Shows a native alert asking user to grant Accessibility permission
    private func showAccessibilityPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Clippy needs Accessibility permission to automatically paste items. Please grant access in System Settings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // Open Accessibility settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            // User clicked "Later" - suppress future alerts
            AppSettings.shared.suppressAccessibilityAlert = true
        }
    }
    
    @objc private func openTextAI() { showAIPanelNearCursor() }

    @objc private func openPenguinCreator() {
        PenguinCreatorWindowController.shared.showCreator()
    }

    @objc private func openSettings() {
        hidePanel()
        hideAIPanel()
        SettingsWindowController.shared.showSettings()
    }
    
    @objc private func clearHistory() {
        Task { @MainActor in
            clipboardManager.clearHistory()
        }
    }
    
    @objc private func quitApp() {
        AIChatService.shared.cancel()
        CodexConnection.shared.stop()
        NSApp.terminate(nil)
    }
    
    // MARK: - Hotkey Setup
    
    private func setupHotkey() {
        hotkeyHandler.onHotkeyPressed = { [weak self] in
            // Show clipboard panel near cursor when triggered by hotkey
            self?.showPanelNearCursor()
        }
        hotkeyHandler.onAIHotkeyPressed = { [weak self] in
            // Open the optional text panel from its shortcut.
            self?.showAIPanelNearCursor()
        }
        hotkeyHandler.onPenguinHotkeyPressed = { [weak self] in
            // Toggle penguin visibility when triggered by Cmd+Shift+P
            DispatchQueue.main.async {
                self?.togglePenguin()
            }
        }
        hotkeyHandler.startListening()
    }
    
    // MARK: - Penguin Modal
    
    @MainActor
    private func togglePenguin() {
        if let window = penguinWindow {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            let window = FloatingPenguinWindow()
            window.makeKeyAndOrderFront(nil)
            penguinWindow = window
        }
    }
    
    // MARK: - AI Panel
    
    func showAIPanelNearCursor() {
        showAIPanelWindow(nearCursor: true)
    }
    
    @MainActor
    private func showAIPanelWindow(nearCursor: Bool = false) {
        // Store the currently active application before we take focus
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            AppDelegate.previousActiveApp = frontApp
        }
        
        // Close existing AI window
        aiPanelWindow?.close()
        
        // Remove old monitor if exists
        if let monitor = aiEventMonitor {
            NSEvent.removeMonitor(monitor)
            aiEventMonitor = nil
        }
        
        // Create the AI panel content with callbacks
        let aiPanelView = AIPanel(
            isPresented: Binding(
                get: { self.aiPanelWindow?.isVisible ?? false },
                set: { if !$0 { self.hideAIPanel() } }
            ),
            onSubmit: { [weak self] prompt in
                // Keep the submitted answer in Clippy for explicit copying.
                self?.submitAIPromptKeepPanel(prompt)
            },
            onHide: { [weak self] in
                self?.hideAIPanel()
            },
            onSwitchToClipboard: { [weak self] in
                // Close AI panel and open clipboard panel
                self?.hideAIPanel()
                self?.showPanelNearCursor()
            }
        )
        
        // Create a hosting controller
        let hostingController = NSHostingController(rootView: aiPanelView)
        
        // Keep the prompt and answer together in a floating panel.
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .mainMenu + 1
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Position panel near cursor
        positionAIPanel(panel, nearCursor: nearCursor)
        
        panel.title = "Ask Clippy"
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        
        aiPanelWindow = panel
        
        // Monitor for clicks outside to close
        aiEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.hideAIPanel()
        }
    }
    
    private func positionAIPanel(_ panel: NSWindow, nearCursor: Bool = false) {
        let panelWidth: CGFloat = 520
        let panelHeight: CGFloat = 380
        
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        
        guard let screen = screen else { return }
        
        let visibleFrame = screen.visibleFrame
        
        var x = mouseLocation.x - panelWidth / 2
        var y = mouseLocation.y - panelHeight - 20
        
        // Clamp to screen bounds
        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - panelWidth))
        y = max(visibleFrame.minY, min(y, visibleFrame.maxY - panelHeight))
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    @MainActor
    func submitAIPromptAndStream(_ prompt: String) {
        showAIPanelAndSubmit(prompt)
    }

    @MainActor
    func showAIPanelAndSubmit(_ prompt: String) {
        showAIPanelWindow(nearCursor: true)
        submitAIPromptKeepPanel(prompt)
    }

    @MainActor
    func submitAIPromptKeepPanel(_ prompt: String) {
        AIChatService.shared.sendMessageAndStream(prompt) {}
    }

    func hideAIPanel() {
        if let monitor = aiEventMonitor {
            NSEvent.removeMonitor(monitor)
            aiEventMonitor = nil
        }
        aiPanelWindow?.close()
        aiPanelWindow = nil
    }
}

// MARK: - Floating Panel

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.hidePanel()
            } else {
                close()
            }
            return
        }
        super.keyDown(with: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        NSCursor.pointingHand.set()
        performDrag(with: event)
    }
}

// MARK: - NSApplication Extension

extension NSApplication {
    /// Activates the app and brings it to front
    func bringToFront() {
        activate(ignoringOtherApps: true)
    }
}

#if DEBUG
// Native regression checks exercise the real local event monitor and window
// delegates. No clipboard monitor, hotkeys, login item or updater is started.
extension AppDelegate {
    @MainActor private func runWindowRegressionChecks() async {
        func pause() async { try? await Task.sleep(nanoseconds: 300_000_000) }
        func check(_ passed: Bool, _ message: String) {
            print("\(passed ? "PASS" : "FAIL"): \(message)")
            if !passed { exit(1) }
        }
        SettingsWindowController.shared.showSettings()
        await pause()
        guard let settingsWindow = NSApp.windows.first(where: { $0.title == "Clippy Settings" }) else {
            check(false, "Settings window exists"); return
        }
        showPanelWindow(nearCursor: false)
        await pause()
        check(panelWindow?.isVisible == true, "Clipboard opens alongside Settings")
        // A normal local mouse event must close Clipboard and still reach Settings.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 300, y: 20),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: settingsWindow.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        await pause()
        check(panelWindow == nil && settingsWindow.isVisible, "Clicking Settings dismisses Clipboard")
        showPanelWindow(nearCursor: false)
        await pause()
        settingsWindow.makeKeyAndOrderFront(nil)
        await pause()
        check(panelWindow == nil, "Returning keyboard focus to Settings dismisses Clipboard")
        showPanelWindow(nearCursor: false)
        hidePanel()
        showPanelWindow(nearCursor: false)
        await pause()
        check(panelWindow?.isVisible == true, "An old close animation cannot hide a new Clipboard window")
        hidePanel()
        SettingsWindowController.shared.hide()
        let manager = ClipboardManager.shared
        let queue = RecentMediaQueue.shared
        let expansion = RecentMediaStackExpansion.shared
        let first = ClipboardItem(contentType: .fileURL, fileURLString: "file:///tmp/clippy-window-test-first.png")
        let second = ClipboardItem(contentType: .fileURL, fileURLString: "file:///tmp/clippy-window-test-second.png")
        manager.addItem(first)
        manager.addItem(second)
        RecentMediaWindowController.shared.start()
        expansion.reveal(2)
        await pause()
        check(RecentMediaWindowController.shared.panelFrame != nil, "Expanded media shelf is visible")
        queue.dismiss(first)
        queue.dismiss(second)
        await pause()
        check(RecentMediaWindowController.shared.panelFrame == nil, "Dismissing the last expanded tile hides the shelf")
        check(manager.items.count == 2, "Dismissing media preserves clipboard history")
        queue.enqueue(first)
        await pause()
        check(RecentMediaWindowController.shared.panelFrame != nil, "A fresh media copy reveals the shelf again")
        expansion.hide()
        await pause()
        try? FileManager.default.removeItem(at: ClipboardItem.storageDirectoryURL)
        print("Window regression checks passed.")
        exit(0)
    }
}

// Real SwiftUI views with isolated, synthetic history for reproducible listing assets.
// This mode never starts clipboard monitoring or touches the user's history.
extension AppDelegate {
    @MainActor
    private func captureListing(to output: URL) {
        #if APP_STORE
        ClipboardKitConfig.allowsSimulatedKeystrokes = false
        #endif
        ClipboardKitConfig.sharedHistoryEnabled = false
        ClipboardKitConfig.storageFolderName = "Clippy-Screenshots/" + UUID().uuidString
        let demoDirectory = ClipboardItem.storageDirectoryURL
        let manager = ClipboardManager.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.panelWindow = window
        let captures = [
            ("01-history.png", "Good ideas.\nAlways on hand.", "Everything you copy, ready when you need it.", "⌘ ⇧ V   Open your clipboard"),
            ("02-search.png", "Less searching.\nMore finding.", "A word is all it takes to find that thing.", "Search notes, links and more"),
            ("03-images.png", "More than\njust words.", "Keep your images and files close, too.", "Text, images and files together"),
            ("04-coworker.png", "A little help\nfrom your voice.", "Meet Coworker. An optional companion\nfor typing with your voice.", "Your clipboard needs no account"),
            ("05-media-bar.png", "Your files.\nWithin reach.", "A floating shelf for the images\nand files you copy.", "Enable Show Media Bar in Settings")
        ]
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func seed(_ index: Int) {
            manager.clearHistory()
            let examples: [(String, String)]
            switch index {
            case 1:
                examples = [
                    ("Coffee catch-up with Alex, Friday at 10", "Calendar"),
                    ("https://example.com/coffee-guide", "Safari"),
                    ("Weekend list: coffee, apples, fresh bread", "Notes"),
                    ("Send the project outline on Monday", "Reminders")
                ]
            case 2:
                examples = [("Logo ideas for the next big thing", "Notes"), ("Brand palette: #2563EB · #38BDF8", "Notes")]
            case 3:
                examples = [
                    ("Thanks for the feedback. I’ll send an update today.", "Mail"),
                    ("Let’s meet tomorrow at 10. Coffee is on me!", "Messages"),
                    ("Three ideas for our next launch", "Notes"),
                    ("Remember to book the meeting room", "Reminders"),
                    ("A little less searching. A little more doing.", "Notes")
                ]
            default:
                examples = [
                    ("Your next great idea starts here.", "Notes"),
                    ("Shopping list: coffee, apples, fresh bread", "Notes"),
                    ("https://github.com/mmkontis/clippy-macos", "Safari"),
                    ("The launch checklist is ready to share", "Messages"),
                    ("Design review, Thursday at 14:00", "Calendar"),
                    ("#2563EB. That’s the blue!", "Notes"),
                    ("Thanks! I’ll take a look this afternoon.", "Mail"),
                    ("See you tomorrow at 10:00 ☕", "Messages")
                ]
            }
            for (text, source) in examples.reversed() {
                manager.addItem(.fromText(text, source: source))
            }
            if index == 2 || index == 4 {
                let sampleFile = demoDirectory.appendingPathComponent("Launch notes.txt")
                try? "A fresh start. A bright blue palette. A little less searching.".write(to: sampleFile, atomically: true, encoding: .utf8)
                manager.addItem(.fromFileURL(sampleFile, source: "Finder"))
                if index == 4 {
                    let samplePDF = demoDirectory.appendingPathComponent("Project brief.pdf")
                    let page = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
                    let label = NSTextField(wrappingLabelWithString: "PROJECT BRIEF\n\nA bright start.\n\nIdeas, images and notes for our next launch.")
                    label.font = .systemFont(ofSize: 28, weight: .semibold)
                    label.textColor = .systemBlue
                    label.frame = NSRect(x: 32, y: 80, width: 336, height: 370)
                    page.addSubview(label)
                    try? page.dataWithPDF(inside: page.bounds).write(to: samplePDF)
                    manager.addItem(.fromFileURL(samplePDF, source: "Finder"))
                    if let logo = NSImage(named: "CoworkerLogo"), let item = ClipboardItem.fromImage(logo, source: "Preview") {
                        manager.addItem(item)
                    }
                }
                if let logo = NSImage(named: "ClippyLogo"), let item = ClipboardItem.fromImage(logo, source: "Preview") {
                    manager.addItem(item)
                }
            }
        }
        func render(_ index: Int) {
            guard index < captures.count else {
                let wordmark = NSHostingView(rootView: ClippyListingWordmark().padding(20))
                wordmark.frame = NSRect(x: 0, y: 0, width: 270, height: 118)
                window.contentView = wordmark
                window.setContentSize(NSSize(width: 270, height: 118))
                wordmark.layoutSubtreeIfNeeded()
                if let bitmap = wordmark.bitmapImageRepForCachingDisplay(in: wordmark.bounds) {
                    wordmark.cacheDisplay(in: wordmark.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("clippy-wordmark.png"))
                }
                try? FileManager.default.removeItem(at: demoDirectory)
                NSApp.terminate(nil)
                return
            }
            seed(index)
            let entry = captures[index]
            let view = ListingScreenshot(title: entry.1, subtitle: entry.2, detail: entry.3, index: index, manager: manager)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                manager.searchQuery = index == 1 ? "coffee" : ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    hosting.layoutSubtreeIfNeeded()
                    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: output.appendingPathComponent(entry.0))
                        }
                    }
                    render(index + 1)
                }
            }
        }
        render(0)
    }
}
private struct ClippyListingWordmark: View {
    var body: some View {
        HStack(spacing: 16) {
            Image("ClippyLogo").resizable().frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 19))
            Text("Clippy").font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(CoworkerBrand.blue)
        }
    }
}
private struct ListingScreenshot: View {
    let title: String
    let subtitle: String
    let detail: String
    let index: Int
    @ObservedObject var manager: ClipboardManager
    var body: some View {
        ZStack {
            Color(red: 0.97, green: 0.98, blue: 1)
            RadialGradient(colors: [Color(red: 0.64, green: 0.86, blue: 1), .clear], center: .trailing, startRadius: 40, endRadius: 740)
            RadialGradient(colors: [Color(red: 1, green: 0.90, blue: 0.80).opacity(0.7), .clear], center: .topLeading, startRadius: 0, endRadius: 530)
            Circle().stroke(CoworkerBrand.blue.opacity(0.09), lineWidth: 1.5)
                .frame(width: 780, height: 780).offset(x: 420, y: 180)
            Circle().stroke(CoworkerBrand.blue.opacity(0.07), lineWidth: 1.5)
                .frame(width: 950, height: 950).offset(x: 420, y: 180)
            RoundedRectangle(cornerRadius: 100)
                .fill(LinearGradient(colors: [CoworkerBrand.blue.opacity(0.14), Color.cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 500, height: 590).rotationEffect(.degrees(index % 2 == 0 ? 10 : -10)).offset(x: 340, y: 35)
            HStack(spacing: 72) {
                VStack(alignment: .leading, spacing: 26) {
                    ClippyListingWordmark()
                    .padding(.bottom, 12)
                    Text(title).font(.system(size: 55, weight: .bold, design: .rounded))
                        .tracking(-1.8).lineSpacing(0).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color(red: 0.06, green: 0.12, blue: 0.25))
                    Text(subtitle).font(.system(size: 22)).lineSpacing(5)
                        .foregroundStyle(Color(red: 0.29, green: 0.36, blue: 0.47))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: 15, weight: .semibold)).foregroundStyle(CoworkerBrand.blue)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.white.opacity(0.85), in: Capsule())
                    Text("FREE  ·  OPEN SOURCE  ·  MADE FOR MAC")
                        .font(.system(size: 12, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(Color(red: 0.36, green: 0.42, blue: 0.53)).padding(.top, 10)
                }.frame(width: 490, alignment: .leading)
                ClipboardPanel(clipboardManager: manager, isPresented: .constant(true), promotionOverride: index == 3)
                    .scaleEffect(index == 4 ? 0.95 : 1.15).frame(width: 483, height: 552)
            }.padding(.horizontal, 72).offset(y: index == 4 ? -65 : 0)
            if index == 4 {
                MediaBarView(clipboardManager: manager, screenWidth: 1000)
                    .frame(width: 1000, height: 140).position(x: 640, y: 750)
            }
        }.frame(width: 1280, height: 800).clipped().environment(\.colorScheme, .light)
    }
}
#endif
