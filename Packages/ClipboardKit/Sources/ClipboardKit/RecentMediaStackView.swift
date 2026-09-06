import SwiftUI
import AppKit

/// Drives how many of the newest clipboard images the bottom-left stack
/// reveals. `revealCount == 0` is the collapsed state (the session queue).
/// Scroll / bottom-push gradually grow it one tile at a time; the window
/// controller owns the value and resizes the panel, the view renders it.
@MainActor
public final class RecentMediaStackExpansion: ObservableObject {
    public static let shared = RecentMediaStackExpansion()
    @Published public internal(set) var revealCount: Int = 0
    @Published public private(set) var isHidden = false
    public func hide() {
        isHidden = true
        collapse()
        RecentMediaPreviewController.shared.hidePreview()
    }
    public func showRecent() {
        isHidden = false
        collapse()
    }
    func reveal(_ count: Int) {
        isHidden = false
        revealCount = count
    }
    public var isExpanded: Bool { revealCount > 0 }
    public func collapse() { if revealCount != 0 { revealCount = 0 } }
    private init() {}
}

/// Vertical stack of recently-copied media tiles, anchored to the bottom-left
/// of the screen. The newest tile is on top, older below. Collapsed it shows
/// the session queue; scrolling over it (or pushing the cursor into the bottom
/// edge) grows it one image at a time into the full clipboard-image history.
public struct RecentMediaStackView: View {
    @ObservedObject var queue: RecentMediaQueue
    @ObservedObject private var expansion = RecentMediaStackExpansion.shared
    @ObservedObject private var manager = ClipboardManager.shared

    public init(queue: RecentMediaQueue) {
        self.queue = queue
    }

    private var historyMedia: [ClipboardItem] {
        manager.items.filter(\.isDraggableMedia)
    }

    /// Newest-first, so rendered top-to-bottom = newest on top, oldest at the
    /// bottom (corner). Collapsed shows the session queue; revealed shows the
    /// newest `revealCount` images from history.
    private var displayItems: [ClipboardItem] {
        if expansion.isHidden { return [] }
        if expansion.revealCount > 0 {
            return Array(historyMedia.prefix(expansion.revealCount))
        }
        return queue.items
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(displayItems) { item in
                RecentMediaTile(item: item) { dismiss(item) }
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
            }
        }
        // Equal padding on all sides; sized to clear the tile shadow without
        // cropping it on the bottom edge.
        .padding(14)
        // Hug the bottom-left corner so the tiles stay pinned to it while the
        // panel grows/shrinks — no gap opening up under them during collapse.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: displayItems.map(\.id))
    }

    private func dismiss(_ item: ClipboardItem) {
        if queue.items.contains(where: { $0.id == item.id }) {
            queue.dismiss(item)
        } else {
            ClipboardManager.shared.removeItem(item)
        }
    }
}

/// 80pt tile. Owns its own hover, swipe and drag state. We avoid SwiftUI's
/// `.onDrag` because it swallows the gesture before our left-swipe handler
/// can run — instead we route mouse drags ourselves and start an
/// NSDraggingSession on a non-left direction.
struct RecentMediaTile: View {
    let item: ClipboardItem
    var allowDrag: Bool = true
    let onDismiss: () -> Void

    @ObservedObject private var previewController = RecentMediaPreviewController.shared
    @ObservedObject private var menuController = RecentMediaProjectMenuController.shared
    @ObservedObject private var projectsHub = ClipboardProjectsHub.shared
    @State private var isHovered = false
    @State private var dragOffset: CGFloat = 0
    @State private var loadedPreview: NSImage?
    @State private var gestureMode: GestureMode = .none
    @StateObject private var bridge = DragSourceBridge()

    private enum GestureMode { case none, swiping, draggingOut }

    private let tileSize: CGFloat = 80

    private var isPreviewActive: Bool {
        previewController.activeItemId == item.id
    }

    private var isMenuActive: Bool {
        menuController.activeItemId == item.id
    }

    private var isActive: Bool {
        isPreviewActive || isMenuActive
    }

    private var saveState: ClipboardSaveState {
        projectsHub.saveState(for: item.id)
    }

