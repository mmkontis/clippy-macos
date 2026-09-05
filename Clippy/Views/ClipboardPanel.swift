import SwiftUI
import Carbon.HIToolbox
import ClipboardKit

/// The main clipboard history panel view
struct ClipboardPanel: View {
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject private var dictationPromo = DictationPromo.shared
    @State private var selectedIndex: Int = 0
    @Binding var isPresented: Bool
    @State private var eventMonitor: Any?
    
    // Callback to submit an AI prompt directly
    var onSubmitAIPrompt: ((_ prompt: String) -> Void)?
    // Callback to switch to AI panel (no text in search)
    var onSwitchToAI: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with search
            headerView
                .background(
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                )
            
            // Clipboard items list
            if clipboardManager.filteredItems.isEmpty {
                emptyStateView
            } else {
                itemsListView
            }

            // Dictation cross-promo: prominent banner by default, and a discrete
            // always-present row once it's been dismissed.
            if dictationPromo.bannerVisible {
                DictationBanner()
            } else {
                DictationModeRow()
            }

            // Footer with hints
            footerView
        }
        .frame(width: 420, height: 480)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(0.92)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
        .onAppear {
            // Clear search query each time panel opens
            clipboardManager.searchQuery = ""
            selectedIndex = 0
            setupCmdNumberMonitor()
        }
        .onDisappear {
            removeCmdNumberMonitor()
        }
        .onKeyPress(.escape) {
            closePanel()
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            selectCurrentItem()
            return .handled
        }
    }
    
    // MARK: - Cmd+Number Handling
    
    private func setupCmdNumberMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Check if Command is held (but not other modifiers like Shift/Option)
            if event.modifierFlags.contains(.command) && 
               !event.modifierFlags.contains(.shift) &&
               !event.modifierFlags.contains(.option) {
                if let chars = event.charactersIgnoringModifiers,
                   let digit = Int(chars), digit >= 0 && digit <= 9 {
                    let index = digit == 0 ? 9 : digit - 1
                    selectItemAtIndex(index)
                    return nil // Consume the event
                }
            }
            return event
        }
    }
    
    private func removeCmdNumberMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack(spacing: 10) {
            // Regular search field
            SearchField(
                text: $clipboardManager.searchQuery,
                onSubmit: {
                    selectCurrentItem()
                }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            
            // Sparkle button: if search text is present, use it as AI prompt; otherwise switch to AI panel
            Button(action: {
                let query = clipboardManager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty {
                    onSubmitAIPrompt?(query)
                } else {
                    onSwitchToAI?()
                }
            }) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                            .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Switch to AI (Cmd+Shift+C)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
    
    private var itemsListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(clipboardManager.filteredItems.enumerated()), id: \.element.id) { index, item in
                        Group {
                            if item.contentType == .image {
                                ClipboardImageRow(
                                    item: item,
                                    index: index + 1,
                                    isSelected: selectedIndex == index,
                                    onSelect: {
                                        pasteItem(item)
                                    },
                                    onDelete: {
                                        deleteItem(item)
                                    },
                                    onShowPreview: { previewItem, rect in
                                        PreviewWindowController.shared.showPreview(for: previewItem, near: rect)
                                    },
                                    onHidePreview: {
                                        PreviewWindowController.shared.hidePreview()
                                    }
                                )
                            } else {
                                ClipboardItemRow(
                                    item: item,
                                    index: index + 1,
                                    isSelected: selectedIndex == index,
                                    onSelect: {
                                        pasteItem(item)
                                    },
                                    onDelete: {
                                        deleteItem(item)
                                    },
                                    onShowPreview: { previewItem, rect in
                                        PreviewWindowController.shared.showPreview(for: previewItem, near: rect)
                                    },
                                    onHidePreview: {
                                        PreviewWindowController.shared.hidePreview()
                                    }
                                )
                            }
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            
            Image(systemName: clipboardManager.searchQuery.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.blue.opacity(0.6))
                .symbolEffect(.bounce, options: .nonRepeating, value: clipboardManager.searchQuery.isEmpty)
            
            Text(clipboardManager.searchQuery.isEmpty ? "No clipboard history" : "No matching items")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary.opacity(0.8))
            
            Text(clipboardManager.searchQuery.isEmpty ? "Copy something to get started" : "Try a different search term")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.8))
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private var footerView: some View {
        HStack {
            HStack(spacing: 12) {
                hintItem(keys: ["↑", "↓"], text: "Navigate")
                hintItem(keys: ["↵"], text: "Paste")
                hintItem(keys: ["⌘1-0"], text: "Quick paste")
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.6))
                
                Button {
                    clipboardManager.clearHistory()
                } label: {
                    Text("Clear")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                
                Button {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.hidePanel()
                    }
                    SettingsWindowController.shared.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(5)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }
    
    private func hintItem(keys: [String], text: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.9))
        }
    }
    
    // MARK: - Actions
    
    private func moveSelection(by delta: Int) {
        let newIndex = selectedIndex + delta
        let itemCount = clipboardManager.filteredItems.count
        
        if itemCount > 0 {
            if newIndex < 0 {
                selectedIndex = itemCount - 1
            } else if newIndex >= itemCount {
                selectedIndex = 0
            } else {
                selectedIndex = newIndex
            }
        }
    }
    
    private func selectCurrentItem() {
        guard selectedIndex >= 0 && selectedIndex < clipboardManager.filteredItems.count else { return }
        let item = clipboardManager.filteredItems[selectedIndex]
        pasteItem(item)
    }
    
    private func selectItemAtIndex(_ index: Int) {
        guard index >= 0 && index < clipboardManager.filteredItems.count else { return }
        let item = clipboardManager.filteredItems[index]
        pasteItem(item)
    }
    
    /// Helper to write debug logs to file
    private func debugLog(_ message: String) {
        // Clipboard content and app activity must not be persisted in debug logs.
    }
    
    private func pasteItem(_ item: ClipboardItem) {
        debugLog("Clipboard item selected")
        
        // Pause monitoring to avoid re-adding our own paste
        ClipboardMonitor.shared.pauseMonitoring()
        
        // Copy to clipboard first
        clipboardManager.pasteItem(item, triggerPaste: false)
        debugLog("Item copied to clipboard")
        
        // Use AppDelegate.shared to handle the hide and paste sequence safely
        if let appDelegate = AppDelegate.shared {
            debugLog("Calling pasteAndHide on AppDelegate.shared")
            appDelegate.pasteAndHide()
        } else {
            debugLog("AppDelegate.shared not found, just closing panel")
            closePanel()
        }
    }
    
    private func deleteItem(_ item: ClipboardItem) {
        clipboardManager.removeItem(item)
        // Adjust selection if needed
        if selectedIndex >= clipboardManager.filteredItems.count {
            selectedIndex = max(0, clipboardManager.filteredItems.count - 1)
        }
    }
    
    private func closePanel() {
        PreviewWindowController.shared.hidePreview()
        clipboardManager.searchQuery = ""
        selectedIndex = 0
        isPresented = false
    }
}

