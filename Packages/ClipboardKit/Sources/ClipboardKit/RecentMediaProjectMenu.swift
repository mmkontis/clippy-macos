import SwiftUI
import AppKit

// MARK: - Dropdown view

/// The discreet "Save to project" dropdown shown when a recent-media tile is
/// clicked. Lists the user's projects, supports creating a new one inline, and
/// auto-closes as soon as a destination is chosen.
struct RecentMediaProjectMenu: View {
    let item: ClipboardItem
    let onClose: () -> Void

    @ObservedObject private var hub = ClipboardProjectsHub.shared
    @State private var newProjectName: String = ""
    @State private var isCreating = false
    @State private var inlineError: String?
    @FocusState private var newFieldFocused: Bool

    private let width: CGFloat = 268

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            content
            newProjectRow
        }
        .padding(.vertical, 4)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
        .onAppear {
            hub.refresh()
            if hub.projects.isEmpty { newFieldFocused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Save to")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if hub.isLoadingProjects {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }

    // MARK: Project list

    @ViewBuilder
    private var content: some View {
        if hub.projects.isEmpty {
            // No placeholder copy — just the header + the inline "New project" row.
            EmptyView()
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(hub.projects) { project in
                        ProjectRow(project: project) { select(project) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)
        }
    }

    // MARK: New project

    private var newProjectRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 9)
            TextField("New project…", text: $newProjectName)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($newFieldFocused)
                .onSubmit { createAndSave() }
            if isCreating {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            } else if !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: createAndSave) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            if let inlineError {
                Text(inlineError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .offset(y: -2)
            }
        }
    }

    // MARK: Actions

    private func select(_ project: ClipboardProject) {
        hub.save(item, to: project)
        onClose()
    }

    private func createAndSave() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isCreating else { return }
        isCreating = true
        inlineError = nil
        Task {
            do {
                let project = try await hub.createProject(name: name)
                hub.save(item, to: project)
                isCreating = false
                onClose()
            } catch {
                isCreating = false
                inlineError = error.localizedDescription
            }
        }
    }
}

private struct ProjectRow: View {
    let project: ClipboardProject
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hexString: project.color) ?? Color.accentColor)
                    .frame(width: 9, height: 9)
                Text(project.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if project.assetCount > 0 {
                    Text("\(project.assetCount)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private extension Color {
    /// Parses "#RRGGBB" / "RRGGBB" (and with alpha) hex strings.
    init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255
            g = Double((value & 0x00FF0000) >> 16) / 255
            b = Double((value & 0x0000FF00) >> 8) / 255
            a = Double(value & 0x000000FF) / 255
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Panel controller

/// Hosts the dropdown in a small key-capable panel anchored beside the tile,
/// and dismisses it on outside-click / Escape. One instance at a time.
@MainActor
public final class RecentMediaProjectMenuController: ObservableObject {
    public static let shared = RecentMediaProjectMenuController()

    @Published public private(set) var activeItemId: UUID?

    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    private init() {}

    public func toggleMenu(for item: ClipboardItem, thumbnail: NSImage?) {
        if activeItemId == item.id {
            hide()
            return
        }
        show(for: item)
    }

    public func show(for item: ClipboardItem) {
        hide()

        let view = RecentMediaProjectMenu(item: item, onClose: { [weak self] in
            self?.hide()
        })
        let host = NSHostingController(rootView: view)
        host.view.frame.size.width = 268
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        let size = NSSize(width: 268, height: min(max(fitting.height, 132), 440))
        host.view.setFrameSize(size)

        let panel = KeyableMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating + 1
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.onEscape = { [weak self] in self?.hide() }

        panel.setFrameOrigin(origin(for: size))
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        activeItemId = item.id
        startOutsideClickMonitor()
    }

    public func hide() {
        activeItemId = nil
        panel?.orderOut(nil)
        panel = nil
        stopOutsideClickMonitor()
    }

    public func hideIfItem(_ item: ClipboardItem) {
        guard activeItemId == item.id else { return }
        hide()
    }

    /// Anchors the dropdown just to the right of the bottom-left stack, rising
    /// from near the click so it never covers the tile it belongs to.
    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero

        var x: CGFloat
        if let stack = RecentMediaWindowController.shared.panelFrame {
            x = stack.maxX + 8
        } else {
            x = visible.minX + 102
        }
        var y = mouse.y - size.height + 44

        if x + size.width > visible.maxX - 8 {
            x = visible.maxX - size.width - 8
        }
        x = max(visible.minX + 8, x)
        y = max(visible.minY + 8, min(y, visible.maxY - size.height - 8))
        return NSPoint(x: x, y: y)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let click = NSEvent.mouseLocation
                if NSPointInRect(click, panel.frame) { return }
                if let stackFrame = RecentMediaWindowController.shared.panelFrame,
                   NSPointInRect(click, stackFrame) {
                    return
                }
                self.hide()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}

/// Borderless panel that can take key focus (so the inline text field works)
/// and closes on Escape.
final class KeyableMenuPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
