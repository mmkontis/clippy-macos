import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotkeys = HotkeyHandler.shared
    private let ink = Color(red: 0.06, green: 0.12, blue: 0.25)

    var body: some View {
        welcomeCard
    }

    private func trustBadge(_ title: String) -> some View {
        Label(title, systemImage: "shield")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color(red: 0.40, green: 0.53, blue: 0.72))
    }

    private var welcomeCard: some View {
        ZStack {
            Color(red: 0.97, green: 0.98, blue: 1)
            RadialGradient(colors: [Color(red: 0.64, green: 0.86, blue: 1), .clear],
                           center: .trailing, startRadius: 0, endRadius: 440)
            RadialGradient(colors: [Color(red: 1, green: 0.90, blue: 0.80).opacity(0.65), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 300)
            Circle().stroke(CoworkerBrand.blue.opacity(0.08), lineWidth: 1)
                .frame(width: 470, height: 470).offset(x: 245, y: 100)
                .accessibilityHidden(true)

            VStack(spacing: 24) {
                HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 11) {
                            Image("ClippyLogo").resizable().scaledToFit()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            Text("Clippy").font(.system(size: 27, weight: .bold, design: .rounded))
                                .foregroundStyle(CoworkerBrand.blue)
                        }
                        .padding(.bottom, 26)
                        Text("Good ideas.\nAlways on hand.")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .tracking(-0.8).foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Your clipboard, with a memory.")
                            .font(.system(size: 14)).foregroundStyle(ink.opacity(0.65))
                            .padding(.top, 12)
                        Button {
                            isPresented = false
                            AppDelegate.shared?.showPanelNearCursor()
                        } label: {
                            HStack(spacing: 24) {
                                Text("Open Clippy")
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).frame(height: 44)
                            .background(CoworkerBrand.blue, in: RoundedRectangle(cornerRadius: 13))
                            .contentShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                        .padding(.top, 26)
                        if hotkeys.isActive {
                            Text("Open anytime with \(HotkeyRecorderView.displayString(modifiers: settings.hotkeyModifiers, keyCode: settings.hotkeyKeyCode))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(ink.opacity(0.6)).padding(.top, 12)
                        } else {
                            Text("Open anytime from the menu bar.")
                                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.6)).padding(.top, 12)
                        }
                    }.frame(width: 316, alignment: .leading)
                    clipboardExample
                }
                HStack(spacing: 32) {
                    trustBadge("Free")
                    trustBadge("Open source")
                    trustBadge("On your Mac")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(.horizontal, 40).padding(.top, 46).padding(.bottom, 28)
        }
        .frame(width: 720, height: 460)
        .ignoresSafeArea()
        .clipped().environment(\.colorScheme, .light)
    }

    /// Illustrative content only. Onboarding never reads or seeds clipboard history.
    private var clipboardExample: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Search your copies", systemImage: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(ink.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            Rectangle().fill(ink.opacity(0.06)).frame(height: 1)
            VStack(spacing: 8) {
                exampleRow("Your next great idea", symbol: "text.alignleft", selected: true)
                exampleRow("Friday notes", symbol: "doc.text")
                exampleRow("Design.png", symbol: "photo")
            }.padding(10)
            Spacer(minLength: 30)
            HStack(spacing: 5) {
                Image(systemName: "clipboard")
                Text("Copy. Find. Reuse.")
            }
            .font(.system(size: 10)).foregroundStyle(ink.opacity(0.4))
            .padding(14)
        }
        .frame(width: 276, height: 264)
        .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(ink.opacity(0.08), lineWidth: 1))
        .shadow(color: CoworkerBrand.blue.opacity(0.12), radius: 24, x: 0, y: 14)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example clipboard history with text, a note and an image")
    }

    private func exampleRow(_ text: String, symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18)
            Text(text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .foregroundStyle(selected ? CoworkerBrand.blue : ink.opacity(0.7))
        .padding(11)
        .background(selected ? CoworkerBrand.blue.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 9))
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        newWindow.contentView = container
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.title = "Welcome to Clippy"
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.appearance = NSAppearance(named: .aqua)
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.setFrame(NSRect(x: 0, y: 0, width: 720, height: 460), display: false)
        window = newWindow
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the welcome screen also skips setup permanently.
        #if DEBUG
        if !CommandLine.arguments.contains("--preview-onboarding") {
            AppSettings.shared.hasCompletedOnboarding = true
        }
        #else
        AppSettings.shared.hasCompletedOnboarding = true
        #endif
        completion?()
        completion = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AppDelegate.shared?.hidePanel()
    }
}
