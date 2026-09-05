import SwiftUI
import AppKit

/// Backs the NSDraggingSession so we get a real drag-completion callback
/// (which `.onDrag` does not expose). When the drop succeeds anywhere
/// outside our app, the source tile auto-disappears.
public final class DragSourceBridge: NSObject, NSDraggingSource, ObservableObject {
    public weak var attachedView: NSView?
    public var onDragSucceeded: (() -> Void)?

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return [.copy]
        case .withinApplication:
            return [.copy, .move]
        @unknown default:
            return [.copy]
        }
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation != [], operation != .delete else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onDragSucceeded?()
        }
    }
}

/// Drops a sibling NSView underneath the tile so we have a stable handle to
/// hand to `beginDraggingSession`. SwiftUI sizes us to match the tile bounds.
public struct DragSourceAttach: NSViewRepresentable {
    let bridge: DragSourceBridge

    public init(bridge: DragSourceBridge) {
        self.bridge = bridge
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        bridge.attachedView = view
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        bridge.attachedView = nsView
    }
}

/// Shared drag-out helpers used by the recent-media stack and media bar.
public enum MediaDragSupport {
    public static func startDrag(
        for item: ClipboardItem,
        bridge: DragSourceBridge,
        tileSize: CGFloat,
        preloadedImage: NSImage?
    ) {
        guard let nsView = bridge.attachedView else { return }
        guard let event = NSApp.currentEvent ?? nsView.window?.currentEvent else { return }
        guard let writer = item.makeDragPasteboardWriter() else { return }

        let dragItem = NSDraggingItem(pasteboardWriter: writer)
        let visual = item.dragVisual(preloadedImage: preloadedImage)
            ?? NSImage(size: NSSize(width: tileSize, height: tileSize))
        dragItem.setDraggingFrame(nsView.bounds, contents: visual)

        nsView.beginDraggingSession(with: [dragItem], event: event, source: bridge)
    }
}
