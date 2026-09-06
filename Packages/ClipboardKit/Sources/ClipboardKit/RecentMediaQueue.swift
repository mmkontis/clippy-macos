import Foundation
import Combine

/// Holds the freshly-copied image/file items that the user has not yet
/// dismissed from the bottom-left "recent media" stack. Distinct from the
/// full clipboard history in ClipboardManager — items here are session-only
/// and disappear when the user swipes/clicks them away.
@MainActor
public final class RecentMediaQueue: ObservableObject {
    public static let shared = RecentMediaQueue()

    @Published public private(set) var items: [ClipboardItem] = []

    @Published public private(set) var dismissedIDs: Set<UUID> = []
    private var copiedIDs: Set<UUID> = []
    private var copiedChangeCount: Int?

    /// Session dismissal applies to expanded history too, without deleting it.
    public func visibleHistory(from history: [ClipboardItem]) -> [ClipboardItem] {
        history.filter { $0.isDraggableMedia && !dismissedIDs.contains($0.id) }
    }

    public func recordPasteboardCopy(_ ids: [UUID], changeCount: Int) {
        copiedIDs = Set(ids)
        copiedChangeCount = changeCount
    }

    func dismissPastedMedia(changeCount: Int) {
        guard copiedChangeCount == changeCount else { return }
        for id in copiedIDs {
            dismiss(id: id)
        }
    }

    /// Cap how many tiles we show at once. Older entries fall off the bottom.
    private let maxItems = 6

    private init() {}

    public func enqueue(_ item: ClipboardItem) {
        guard item.contentType == .image || item.contentType == .fileURL else { return }
        RecentMediaStackExpansion.shared.showRecent()
        dismissedIDs.remove(item.id)
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
    }

    public func dismiss(_ item: ClipboardItem) {
        dismiss(id: item.id)
    }

    private func dismiss(id: UUID) {
        if RecentMediaPreviewController.shared.activeItemId == id {
            RecentMediaPreviewController.shared.hidePreview()
        }
        if RecentMediaProjectMenuController.shared.activeItemId == id {
            RecentMediaProjectMenuController.shared.hide()
        }
        dismissedIDs.insert(id)
        items.removeAll { $0.id == id }
    }

    public func dismissAll() {
        RecentMediaPreviewController.shared.hidePreview()
        RecentMediaProjectMenuController.shared.hide()
        dismissedIDs.formUnion(items.map(\.id))
        items.removeAll()
    }
}
