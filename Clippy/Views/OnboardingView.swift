import SwiftUI
import ApplicationServices

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var hasAccessibility = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "clipboard.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            Text("Welcome to Clippy")
                .font(.system(size: 28, weight: .bold))
            Text("Free clipboard history. No account needed.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Label("Copy something, then press ⌘⇧V to find it.", systemImage: "keyboard")
                Label("You can also click Clippy in the menu bar.", systemImage: "menubar.rectangle")
                Label("Your clipboard history is stored on this Mac.", systemImage: "lock.shield")
            }
            .font(.system(size: 13))
            Text("Accessibility is optional. Enable it to paste directly into other apps. You can always copy an item and paste it yourself.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button(hasAccessibility ? "Accessibility enabled" : "Enable auto-paste") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    AXIsProcessTrustedWithOptions(options)
                }
                .disabled(hasAccessibility)
                Button("Start using Clippy") {
                    AppSettings.shared.hasCompletedOnboarding = true
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text("Optional AI sends your prompts or voice to an online provider only when you use it. Configure it in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 500, height: 450)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = AXIsProcessTrusted()
        }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private var completion: (() -> Void)?
    var isVisible: Bool { window?.isVisible ?? false }

    func showOnboarding(completion: (() -> Void)? = nil) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        self.completion = completion
        let view = OnboardingView(isPresented: Binding(
            get: { self.isVisible },
            set: { if !$0 { self.window?.close() } }
        ))
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        newWindow.contentViewController = NSHostingController(rootView: view)
        newWindow.title = "Welcome to Clippy"
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        window = newWindow
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the welcome screen also skips setup permanently.
        AppSettings.shared.hasCompletedOnboarding = true
        completion?()
        completion = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AppDelegate.shared?.hidePanel()
    }
}
