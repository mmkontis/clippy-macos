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

    /// Cap how many tiles we show at once. Older entries fall off the bottom.
    private let maxItems = 6

    private init() {}

    public func enqueue(_ item: ClipboardItem) {
        guard item.contentType == .image || item.contentType == .fileURL else { return }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
    }

    public func dismiss(_ item: ClipboardItem) {
        RecentMediaPreviewController.shared.hidePreviewIfItem(item)
        items.removeAll { $0.id == item.id }
    }

    public func dismissAll() {
        RecentMediaPreviewController.shared.hidePreview()
        items.removeAll()
    }
}
