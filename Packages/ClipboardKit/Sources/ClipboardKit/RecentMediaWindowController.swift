import SwiftUI
import AppKit
import Combine

/// Hosts the floating bottom-left stack of recently-copied media tiles.
/// Window lifecycle: lazily created, shown when there are items in the queue,
/// hidden (not destroyed) when the queue is empty.
@MainActor
public final class RecentMediaWindowController {
    public static let shared = RecentMediaWindowController()

    private var panel: NSPanel?
    private var hosting: NSHostingController<RecentMediaStackView>?
    private var cancellable: AnyCancellable?
    private var expansionCancellable: AnyCancellable?
    private var historyCancellable: AnyCancellable?
    private var pasteMonitor: Any?
    private var localPasteMonitor: Any?
    private var scrollMonitorLocal: Any?
    private var scrollMonitorGlobal: Any?
    private var edgeMonitorLocal: Any?
    private var edgeMonitorGlobal: Any?

    private let tileSize: CGFloat = 80
    private let spacing: CGFloat = 10
    // Must mirror RecentMediaStackView's .padding() — also what creates the
    // tile-to-screen-edge gap.
    private let outerPadding: CGFloat = 14

    // Reveal accumulators: scroll grows the stack one image per `revealScrollStep`
    // points; the bottom edge only opens after a sustained downward push.
    private var scrollIntent = MediaShelfScrollIntent()
    private var bottomPushAccum: CGFloat = 0
    private let bottomPushThreshold: CGFloat = 48

    private init() {}

    /// Screen frame of the stack panel, used to ignore clicks on tiles.
    public var panelFrame: NSRect? {
        panel?.isVisible == true ? panel?.frame : nil
    }

