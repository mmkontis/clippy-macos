import SwiftUI
import AppKit
import ApplicationServices
import ClipboardKit
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
    private var aiEventMonitor: Any?
    
    #if !APP_STORE
    let updaterDelegate = UpdaterDelegate.shared
    lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
    }()
    
    #endif

    /// The application that was active before showing the panel
    static var previousActiveApp: NSRunningApplication?
    
    @MainActor
    private lazy var clipboardManager = ClipboardManager.shared
    @MainActor
    private lazy var clipboardMonitor = ClipboardMonitor.shared
    private var hotkeyHandler = HotkeyHandler.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
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
        ClipboardKitConfig.enableSharedHistory(client: "clippy")
        ClipboardKitConfig.maximumHistoryItems = { AppSettings.shared.maxHistoryItems }
        ClipboardKitConfig.dismissOnPasteEnabled = { AppSettings.shared.dismissRecentOnPaste }

        // Initialize Sparkle updater and start feed checks
        #if !APP_STORE
        _ = updaterController
        #endif
        
        setupStatusItem()
        setupHotkey()
        
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
    
    /// Checks if accessibility permission is granted
    /// Returns true if permission is granted (no prompt shown)
    @discardableResult
    func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        print("🔐 Clippy Accessibility Permission: \(trusted ? "✅ GRANTED" : "❌ NOT GRANTED")")
        return trusted
    }
    
    func applicationWillTerminate(_ notification: Notification) {
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
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clippy")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        
        if event.type == .rightMouseUp {
            // Show context menu on right-click
            showContextMenu()
        } else {
            // Toggle panel on left-click
            togglePanel()
        }
    }
    
    private func showContextMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Show Clipboard History", action: #selector(showPanel), keyEquivalent: ""))

        let dictationItem = NSMenuItem(title: "Get Coworker Dictation", action: #selector(openDictationMode), keyEquivalent: "")
        dictationItem.target = self
        dictationItem.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        menu.addItem(dictationItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize Penguin...", action: #selector(openPenguinCreator), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        #if !APP_STORE
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "u")
        updateItem.target = updaterController
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())
        #endif
        menu.addItem(NSMenuItem(title: "Quit Clippy", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }
    
    private func togglePanel() {
        if let window = panelWindow, window.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }
    
    @objc private func showPanel() {
        Task { @MainActor in
            showPanelWindow(nearCursor: false)
        }
    }

    /// Opens the clipboard panel and reveals the dictation download banner.
    @objc private func openDictationMode() {
        Task { @MainActor in
            DictationPromo.shared.reveal()
            showPanelWindow(nearCursor: false)
        }
    }
    
    func showPanelNearCursor() {
        Task { @MainActor in
            showPanelWindow(nearCursor: true)
        }
    }
    
    @MainActor
    private func showPanelWindow(nearCursor: Bool = false) {
        // Store the currently active application before we take focus
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            AppDelegate.previousActiveApp = frontApp
        }
        
        // Close existing window
        panelWindow?.close()
        
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
        
        // Show the panel with animation
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        
        panelWindow = panel
        
        // Show media bar at bottom of screen
        showMediaBar()
        
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
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        if let panel = panelWindow {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.close()
                self.panelWindow = nil
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
    
    @objc private func openPenguinCreator() {
        PenguinCreatorWindowController.shared.showCreator()
    }

    @objc private func openSettings() {
        hidePanel()
        SettingsWindowController.shared.showSettings()
    }
    
    @objc private func clearHistory() {
        Task { @MainActor in
            clipboardManager.clearHistory()
        }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    
    // MARK: - Hotkey Setup
    
    private func setupHotkey() {
        hotkeyHandler.onHotkeyPressed = { [weak self] in
            // Show clipboard panel near cursor when triggered by hotkey
            self?.showPanelNearCursor()
        }
        hotkeyHandler.onAIHotkeyPressed = { [weak self] in
            // Show AI panel near cursor when triggered by Cmd+Shift+CapsLock
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
        Task { @MainActor in
            showAIPanelWindow(nearCursor: true)
        }
    }
    
    @MainActor
    private func showAIPanelWindow(nearCursor: Bool = false) {
        #if APP_STORE
        return // Streaming keystroke insertion belongs to the direct-download edition.
        #endif
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
                // Activate previous app and start streaming, but keep panel open for spinner
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
        
        // Create a borderless panel window - smaller for just input
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 48),
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
        
        // Show the panel
        panel.makeKeyAndOrderFront(nil)
        
        aiPanelWindow = panel
        
        // Monitor for clicks outside to close
        aiEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.hideAIPanel()
        }
    }
    
    private func positionAIPanel(_ panel: NSWindow, nearCursor: Bool = false) {
        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 48
        
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
    
    /// Hides panels, activates previous app, and starts streaming the AI response
    func submitAIPromptAndStream(_ prompt: String) {
        let previousApp = AppDelegate.previousActiveApp
        
        // Hide both panels (whichever is open)
        hideAIPanel()
        hidePanel()
        
        // Activate the previous app
        if let app = previousApp {
            app.activate()
        }
        
        // Wait longer for app to fully activate and focus input before streaming
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            AIChatService.shared.sendMessageAndStream(prompt) {
                print("AI streaming complete")
            }
        }
    }
    
    /// Shows the AI panel and immediately submits a prompt (used from clipboard panel sparkle button)
    func showAIPanelAndSubmit(_ prompt: String) {
        AIChatService.shared.prepareForStreaming()
        
        Task { @MainActor in
            showAIPanelWindow(nearCursor: true)
            submitAIPromptKeepPanel(prompt)
        }
    }

    /// Activates previous app and starts streaming, but keeps AI panel open for spinner
    func submitAIPromptKeepPanel(_ prompt: String) {
        let previousApp = AppDelegate.previousActiveApp
        
        // Show spinner immediately before any delay
        AIChatService.shared.prepareForStreaming()
        
        // Activate the previous app (but keep AI panel visible)
        if let app = previousApp {
            app.activate()
        }
        
        // Wait for app to fully activate and focus input before streaming
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AIChatService.shared.sendMessageAndStream(prompt) {
                print("AI streaming complete")
            }
        }
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
    override var canBecomeMain: Bool { false }
    
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
        ["See you tomorrow at 10:00 ☕", "A little less searching. A little more doing.",
         "https://github.com/mmkontis/clippy-macos", "Shopping list: coffee, apples, fresh bread",
         "Your next great idea starts here."].forEach { manager.addItem(.fromText($0, source: "Notes")) }
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.panelWindow = window
        let captures = [
            ("01-history.png", "Copy once.\nFind it whenever.", "Your clipboard, with a memory."),
            ("02-search.png", "Find that thing\nyou copied.", "Search your history in a moment.")
        ]
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func render(_ index: Int) {
            guard index < captures.count else {
                try? FileManager.default.removeItem(at: demoDirectory)
                NSApp.terminate(nil)
                return
            }
            let entry = captures[index]
            let view = ListingScreenshot(title: entry.1, subtitle: entry.2, manager: manager)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                manager.searchQuery = index == 1 ? "idea" : ""
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
private struct ListingScreenshot: View {
    let title: String
    let subtitle: String
    @ObservedObject var manager: ClipboardManager
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.94, green: 0.97, blue: 1), Color(red: 0.80, green: 0.88, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 90) {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Clippy", systemImage: "clipboard.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(.blue)
                    Text(title).font(.system(size: 54, weight: .bold, design: .rounded)).tracking(-1.5)
                    Text(subtitle).font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("Free. Open source. No account.").font(.system(size: 17, weight: .medium)).padding(.top, 14)
                }.frame(width: 490, alignment: .leading)
                ClipboardPanel(clipboardManager: manager, isPresented: .constant(true))
            }.padding(80)
        }.frame(width: 1280, height: 800).environment(\.colorScheme, .light)
    }
}
#endif
