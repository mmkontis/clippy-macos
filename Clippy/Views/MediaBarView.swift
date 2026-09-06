import SwiftUI
import AppKit
import ClipboardKit

/// Floating media bar - fully interactive, smooth animations
struct MediaBarView: View {
    @ObservedObject var clipboardManager: ClipboardManager
    var onPasteItem: ((ClipboardItem) -> Void)?
    let screenWidth: CGFloat
    
    @State private var hoveredIndex: Int? = nil
    
    var mediaItems: [ClipboardItem] {
        clipboardManager.items.filter(\.isDraggableMedia)
            .prefix(25)
            .map { $0 }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, item in
                            DockItem(
                                item: item,
                                index: index,
                                hoveredIndex: hoveredIndex,
                                onPaste: { pasteItem(item) }
                            )
                            .frame(width: 90, height: 100, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onHover { isHovered in
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    if isHovered { hoveredIndex = index }
                                    else if hoveredIndex == index { hoveredIndex = nil }
                                }
                            }
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 100, alignment: .bottom)
                }
                .background(
                    ClippySurfaceBackground()
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 6)
                .onKeyPress(.leftArrow) {
                    navigate(offset: -1, scrollProxy: scrollProxy)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    navigate(offset: 1, scrollProxy: scrollProxy)
                    return .handled
                }
                .onKeyPress(.return) {
                    if let index = hoveredIndex, index < mediaItems.count {
                        pasteItem(mediaItems[index])
                    }
                    return .handled
                }
            }
            .frame(maxWidth: screenWidth - 40)
            .padding(.bottom, 8)
        }
        .frame(height: 140, alignment: .bottom)
        .onChange(of: mediaItems.map(\.id)) { _, _ in hoveredIndex = nil }
    }
    
    private func navigate(offset: Int, scrollProxy: ScrollViewProxy) {
        let count = mediaItems.count
        guard count > 0 else { return }
        
        let newIndex: Int
        if let current = hoveredIndex {
            newIndex = (current + offset + count) % count
        } else {
            newIndex = offset > 0 ? 0 : count - 1
        }
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            hoveredIndex = newIndex
            scrollProxy.scrollTo(newIndex, anchor: .center)
        }
    }
    
    private func pasteItem(_ item: ClipboardItem) {
        ClipboardMonitor.shared.pauseMonitoring()
        ClipboardManager.shared.pasteItem(item)
        
        if let callback = onPasteItem {
            callback(item)
        } else if let appDelegate = AppDelegate.shared {
            appDelegate.pasteAndHide()
        }
    }
}

// MARK: - Dock Item Component

struct DockItem: View {
    let item: ClipboardItem
    let index: Int
    let hoveredIndex: Int?
    let onPaste: () -> Void
    
    @State private var loadedPreview: NSImage?
    @State private var gestureMode: GestureMode = .none
    @StateObject private var bridge = DragSourceBridge()
    
    private enum GestureMode { case none, draggingOut }
    
    private let baseSize: CGFloat = 50
    private let magnifiedSize: CGFloat = 85
    
    private var isHovered: Bool {
        hoveredIndex == index
    }
    
    private var isNeighbor: Bool {
        guard let hovered = hoveredIndex else { return false }
        return abs(hovered - index) == 1
    }
    
    private var currentSize: CGFloat {
        if isHovered { return magnifiedSize }
        if isNeighbor { return (baseSize + magnifiedSize) / 2 }
        return baseSize
    }
    
    var body: some View {
        contentView
            .frame(width: currentSize, height: currentSize)
            .background(DragSourceAttach(bridge: bridge))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentSize)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { handleDragChanged($0) }
                    .onEnded { handleDragEnded($0) }
            )
            .task(id: item.id) {
                guard loadedPreview == nil, item.isDraggableMedia else { return }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                loadedPreview = await item.loadMediaPreview(pixelSize: Int(currentSize * 2 * scale))
            }
    }
    
    @ViewBuilder
    private var contentView: some View {
        ZStack {
            if let preview = loadedPreview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else if item.contentType == .image {
                Color.secondary.opacity(0.1)
            } else if item.contentType == .fileURL {
                ZStack {
                    Color.primary.opacity(0.06)
                    Image(systemName: fileIcon(for: item.fileURL))
                        .font(.system(size: currentSize * 0.4, weight: .medium))
                        .foregroundColor(.orange)
                }
            }
        }
        .frame(width: currentSize, height: currentSize)
        .clipShape(RoundedRectangle(cornerRadius: currentSize * 0.2))
        .overlay(
            RoundedRectangle(cornerRadius: currentSize * 0.2)
                .strokeBorder(isHovered ? Color.accentColor : Color.white.opacity(0.15), lineWidth: isHovered ? 2 : 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.3 : 0.15), radius: isHovered ? 8 : 4, y: 3)
    }
    
    private func handleDragChanged(_ gesture: DragGesture.Value) {
        guard gestureMode == .none else { return }
        guard abs(gesture.translation.width) > 4 || abs(gesture.translation.height) > 4 else { return }
        guard item.makeDragPasteboardWriter() != nil else { return }
        gestureMode = .draggingOut
        MediaDragSupport.startDrag(
            for: item,
            bridge: bridge,
            tileSize: currentSize,
            preloadedImage: loadedPreview
        )
    }
    
    private func handleDragEnded(_ gesture: DragGesture.Value) {
        defer { gestureMode = .none }
        guard gestureMode == .none else { return }
        guard abs(gesture.translation.width) < 4, abs(gesture.translation.height) < 4 else { return }
        onPaste()
    }
    
    private func fileIcon(for url: URL?) -> String {
        guard let url else { return "folder.fill" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "zip", "tar", "gz", "rar": return "archivebox.fill"
        case "app": return "app.gift.fill"
        case "dmg": return "externaldrive.fill"
        default: return "folder.fill"
        }
    }
}