    public func start() {
        guard cancellable == nil else { return }
        ensurePanel()
        cancellable = RecentMediaQueue.shared.$items
            .combineLatest(RecentMediaQueue.shared.$dismissedIDs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(animated: true) }
            }
        expansionCancellable = RecentMediaStackExpansion.shared.$revealCount
            .combineLatest(RecentMediaStackExpansion.shared.$isHidden)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(animated: true) }
            }
        historyCancellable = ClipboardManager.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    if RecentMediaStackExpansion.shared.isExpanded {
                        self?.refresh(animated: true)
                    }
                }
            }
        startPasteMonitor()
        startStackInteractionMonitors()
    }

    /// Grows the stack one image at a time as the user scrolls over it, and
    /// opens it on a sustained downward push at the bottom edge; upward scroll
    /// hides the shelf without deleting history. Collapses once
    /// the cursor leaves. We extract the raw deltas synchronously (NSEvent isn't
    /// Sendable) and hop to the main actor with plain values.
    private func startStackInteractionMonitors() {
        guard scrollMonitorLocal == nil else { return }

        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let input = MediaShelfScrollInput(event: event)
            let point = NSEvent.mouseLocation
            self?.handleStackScroll(input, at: point)
            return event
        }
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let input = MediaShelfScrollInput(event: event)
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleStackScroll(input, at: point) }
        }
        edgeMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handlePointerMove(deltaY: event.deltaY, at: NSEvent.mouseLocation)
            return event
        }
        edgeMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            let dy = event.deltaY, point = NSEvent.mouseLocation
            Task { @MainActor in self?.handlePointerMove(deltaY: dy, at: point) }
        }
    }

    private func handleStackScroll(_ input: MediaShelfScrollInput, at point: NSPoint) {
        guard hasClipboardMedia else { return }

        // Hit area: the live panel when it's on screen, otherwise the bottom-left
        // launch zone — so scrolling there opens the history even while hidden.
        let inHitArea: Bool
        if let panel, panel.isVisible {
            inHitArea = NSPointInRect(point, panel.frame)
        } else if let visible = stackScreen()?.visibleFrame {
            inHitArea = NSPointInRect(point, stackLaunchZone(visible))
        } else {
            return
        }
        switch scrollIntent.consume(input, inHitArea: inHitArea) {
        case .hide: RecentMediaStackExpansion.shared.hide()
        case .reveal: adjustReveal(by: 1)
        case .none: break
        }
    }

    private func handlePointerMove(deltaY: CGFloat, at mouse: NSPoint) {
        guard hasClipboardMedia else { return }
        guard let visible = stackScreen()?.visibleFrame else { return }

        let column = stackColumnRect(visible)
        let overColumn = mouse.x >= column.minX - 6 && mouse.x <= column.maxX + 6
        let atBottom = mouse.y <= visible.minY + 1

        // A *deliberate* downward push at the very bottom edge reveals one image
        // at a time — works whether the stack is hidden, collapsed, or already
        // expanded, so you can open it from nothing and keep pushing for more.
        if overColumn && atBottom {
            // Only a downward push counts. Upward and sideways movement must
            // not accidentally reveal a shelf the user just hid.
            guard deltaY > 0 else { bottomPushAccum = 0; return }
            bottomPushAccum += deltaY
            if bottomPushAccum >= bottomPushThreshold {
                bottomPushAccum = 0
                adjustReveal(by: 1)
            }
            return
        }
        bottomPushAccum = 0

        // Collapse once the cursor clearly leaves an expanded panel — but not
        // while a save dropdown opened from a tile is still up (it sits aside).
        if RecentMediaStackExpansion.shared.isExpanded, let panel, panel.isVisible {
            if RecentMediaProjectMenuController.shared.activeItemId != nil { return }
            if let preview = RecentMediaPreviewController.shared.panelFrame,
               NSPointInRect(mouse, preview.insetBy(dx: -12, dy: -12)) { return }
            if !NSPointInRect(mouse, panel.frame.insetBy(dx: -44, dy: -44)) {
                RecentMediaStackExpansion.shared.collapse()
            }
        }
    }

    /// Moves the reveal count by `steps`. Base is the collapsed item count (the
    /// session queue — 0 when the stack is hidden); reveals climb from there up
    /// to what fits on screen, and drop back to 0 (collapsed/hidden).
    private func adjustReveal(by steps: Int) {
        guard hasClipboardMedia else { return }
        let base = RecentMediaQueue.shared.items.count
        let maxReveal = maxRevealCount()
        let current = RecentMediaStackExpansion.shared.revealCount
        var count = current == 0 ? base : current
        count = max(0, min(maxReveal, count + steps))
        let newValue = count > base ? count : 0
        if newValue != current || RecentMediaStackExpansion.shared.isHidden {
            RecentMediaStackExpansion.shared.reveal(newValue)
        }
    }

    /// How many tiles fit in the usable screen height — the cap for revealing.
    private func maxRevealCount() -> Int {
        let mediaCount = RecentMediaQueue.shared.visibleHistory(from: ClipboardManager.shared.items).count
        guard let visible = stackScreen()?.visibleFrame else { return mediaCount }
        let available = visible.height - 24 - outerPadding * 2
        let fit = Int((available + spacing) / (tileSize + spacing))
        return max(1, min(mediaCount, fit))
    }

    private var hasClipboardMedia: Bool {
        !RecentMediaQueue.shared.visibleHistory(from: ClipboardManager.shared.items).isEmpty
    }

    /// The screen the stack lives on (menu-bar screen), matching `applyLayout`.
    private func stackScreen() -> NSScreen? {
        panel?.screen ?? NSScreen.main
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.screens.first
    }

    /// Full-height bottom-left column, for hit-testing the cursor's x position.
    private func stackColumnRect(_ visible: NSRect) -> NSRect {
        NSRect(x: visible.minX, y: visible.minY, width: tileSize + outerPadding * 2, height: visible.height)
    }

    /// Bottom-left corner zone where a scroll opens the hidden stack.
    private func stackLaunchZone(_ visible: NSRect) -> NSRect {
        NSRect(x: visible.minX, y: visible.minY, width: tileSize + outerPadding * 2, height: 220)
    }

    /// Dismiss only the media on the current pasteboard, including copies made
    /// less than one polling interval ago. A text paste never consumes a tile.
    private func startPasteMonitor() {
        guard pasteMonitor == nil else { return }
        let pasted: (NSEvent) -> Void = { event in
            guard ClipboardKitConfig.dismissOnPasteEnabled(), !event.isARepeat,
                  event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v" else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command else { return }
            let change = NSPasteboard.general.changeCount
            Task { @MainActor in
                ClipboardMonitor.shared.capturePendingCopy()
                RecentMediaQueue.shared.dismissPastedMedia(changeCount: change)
            }
        }
        pasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: pasted)
        localPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            pasted(event)
            return event
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let view = RecentMediaStackView(queue: RecentMediaQueue.shared)
        let host = NSHostingController(rootView: view)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: tileSize + outerPadding * 2, height: tileSize + outerPadding * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = true
        p.isFloatingPanel = true
        p.worksWhenModal = true

        panel = p
        hosting = host
    }

    /// Shows/hides + sizes the panel for the current mode. Collapsed shows the
    /// session queue; expanded shows every clipboard image in a scroll column.
    private func refresh(animated: Bool) {
        ensurePanel()
        guard let panel else { return }

        let expanded = RecentMediaStackExpansion.shared.isExpanded
        let hasContent = expanded
            ? hasClipboardMedia
            : !RecentMediaQueue.shared.items.isEmpty

        if !hasContent || RecentMediaStackExpansion.shared.isHidden {
            RecentMediaPreviewController.shared.hidePreview()
            if expanded { RecentMediaStackExpansion.shared.collapse() }
            // Synchronous dismissal avoids an old fade completion hiding fresh
            // tiles that arrive while the previous queue is disappearing.
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        applyLayout(animated: animated && panel.isVisible)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    private func applyLayout(animated: Bool) {
        guard let panel else { return }

        // Pick the screen whose menu bar is on it (the "main" one), falling back
        // to whichever screen currently contains the cursor.
        guard let visible = stackScreen()?.visibleFrame else { return }

        let contentWidth: CGFloat = tileSize + outerPadding * 2

        // One tile per shown image; reveal count when expanded, else the queue.
        let reveal = RecentMediaStackExpansion.shared.revealCount
        let available = RecentMediaQueue.shared.visibleHistory(from: ClipboardManager.shared.items).count
        let count = reveal > 0 ? min(reveal, available) : RecentMediaQueue.shared.items.count
        let height = CGFloat(count) * tileSize
            + CGFloat(max(0, count - 1)) * spacing
            + outerPadding * 2

        // Flush to the bottom-left corner; the inner padding is the screen gap.
        let target = NSRect(x: visible.minX, y: visible.minY, width: contentWidth, height: height)

        guard animated else {
            panel.setFrame(target, display: true)
            return
        }

        // Controlled, distance-proportional ease so a one-tile reveal is snappy
        // and a full collapse glides instead of snapping. This replaces AppKit's
        // default resize timing, which fought the SwiftUI content animation.
        let delta = abs(target.height - panel.frame.height)
        let duration = min(0.32, max(0.10, Double(delta) / 1700))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
    }
}

/// Device-normalized input lets wheel and trackpad behavior share regression tests.
struct MediaShelfScrollInput {
    var deltaX: CGFloat
    var deltaY: CGFloat
    var precise: Bool
    var momentum: Bool
    var began: Bool
    var timestamp: TimeInterval

    init(deltaX: CGFloat = 0, deltaY: CGFloat, precise: Bool = true,
         momentum: Bool = false, began: Bool = false, timestamp: TimeInterval = 0) {
        self.deltaX = deltaX; self.deltaY = deltaY; self.precise = precise
        self.momentum = momentum; self.began = began; self.timestamp = timestamp
    }
    init(event: NSEvent) {
        self.init(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                  precise: event.hasPreciseScrollingDeltas, momentum: !event.momentumPhase.isEmpty,
                  began: event.phase.contains(.began), timestamp: event.timestamp)
    }
}

struct MediaShelfScrollIntent {
    enum Action: Equatable { case none, reveal, hide }
    private var accumulated: CGFloat = 0
    private var lastTimestamp: TimeInterval = 0

    mutating func consume(_ input: MediaShelfScrollInput, inHitArea: Bool) -> Action {
        guard inHitArea else { accumulated = 0; return .none }
        guard !input.momentum else { return .none }
        guard abs(input.deltaY) > max(0.1, abs(input.deltaX)) else { accumulated = 0; return .none }
        if input.began || input.timestamp - lastTimestamp > 0.4 || accumulated * input.deltaY < 0 {
            accumulated = 0
        }
        lastTimestamp = input.timestamp
        // One mouse-wheel notch suffices. Trackpads accumulate deliberate movement.
        accumulated += input.deltaY * (input.precise ? 1 : 26)
        guard abs(accumulated) >= 26 else { return .none }
        let action: Action = accumulated > 0 ? .hide : .reveal
        accumulated = 0
        return action
    }
}
