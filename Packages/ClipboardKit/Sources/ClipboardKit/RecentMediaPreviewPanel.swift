import SwiftUI
import AppKit

struct RecentMediaPreviewPanel: View {
    let item: ClipboardItem
    let thumbnail: NSImage?

    @State private var fileText: String?
    @State private var fullPreview: NSImage?

    private let codeMaxWidth: CGFloat = 440
    private let codeMaxHeight: CGFloat = 380
    private let imageMaxSize: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider().opacity(0.25)

            content
                .padding(12)
        }
        .frame(
            width: panelWidth,
            height: panelHeight,
            alignment: .topLeading
        )
        .background(RecentMediaVisualEffect(material: .hudWindow, blendingMode: .behindWindow).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 8)
        .task(id: item.id) {
            await loadContent()
        }
    }

    private var panelWidth: CGFloat {
        switch item.contentType {
        case .image:
            return imageMaxSize + 24
        case .fileURL:
            if item.isImageFile { return imageMaxSize + 24 }
            if fileText != nil { return codeMaxWidth }
            return 320
        default:
            return 320
        }
    }

    private var panelHeight: CGFloat {
        switch item.contentType {
        case .image:
            return imageMaxSize + 70
        case .fileURL:
            if item.isImageFile { return imageMaxSize + 70 }
            if fileText != nil { return codeMaxHeight + 54 }
            return 120
        default:
            return 120
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text(titleText)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                RecentMediaPreviewController.shared.hidePreview()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
    }

    private var titleText: String {
        switch item.contentType {
        case .image:
            return "Image"
        case .fileURL:
            return item.fileURL?.lastPathComponent ?? "File"
        default:
            return "Preview"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.contentType {
        case .image:
            if let img = fullPreview ?? thumbnail ?? item.image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: imageMaxSize, maxHeight: imageMaxSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder("Image not available")
            }

        case .fileURL:
            if item.isImageFile, let img = fullPreview ?? thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: imageMaxSize, maxHeight: imageMaxSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let fileText {
                ScrollView {
                    Text(fileText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let img = fullPreview ?? thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: imageMaxSize, maxHeight: imageMaxSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = item.fileURL {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(url.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                placeholder("File not available")
            }

        default:
            placeholder("Nothing to preview")
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadContent() async {
        fileText = nil
        fullPreview = nil

        switch item.contentType {
        case .image:
            fullPreview = item.image
        case .fileURL:
            guard let url = item.fileURL else { return }
            if item.isImageFile {
                fullPreview = await item.loadMediaPreview(pixelSize: Int(imageMaxSize * 2))
            } else if let text = FileContentLoader.loadText(from: url) {
                fileText = text
            } else {
                fullPreview = await item.loadMediaPreview(pixelSize: Int(imageMaxSize * 2))
            }
        default:
            break
        }
    }
}

private struct RecentMediaVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
