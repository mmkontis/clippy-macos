import Foundation
import AppKit
import ImageIO

/// Represents the type of content stored in a clipboard item
public enum ClipboardContentType: String, Codable {
    case text
    case richText
    case image
    case fileURL
}

/// A single clipboard history entry
public struct ClipboardItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public let contentType: ClipboardContentType
    public let timestamp: Date

    public var textContent: String?

    /// In-memory image data, NOT persisted to JSON. Stored as a separate file on disk.
    public var imageData: Data?

    /// Filename of the image stored in the images directory (e.g. "<uuid>.png")
    public var imageFileName: String?

    public var fileURLString: String?
    public var sourceApplication: String?

    /// Root directory under `~/Library/Application Support/<appFolder>/` for
    /// everything the package persists. The host app picks `appFolder` via
    /// `ClipboardKitConfig.storageFolderName`.
    public static var storageDirectoryURL: URL {
        if ClipboardKitConfig.sharedHistoryEnabled { return ClipboardKitConfig.sharedHistoryDirectory }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(ClipboardKitConfig.storageFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var imagesDirectoryURL: URL {
        let dir = storageDirectoryURL.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(
        id: UUID = UUID(),
        contentType: ClipboardContentType,
        timestamp: Date = Date(),
        textContent: String? = nil,
        imageData: Data? = nil,
        imageFileName: String? = nil,
        fileURLString: String? = nil,
        sourceApplication: String? = nil
    ) {
        self.id = id
        self.contentType = contentType
        self.timestamp = timestamp
        self.textContent = textContent
        self.imageData = imageData
        self.imageFileName = imageFileName
        self.fileURLString = fileURLString
        self.sourceApplication = sourceApplication
    }

    // MARK: - Custom Codable (excludes imageData from JSON)

    enum CodingKeys: String, CodingKey {
        case id, contentType, timestamp, textContent, imageData, imageFileName, fileURLString, sourceApplication
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        contentType = try container.decode(ClipboardContentType.self, forKey: .contentType)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        textContent = try container.decodeIfPresent(String.self, forKey: .textContent)
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        fileURLString = try container.decodeIfPresent(String.self, forKey: .fileURLString)
        sourceApplication = try container.decodeIfPresent(String.self, forKey: .sourceApplication)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(textContent, forKey: .textContent)
        try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try container.encodeIfPresent(fileURLString, forKey: .fileURLString)
        try container.encodeIfPresent(sourceApplication, forKey: .sourceApplication)
    }

    /// Loads image data from the separate file on disk
    public func loadImageDataFromDisk() -> Data? {
        guard let fileName = imageFileName else { return nil }
        let url = Self.imagesDirectoryURL.appendingPathComponent(fileName)
        return try? Data(contentsOf: url)
    }

    /// Creates a ClipboardItem from text
    public static func fromText(_ text: String, source: String? = nil) -> ClipboardItem {
        ClipboardItem(
            contentType: .text,
            textContent: text,
            sourceApplication: source
        )
    }

    /// Creates a ClipboardItem from an image
    public static func fromImage(_ image: NSImage, source: String? = nil) -> ClipboardItem? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let itemId = UUID()
        let fileName = "\(itemId.uuidString).png"

        return ClipboardItem(
            id: itemId,
            contentType: .image,
            imageData: pngData,
            imageFileName: fileName,
            sourceApplication: source
        )
    }

    /// Creates a ClipboardItem from a file URL
    public static func fromFileURL(_ url: URL, source: String? = nil) -> ClipboardItem {
        ClipboardItem(
            contentType: .fileURL,
            fileURLString: url.absoluteString,
            sourceApplication: source
        )
    }

    /// Returns a preview string for display in the list
    public var previewText: String {
        switch contentType {
        case .text, .richText:
            let text = textContent ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 100 {
                return String(trimmed.prefix(100)) + "..."
            }
            return trimmed
        case .image:
            return "📷 Image"
        case .fileURL:
            if let urlString = fileURLString,
               let url = URL(string: urlString) {
                return "📁 " + url.lastPathComponent
            }
            return "📁 File"
        }
    }

    public static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "svg", "ico", "raw"
    ]

    /// Whether this item points at a local image file on disk.
    public var isImageFile: Bool {
        guard contentType == .fileURL, let url = fileURL else { return false }
        return Self.imageFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the item can appear in the recent media stack / media bar.
    public var isDraggableMedia: Bool {
        contentType == .image || contentType == .fileURL
    }

    /// Returns the full content as a string (for search purposes)
    public var searchableText: String {
        switch contentType {
        case .text, .richText:
            return textContent ?? ""
        case .image:
            return "image img picture photo screenshot"
        case .fileURL:
            guard let urlString = fileURLString else { return "" }
            let ext = (urlString as NSString).pathExtension.lowercased()
            if Self.imageFileExtensions.contains(ext) {
                return "\(urlString) image img picture photo"
            }
            return urlString
        }
    }

    /// Retrieves the NSImage, loading from disk if needed
    public var image: NSImage? {
        guard contentType == .image else { return nil }
        if let data = imageData {
            return NSImage(data: data)
        }
        if let data = loadImageDataFromDisk() {
            return NSImage(data: data)
        }
        return nil
    }

    /// Retrieves the file URL if this is a file URL item
    public var fileURL: URL? {
        guard contentType == .fileURL, let urlString = fileURLString else { return nil }
        return URL(string: urlString)
    }

    /// Raw PNG data for image items (from memory or disk)
    public func pngData() -> Data? {
        guard contentType == .image else { return nil }
        if let data = imageData { return data }
        return loadImageDataFromDisk()
    }

    /// Returns a downscaled thumbnail rendered via ImageIO. Much cheaper than
    /// rendering full-resolution NSImages every time a preview/thumbnail is shown.
    public func thumbnail(maxPixelSize: Int) -> NSImage? {
        guard contentType == .image, let data = pngData() else { return nil }
        return Self.thumbnailFromImageSource(data: data as CFData, maxPixelSize: maxPixelSize)
    }

    /// Thumbnail for images and image files, otherwise the workspace file icon.
    public func mediaPreview(maxPixelSize: Int) -> NSImage? {
        switch contentType {
        case .image:
            return thumbnail(maxPixelSize: maxPixelSize)
        case .fileURL:
            if isImageFile, let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
                if let image = Self.thumbnailFromImageSource(url: url as CFURL, maxPixelSize: maxPixelSize) {
                    return image
                }
            }
            return workspaceFileIcon()
        default:
            return nil
        }
    }

    /// Loads a cropped 1:1 preview for stack / media-bar tiles.
    public func loadMediaPreview(pixelSize: Int) async -> NSImage? {
        switch contentType {
        case .image:
            return thumbnail(maxPixelSize: pixelSize)
        case .fileURL:
            guard let url = fileURL else { return workspaceFileIcon() }
            return await FilePreviewGenerator.preview(for: url, pixelSize: pixelSize)
        default:
            return nil
        }
    }

    /// Finder-style icon for file items.
    public func workspaceFileIcon() -> NSImage? {
        guard contentType == .fileURL, let url = fileURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Builds the pasteboard payload for dragging this item into another app.
    public func makeDragPasteboardWriter() -> NSPasteboardWriting? {
        switch contentType {
        case .image:
            guard let data = pngData() else { return nil }
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClippyDrags", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let fileName = "clip-\(id.uuidString.prefix(8)).png"
            let fileURL = tmpDir.appendingPathComponent(fileName)
            guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }

            let pbItem = NSPasteboardItem()
            pbItem.setData(data, forType: .png)
            pbItem.setData(data, forType: .tiff)
            pbItem.setString(fileURL.absoluteString, forType: .fileURL)
            return pbItem
        case .fileURL:
            guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(url.absoluteString, forType: .fileURL)
            pbItem.setString(url.lastPathComponent, forType: .string)
            return pbItem
        default:
            return nil
        }
    }

    /// Drag ghost image shown while the user is dragging.
    public func dragVisual(preloadedImage: NSImage?) -> NSImage? {
        switch contentType {
        case .image:
            return preloadedImage ?? image
        case .fileURL:
            return preloadedImage ?? workspaceFileIcon()
        default:
            return nil
        }
    }

    private static func thumbnailFromImageSource(data: CFData, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        return thumbnailFromImageSource(source: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnailFromImageSource(url: CFURL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return thumbnailFromImageSource(source: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnailFromImageSource(source: CGImageSource, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Copies this item's content to the clipboard
    public func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch contentType {
        case .text, .richText:
            if let text = textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            let data = imageData ?? loadImageDataFromDisk()
            if let data = data, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .fileURL:
            if let urlString = fileURLString, let url = URL(string: urlString) {
                pasteboard.writeObjects([url as NSURL])
            }
        }
    }

    /// Formatted timestamp for display
    public var formattedTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    public static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        switch (lhs.contentType, rhs.contentType) {
        case (.text, .text), (.richText, .richText):
            return lhs.textContent == rhs.textContent
        case (.image, .image):
            let lhsData = lhs.imageData ?? lhs.loadImageDataFromDisk()
            let rhsData = rhs.imageData ?? rhs.loadImageDataFromDisk()
            return lhsData == rhsData
        case (.fileURL, .fileURL):
            return lhs.fileURLString == rhs.fileURLString
        default:
            return false
        }
    }
}
