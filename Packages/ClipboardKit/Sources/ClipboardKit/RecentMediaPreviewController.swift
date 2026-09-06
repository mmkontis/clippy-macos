import SwiftUI
import AppKit

/// Toggleable preview modal for items in the bottom-left recent media stack.
@MainActor
public final class RecentMediaPreviewController: ObservableObject {
    public static let shared = RecentMediaPreviewController()

    @Published public private(set) var activeItemId: UUID?

    public var panelFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }
    private var panel: NSPanel?
    private var hosting: NSHostingController<RecentMediaPreviewPanel>?
    private var outsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?

    private init() {}

    public func togglePreview(for item: ClipboardItem, thumbnail: NSImage?) {
        if activeItemId == item.id {
            hidePreview()
            return
        }
        showPreview(for: item, thumbnail: thumbnail)
    }

    public func showPreview(for item: ClipboardItem, thumbnail: NSImage?) {
        hidePreview()

        let previewView = RecentMediaPreviewPanel(item: item, thumbnail: thumbnail)
        let host = NSHostingController(rootView: previewView)

        let size = previewSize(for: item)
        host.view.setFrameSize(NSSize(width: size.width, height: size.height))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true

        let origin = previewOrigin(size: size)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hosting = host
        activeItemId = item.id
        startOutsideClickMonitor()
    }

    public func hidePreview() {
        activeItemId = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        stopOutsideClickMonitor()
    }

    public func hidePreviewIfItem(_ item: ClipboardItem) {
        guard activeItemId == item.id else { return }
        hidePreview()
    }

    private func previewSize(for item: ClipboardItem) -> NSSize {
        switch item.contentType {
        case .image:
            return NSSize(width: 444, height: 490)
        case .fileURL:
            if item.isImageFile {
                return NSSize(width: 444, height: 490)
            }
            if let url = item.fileURL, FileContentLoader.loadText(from: url) != nil {
                return NSSize(width: 440, height: 434)
            }
            return NSSize(width: 320, height: 120)
        default:
            return NSSize(width: 320, height: 120)
        }
    }

    /// Places the modal just above the media stack in the bottom-left corner.
    private func previewOrigin(size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero

        let stackWidth: CGFloat = 80 + 28
        let stackPadding: CGFloat = 14
        let gap: CGFloat = 10

        var x = visible.minX + stackPadding
        var y = visible.minY + stackPadding + 80 + gap

        if x + size.width > visible.maxX - 8 {
            x = visible.maxX - size.width - 8
        }
        if y + size.height > visible.maxY - 8 {
            y = mouse.y - size.height / 2
        }

        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        y = max(visible.minY + 8, min(y, visible.maxY - size.height - 8))

        _ = stackWidth
        return NSPoint(x: x, y: y)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.window === panel || event.window?.parent === panel { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            if let stack = RecentMediaWindowController.shared.panelFrame, NSPointInRect(point, stack) { return event }
            self.hidePreview()
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let click = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if NSPointInRect(click, panel.frame) { return }
                if let stackFrame = RecentMediaWindowController.shared.panelFrame,
                   NSPointInRect(click, stackFrame) {
                    return
                }
                self.hidePreview()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = localOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            localOutsideClickMonitor = nil
        }
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
