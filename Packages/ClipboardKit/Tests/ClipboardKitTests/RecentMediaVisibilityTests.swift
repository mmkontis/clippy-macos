import XCTest
@testable import ClipboardKit

final class RecentMediaVisibilityTests: XCTestCase {
    @MainActor func testHidingPreservesQueueAndNewCopiesRevealIt() {
        let queue = RecentMediaQueue.shared
        let expansion = RecentMediaStackExpansion.shared
        queue.dismissAll()
        expansion.showRecent()
        defer { queue.dismissAll(); expansion.showRecent() }
        let first = ClipboardItem(contentType: .fileURL, fileURLString: "file:///tmp/clippy-visibility-first.png")
        queue.enqueue(first)
        expansion.reveal(3)
        expansion.hide()
        XCTAssertTrue(expansion.isHidden)
        XCTAssertFalse(expansion.isExpanded)
        XCTAssertEqual(queue.items.map(\.id), [first.id], "Hiding is not deletion")
        expansion.reveal(1)
        XCTAssertFalse(expansion.isHidden)
        XCTAssertEqual(expansion.revealCount, 1)
        expansion.hide()
        let second = ClipboardItem(contentType: .fileURL, fileURLString: "file:///tmp/clippy-visibility-second.png")
        queue.enqueue(second)
        XCTAssertFalse(expansion.isHidden, "A fresh copy should reveal recent media again")
        XCTAssertEqual(queue.items.map(\.id), [second.id, first.id])
    }
}