    private var isSaving: Bool {
        switch saveState {
        case .uploading, .saved: return true
        default: return false
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            tileContent
                .frame(width: tileSize, height: tileSize)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(saveStateOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isActive ? Color.white.opacity(0.95) : Color.white.opacity(0.16),
                            lineWidth: isActive ? 2 : 0.5
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 3)

            if isHovered, !isSaving {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .frame(width: tileSize, height: tileSize)
        .offset(x: dragOffset)
        .opacity(opacityForOffset)
        .background(DragSourceAttach(bridge: bridge))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
        }
        .simultaneousGesture(
            // In the expanded scroll column the threshold is set absurdly high so
            // this gesture never activates and the ScrollView owns vertical drags.
            DragGesture(minimumDistance: allowDrag ? 4 : 100_000, coordinateSpace: .local)
                .onChanged { handleDragChanged($0) }
                .onEnded { handleDragEnded($0) }
        )
        // A clean click (no 4px movement) never trips the DragGesture above, so
        // handle taps explicitly — this is what opens the "Save to project"
        // dropdown.
        .simultaneousGesture(
            TapGesture().onEnded { handleTap() }
        )
        .task(id: item.id) {
            guard loadedPreview == nil, item.isDraggableMedia else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            loadedPreview = await item.loadMediaPreview(pixelSize: Int(tileSize * 2 * scale))
        }
        .onAppear {
            bridge.onDragSucceeded = { onDismiss() }
        }
        .onChange(of: saveState) { _, newValue in
            // Once the upload lands, flash the check then file the tile away.
            if newValue == .saved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    guard projectsHub.saveState(for: item.id) == .saved else { return }
                    projectsHub.clearSaveState(for: item.id)
                    onDismiss()
                }
            }
        }
    }

    // MARK: Save-state overlay (progress ring / check / error)

    @ViewBuilder
    private var saveStateOverlay: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .uploading(let progress):
            ZStack {
                Color.black.opacity(0.45)
                CircularProgress(progress: progress)
                    .frame(width: 30, height: 30)
            }
            .transition(.opacity)
        case .saved:
            ZStack {
                Color.black.opacity(0.45)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white, Color.green)
            }
            .transition(.opacity)
        case .failed:
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.4)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Color.orange)
            }
            .transition(.opacity)
        }
    }

    private var opacityForOffset: Double {
        guard dragOffset < 0 else { return 1 }
        return 1 - min(0.85, Double(abs(dragOffset) / 140))
    }

    private func dismiss() {
        RecentMediaPreviewController.shared.hidePreviewIfItem(item)
        RecentMediaProjectMenuController.shared.hideIfItem(item)
        withAnimation(.easeOut(duration: 0.18)) {
            dragOffset = -240
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onDismiss()
        }
    }

    private func handleDragChanged(_ g: DragGesture.Value) {
        let dx = g.translation.width
        let dy = g.translation.height

        switch gestureMode {
        case .none:
            guard abs(dx) > 4 || abs(dy) > 4 else { return }
            if dx < -2 && abs(dx) > abs(dy) {
                gestureMode = .swiping
                dragOffset = dx
            } else {
                gestureMode = .draggingOut
                startSystemDrag()
            }
        case .swiping:
            dragOffset = min(0, dx)
        case .draggingOut:
            break
        }
    }

    private func handleDragEnded(_ g: DragGesture.Value) {
        let mode = gestureMode
        defer { gestureMode = .none }

        if mode == .draggingOut { return }

        if mode == .swiping {
            if g.translation.width < -50 {
                withAnimation(.easeOut(duration: 0.2)) {
                    dragOffset = -240
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onDismiss()
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    dragOffset = 0
                }
            }
            return
        }

        // Tap handling lives in the dedicated TapGesture; drag end only cares
        // about swipe/drag-out, both handled above.
    }

    /// Click always opens the "Save to project" dropdown. The dropdown itself
    /// handles the signed-out / no-projects cases gracefully.
    private func handleTap() {
        guard !isSaving else { return }
        RecentMediaPreviewController.shared.hidePreviewIfItem(item)
        RecentMediaProjectMenuController.shared.toggleMenu(for: item, thumbnail: loadedPreview)
    }

    private func startSystemDrag() {
        guard item.makeDragPasteboardWriter() != nil else {
            gestureMode = .none
            return
        }
        MediaDragSupport.startDrag(
            for: item,
            bridge: bridge,
            tileSize: tileSize,
            preloadedImage: loadedPreview
        )
    }

    @ViewBuilder
    private var tileContent: some View {
        ZStack {
            switch item.contentType {
            case .image:
                if let img = loadedPreview {
                    previewImage(img)
                } else {
                    Color.black.opacity(0.72)
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.5))
                }
            case .fileURL:
                if let img = loadedPreview {
                    previewImage(img)
                        .overlay(alignment: .bottom) {
                            if let url = item.fileURL, !item.isImageFile {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: tileSize - 8)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.black.opacity(0.0), Color.black.opacity(0.72)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            }
                        }
                } else {
                    Color.black.opacity(0.72)
                    Image(systemName: "doc")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.5))
                }
            default:
                Color.black.opacity(0.72)
            }
        }
    }

    private func previewImage(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fill)
            .frame(width: tileSize, height: tileSize)
            .clipped()
    }
}

/// Small determinate upload ring. Falls back to an indeterminate spin look at
/// 0 progress so the user gets immediate feedback before the first bytes flush.
private struct CircularProgress: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.04, min(1, progress)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
    }
}