// MARK: - Supporting Views

struct KeyboardShortcutHint: View {
    let keys: [String]
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            }
        }
    }
}

/// NSVisualEffectView wrapper for SwiftUI
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Dictation cross-promo

/// Shared state for the "get the dictation app" promo. Drives the dismissible
/// banner at the bottom of the clipboard panel; opened from the status-bar menu,
/// the panel's discrete row, and Settings. The dictation app is Coworker
/// (voice → text anywhere).
@MainActor
final class DictationPromo: ObservableObject {
    static let shared = DictationPromo()

    /// The special page opened from Clippy to get the dictation app.
    static let pageURL = URL(string: "https://www.tryhumanlike.com/clippy/dictation")!

    private let dismissedKey = "dictationBannerDismissed"
    @Published var bannerVisible: Bool

    private init() {
        bannerVisible = !UserDefaults.standard.bool(forKey: dismissedKey)
    }

    /// Show the banner now (from a menu item / row / settings button).
    func reveal() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            bannerVisible = true
        }
    }

    /// Hide the banner and remember the choice so it doesn't auto-show again.
    func dismiss() {
        UserDefaults.standard.set(true, forKey: dismissedKey)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            bannerVisible = false
        }
    }

    /// Open the special download page in the default browser.
    func openDownloadPage() {
        NSWorkspace.shared.open(Self.pageURL)
    }
}

/// Small "NEW" pill used on dictation entry points.
struct DictationNewBadge: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                )
            )
    }
}

/// Dismissible download banner promoting the dictation app.
struct DictationBanner: View {
    @ObservedObject private var promo = DictationPromo.shared

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Type with your voice")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    DictationNewBadge()
                }
                Text("Coworker turns speech into text in any app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: { promo.openDownloadPage() }) {
                Text("Explore")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                        )
                    )
            }
            .buttonStyle(.plain)

            Button(action: { promo.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss Coworker promotion")
            .accessibilityLabel("Dismiss Coworker promotion")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.07))
        .overlay(
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1),
            alignment: .top
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Discrete always-present row that re-opens the dictation banner. Shown in the
/// panel once the banner has been dismissed.
struct DictationModeRow: View {
    var body: some View {
        Button(action: { DictationPromo.shared.reveal() }) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                Text("Explore Coworker dictation")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                DictationNewBadge()
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1),
            alignment: .top
        )
    }
}

#Preview {
    ClipboardPanel(
        clipboardManager: ClipboardManager.shared,
        isPresented: .constant(true)
    )
}

