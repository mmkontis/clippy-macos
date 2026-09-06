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
    private var scrollAccum: CGFloat = 0
    private var bottomPushAccum: CGFloat = 0
    private let revealScrollStep: CGFloat = 26
    private let bottomPushThreshold: CGFloat = 48

    private init() {}

    /// Screen frame of the stack panel, used to ignore clicks on tiles.
    public var panelFrame: NSRect? {
        panel?.frame
    }

    public func start() {
        ensurePanel()
        cancellable = RecentMediaQueue.shared.$items
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
            let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            Task { @MainActor in self?.handleStackScroll(deltaY: dy) }
            return event
        }
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            Task { @MainActor in self?.handleStackScroll(deltaY: dy) }
        }
        edgeMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            let dy = event.deltaY
            Task { @MainActor in self?.handlePointerMove(deltaY: dy) }
            return event
        }
        edgeMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            let dy = event.deltaY
            Task { @MainActor in self?.handlePointerMove(deltaY: dy) }
        }
    }

    private func handleStackScroll(deltaY: CGFloat) {
        guard abs(deltaY) > 0.1 else { return }
        guard hasClipboardMedia else { return }

        // Hit area: the live panel when it's on screen, otherwise the bottom-left
        // launch zone — so scrolling there opens the history even while hidden.
        let inHitArea: Bool
        if let panel, panel.isVisible {
            inHitArea = NSPointInRect(NSEvent.mouseLocation, panel.frame)
        } else if let visible = stackScreen()?.visibleFrame {
            inHitArea = NSPointInRect(NSEvent.mouseLocation, stackLaunchZone(visible))
        } else {
            return
        }
        guard inHitArea else { scrollAccum = 0; return }

        // Down reveals more. Up hides the shelf without clearing any clips.
        // Changing direction starts a fresh gesture instead of fighting old deltas.
        if scrollAccum * deltaY > 0 { scrollAccum = 0 }
        scrollAccum += -deltaY
        while scrollAccum >= revealScrollStep {
            scrollAccum -= revealScrollStep
            adjustReveal(by: 1)
        }
        if scrollAccum <= -revealScrollStep {
            scrollAccum = 0
            RecentMediaStackExpansion.shared.hide()
        }
    }

    private func handlePointerMove(deltaY: CGFloat) {
        guard hasClipboardMedia else { return }
        let mouse = NSEvent.mouseLocation
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
        let mediaCount = ClipboardManager.shared.items.lazy.filter(\.isDraggableMedia).count
        guard let visible = stackScreen()?.visibleFrame else { return mediaCount }
        let available = visible.height - 24 - outerPadding * 2
        let fit = Int((available + spacing) / (tileSize + spacing))
        return max(1, min(mediaCount, fit))
    }

    private var hasClipboardMedia: Bool {
        ClipboardManager.shared.items.contains(where: \.isDraggableMedia)
    }

    /// The screen the stack lives on (menu-bar screen), matching `applyLayout`.
    private func stackScreen() -> NSScreen? {
        NSScreen.main
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

    /// Watches for global ⌘V / ⌃V keystrokes (in any other app) so we can pop
    /// the top tile off the stack — the user has clearly "used" it. Whether
    /// to act is decided by the host via `ClipboardKitConfig.dismissOnPasteEnabled`.
    private func startPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard ClipboardKitConfig.dismissOnPasteEnabled() else { return }
            guard event.charactersIgnoringModifiers?.lowercased() == "v" else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘⇧V is commonly the host's own hotkey — skip it so we don't
            // dismiss anything when the user is opening the host's panel.
            guard !flags.contains(.shift) else { return }
            guard flags.contains(.command) || flags.contains(.control) else { return }

            Task { @MainActor in
                if let top = RecentMediaQueue.shared.items.first {
                    RecentMediaQueue.shared.dismiss(top)
                }
            }
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
            ? ClipboardManager.shared.items.contains(where: \.isDraggableMedia)
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
        let screen = NSScreen.main
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let contentWidth: CGFloat = tileSize + outerPadding * 2

        // One tile per shown image; reveal count when expanded, else the queue.
        let reveal = RecentMediaStackExpansion.shared.revealCount
        let count = reveal > 0 ? reveal : RecentMediaQueue.shared.items.count
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
