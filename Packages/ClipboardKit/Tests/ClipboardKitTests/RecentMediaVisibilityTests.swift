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
    @MainActor func testDismissedExpandedItemsStayOutOfShelfButRemainInHistory() {
        let queue = RecentMediaQueue.shared
        queue.dismissAll()
        defer { queue.dismissAll(); RecentMediaStackExpansion.shared.showRecent() }
        let recent = ClipboardItem(contentType: .fileURL, fileURLString: "file:///tmp/recent.png")
        let older = ClipboardItem(contentType: .fileURL, fileURLString: "file:///tmp/older.png")
        let history = [recent, older]
        queue.enqueue(recent)
        RecentMediaStackExpansion.shared.reveal(2)
        queue.dismiss(recent)
        XCTAssertEqual(queue.visibleHistory(from: history).map(\.id), [older.id])
        queue.dismiss(older)
        queue.dismiss(older) // A repeated dismissal must not become a history deletion.
        XCTAssertTrue(queue.visibleHistory(from: history).isEmpty)
        XCTAssertEqual(history.map(\.id), [recent.id, older.id])
        queue.enqueue(older)
        XCTAssertEqual(queue.visibleHistory(from: history).map(\.id), [older.id], "Copying again restores the dismissed tile")
    }

    @MainActor func testPasteDismissesMatchingCopyOnlyAndNeverNextTile() {
        let queue = RecentMediaQueue.shared
        queue.dismissAll()
        defer { queue.dismissAll(); RecentMediaStackExpansion.shared.showRecent() }
        let first = ClipboardItem(contentType: .fileURL, fileURLString: "file:///tmp/first.png")
        let second = ClipboardItem(contentType: .fileURL, fileURLString: "file:///tmp/second.png")
        queue.enqueue(first); queue.enqueue(second)
        queue.recordPasteboardCopy([first.id], changeCount: 12)
        queue.dismissPastedMedia(changeCount: 13) // A subsequent text copy.
        XCTAssertEqual(queue.items.map(\.id), [second.id, first.id])
        queue.dismissPastedMedia(changeCount: 12)
        XCTAssertEqual(queue.items.map(\.id), [second.id], "Paste must dismiss the copied item, not the first tile")
        queue.dismissPastedMedia(changeCount: 12)
        XCTAssertEqual(queue.items.map(\.id), [second.id], "Repeated paste must not consume unrelated tiles")
        queue.recordPasteboardCopy([], changeCount: 14)
        queue.dismissPastedMedia(changeCount: 14)
        XCTAssertEqual(queue.items.map(\.id), [second.id])
    }

    func testWheelAndTrackpadHideRevealWithoutMomentumReopening() {
        var intent = MediaShelfScrollIntent()
        XCTAssertEqual(intent.consume(.init(deltaY: 1, precise: false), inHitArea: true), .hide)
        XCTAssertEqual(intent.consume(.init(deltaY: -1, precise: false), inHitArea: true), .reveal)
        XCTAssertEqual(intent.consume(.init(deltaY: 15, began: true), inHitArea: true), .none)
        XCTAssertEqual(intent.consume(.init(deltaY: 15), inHitArea: true), .hide)
        XCTAssertEqual(intent.consume(.init(deltaY: -90, momentum: true), inHitArea: true), .none)
        XCTAssertEqual(intent.consume(.init(deltaX: 40, deltaY: -30), inHitArea: true), .none)
        XCTAssertEqual(intent.consume(.init(deltaY: -10), inHitArea: false), .none)
        XCTAssertEqual(intent.consume(.init(deltaY: -20), inHitArea: true), .none)
        XCTAssertEqual(intent.consume(.init(deltaY: -10), inHitArea: true), .reveal)
    }

    func testScrollAccumulationResetsAfterPauseOrDirectionChange() {
        var intent = MediaShelfScrollIntent()
        XCTAssertEqual(intent.consume(.init(deltaY: 20, timestamp: 1), inHitArea: true), .none)
        XCTAssertEqual(intent.consume(.init(deltaY: 10, timestamp: 2), inHitArea: true), .none)
        XCTAssertEqual(intent.consume(.init(deltaY: -20, timestamp: 2.1), inHitArea: true), .none)
        XCTAssertEqual(intent.consume(.init(deltaY: -10, timestamp: 2.2), inHitArea: true), .reveal)
    }

}
