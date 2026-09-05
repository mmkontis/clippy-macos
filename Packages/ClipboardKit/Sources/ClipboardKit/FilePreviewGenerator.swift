import AppKit
import CoreText
import ImageIO
import QuickLookThumbnailing

enum FilePreviewGenerator {
    private static let textExtensions: Set<String> = [
        "ts", "tsx", "js", "jsx", "mjs", "cjs", "swift", "py", "rb", "go", "rs",
        "java", "kt", "kts", "cs", "cpp", "c", "h", "hpp", "m", "mm",
        "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "sass", "less",
        "md", "markdown", "txt", "sql", "sh", "bash", "zsh", "graphql", "vue", "svelte",
        "php", "pl", "r", "dart", "lua", "ex", "exs", "tf", "env", "ini", "cfg", "conf",
    ]

    private static let maxPreviewBytes = 256_000

    static func preview(for url: URL, pixelSize: Int) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        let ext = url.pathExtension.lowercased()

        if ClipboardItem.imageFileExtensions.contains(ext) {
            return imageThumbnail(url: url, maxPixelSize: pixelSize)
        }

        if textExtensions.contains(ext) || isLikelyTextFile(url) {
            if let rendered = textPreview(url: url, pixelSize: pixelSize) {
                return rendered
            }
        }

        if let quickLook = await quickLookPreview(url: url, pixelSize: pixelSize) {
            return cropToSquare(quickLook, pixelSize: pixelSize)
        }

        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func isLikelyTextFile(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size <= maxPreviewBytes else {
            return false
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]).prefix(512) else {
            return false
        }

        guard !data.isEmpty else { return false }
        return data.allSatisfy { byte in
            byte == 9 || byte == 10 || byte == 13 || (32...126).contains(byte)
        }
    }

    /// Renders the top of a text file into a square bitmap with no margins.
    private static func textPreview(url: URL, pixelSize: Int) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]).prefix(maxPreviewBytes) else {
            return nil
        }

        guard let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .windowsCP1252) else {
            return nil
        }

        let side = CGFloat(pixelSize)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()

        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return nil }

        context.setFillColor(NSColor(red: 0.965, green: 0.969, blue: 0.976, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        context.saveGState()
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)

        let fontSize = max(5, side / 12.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0.5
        paragraph.lineBreakMode = .byClipping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.21, alpha: 1),
            .paragraphStyle: paragraph,
        ]

        let snippet = content
            .components(separatedBy: .newlines)
            .prefix(32)
            .joined(separator: "\n")

        let attributed = NSAttributedString(string: snippet, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: side, height: side), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()

        return image
    }

    private static func quickLookPreview(url: URL, pixelSize: Int) async -> NSImage? {
        let side = CGFloat(pixelSize)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }

    /// Zoom/crop Quick Look thumbnails so they fill a 1:1 tile without letterboxing.
    private static func cropToSquare(_ image: NSImage, pixelSize: Int) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return image }

        let side = min(width, height)
        let originX = (width - side) / 2
        let originY = (height - side) / 2
        let cropRect = CGRect(x: originX, y: originY, width: side, height: side)

        guard let cropped = cgImage.cropping(to: cropRect) else { return image }

        let outputSide = CGFloat(pixelSize)
        let output = NSImage(size: NSSize(width: outputSide, height: outputSide))
        output.lockFocus()
        defer { output.unlockFocus() }

        NSGraphicsContext.current?.cgContext.interpolationQuality = .medium
        NSGraphicsContext.current?.cgContext.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide)
        )

        return output
    }

    private static func imageThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
