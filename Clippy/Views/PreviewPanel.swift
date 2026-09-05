import SwiftUI
import AppKit
import ClipboardKit

/// A floating preview panel that shows full content of a clipboard item
struct PreviewPanel: View {
    let item: ClipboardItem
    let thumbnail: NSImage?

    init(item: ClipboardItem, thumbnail: NSImage? = nil) {
        self.item = item
        self.thumbnail = thumbnail
    }

    var body: some View {
        contentView
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(0.95)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private var contentView: some View {
        switch item.contentType {
        case .text, .richText:
            ScrollView {
                Text(item.textContent ?? "No content")
                    .font(.system(size: 12.5))
                    .foregroundColor(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(2.5)
            }

        case .image:
            VStack(spacing: 6) {
                if let img = thumbnail ?? item.image {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if let full = item.image {
                        Text("\(Int(full.size.width)) × \(Int(full.size.height)) px")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                } else {
                    Text("Image not available")
                        .foregroundColor(.secondary)
                        .frame(minHeight: 80)
                }
            }

        case .fileURL:
            if let url = item.fileURL {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                    Text(url.path)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("File not available")
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Triangle shape for the bubble arrow
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// NSVisualEffectView wrapper for transparent blur background
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Preview Window Controller

/// Owns a single, reusable preview NSWindow. We never recreate the window per
/// hover — we just swap the SwiftUI root view and resize. This avoids the
/// hosting-controller / window churn that made the previous preview laggy.
@MainActor
final class PreviewWindowController {
    static let shared = PreviewWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<PreviewPanel>?
    private var currentItemId: UUID?
    private var hideWorkItem: DispatchWorkItem?

    // Compact caps — the old preview ballooned to ~720pt wide which felt huge
    // next to a 420pt clipboard panel.
    private let textMaxWidth: CGFloat = 340
    private let textMaxHeight: CGFloat = 280
    private let imageMaxWidth: CGFloat = 340
    private let imageMaxHeight: CGFloat = 300
    private let fileWidth: CGFloat = 280
    private let fileHeight: CGFloat = 88

    /// Check if an item needs a preview (i.e., content is truncated in main panel)
    func needsPreview(for item: ClipboardItem) -> Bool {
        switch item.contentType {
        case .text, .richText:
            let text = item.textContent ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 40 || trimmed.contains("\n")
        case .image, .fileURL:
            return true
        }
    }

    func showPreview(for item: ClipboardItem, near rect: NSRect) {
        guard needsPreview(for: item) else { return }

        hideWorkItem?.cancel()
        hideWorkItem = nil

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen = screen else { return }
        let screenFrame = screen.visibleFrame
        let gap: CGFloat = 8

        // Compute target window size + (for images) a downsampled thumbnail
        let (finalWidth, finalHeight, thumb) = computeSize(for: item)

        let preview = PreviewPanel(item: item, thumbnail: thumb)

        if window == nil {
            let host = NSHostingController(rootView: preview)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.contentViewController = host
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .popUpMenu
            win.hasShadow = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.isReleasedWhenClosed = false
            window = win
            hosting = host
        } else {
            hosting?.rootView = preview
        }

        guard let win = window else { return }

        // Position next to the row's frame, clamped to the screen
        let spaceOnRight = screenFrame.maxX - rect.origin.x - gap
        var x: CGFloat = spaceOnRight >= finalWidth
            ? rect.origin.x + gap
            : rect.origin.x - finalWidth - gap
        var y: CGFloat = mouseLocation.y - finalHeight / 2

        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - finalWidth - 4))
        y = max(screenFrame.minY + 4, min(y, screenFrame.maxY - finalHeight - 4))

        let targetFrame = NSRect(x: x, y: y, width: finalWidth, height: finalHeight)
        let shouldAnimate = win.isVisible && currentItemId != nil
        win.setFrame(targetFrame, display: true, animate: shouldAnimate)

        if !win.isVisible {
            win.alphaValue = 0
            win.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
            }
        }
        currentItemId = item.id
    }

    /// Small grace period before hiding so quick mouse moves between rows
    /// don't make the preview flicker.
    func hidePreview() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let win = self.window, win.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                win.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    win.orderOut(nil)
                    self.currentItemId = nil
                }
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func computeSize(for item: ClipboardItem) -> (CGFloat, CGFloat, NSImage?) {
        switch item.contentType {
        case .image:
            guard let img = item.image else { return (180, 100, nil) }
            let aspect = img.size.width / max(1, img.size.height)
            let contentMaxW = imageMaxWidth - 24
            let contentMaxH = imageMaxHeight - 24 - 22 // padding + caption
            let (w, h): (CGFloat, CGFloat)
            if aspect >= 1 {
                let cw = min(contentMaxW, max(180, img.size.width))
                w = cw
                h = min(contentMaxH, cw / aspect)
            } else {
                let ch = min(contentMaxH, max(180, img.size.height))
                h = ch
                w = min(contentMaxW, ch * aspect)
            }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let maxPx = Int(max(w, h) * scale)
            let thumb = item.thumbnail(maxPixelSize: maxPx)
            return (w + 24, h + 24 + 22, thumb)

        case .text, .richText:
            let text = item.textContent ?? ""
            let lines = max(1, text.components(separatedBy: .newlines).count)
            let longest = text.components(separatedBy: .newlines).map(\.count).max() ?? 0
            let w = min(textMaxWidth, max(200, CGFloat(longest) * 6.6 + 24))
            let h = min(textMaxHeight, max(60, CGFloat(lines) * 18 + 24))
            return (w, h, nil)

        case .fileURL:
            return (fileWidth, fileHeight, nil)
        }
    }
}

#Preview {
    PreviewPanel(item: ClipboardItem.fromText("This is a sample text that would be shown in the preview panel. It can contain multiple lines and will be scrollable if the content is too long to fit in the available space.\n\nHere's another paragraph to demonstrate the scrolling behavior."))
}
