import Foundation

/// Resolves file paths copied as plain text from Cursor, VS Code, and similar
/// editors where "Copy" writes a relative path instead of a native file URL.
enum EditorWorkspaceResolver {
    private static let editorStorageFolders = ["Cursor", "Code"]
    private static let editorAppNames = ["Cursor", "Visual Studio Code", "Code"]

    /// Cached workspace roots from Cursor/Code storage (~5 min TTL).
    private static var cachedRoots: [URL] = []
    private static var cacheTimestamp: Date = .distantPast
    private static let cacheTTL: TimeInterval = 300

    static func workspaceRoots() -> [URL] {
        if Date().timeIntervalSince(cacheTimestamp) < cacheTTL, !cachedRoots.isEmpty {
            return cachedRoots
        }

        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }

        var roots: [URL] = []
        for editor in editorStorageFolders {
            let storage = appSupport
                .appendingPathComponent(editor, isDirectory: true)
                .appendingPathComponent("User/workspaceStorage", isDirectory: true)

            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: storage,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries {
                let workspaceFile = entry.appendingPathComponent("workspace.json")
                guard let data = try? Data(contentsOf: workspaceFile),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let folder = json["folder"] as? String,
                   let url = URL(string: folder),
                   url.isFileURL {
                    roots.append(url.standardizedFileURL)
                }

                if let folders = json["folders"] as? [[String: Any]] {
                    for folderEntry in folders {
                        guard let path = folderEntry["path"] as? String,
                              let url = URL(string: path),
                              url.isFileURL else { continue }
                        roots.append(url.standardizedFileURL)
                    }
                }
            }
        }

        cachedRoots = Array(Set(roots))
        cacheTimestamp = Date()
        return cachedRoots
    }

    static func isEditorApp(_ source: String?) -> Bool {
        guard let source else { return false }
        return editorAppNames.contains(where: { source.localizedCaseInsensitiveContains($0) })
    }

    /// Tries to turn clipboard text into an on-disk file URL.
    static func resolveFileURL(from text: String, sourceApp: String?) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096, !trimmed.contains("\n") else { return nil }

        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            return fileExists(url)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return fileExists(URL(fileURLWithPath: expanded))
        }

        guard looksLikeFileReference(trimmed) else { return nil }

        // Relative paths are most common when copying from Cursor/VS Code explorer.
        if isEditorApp(sourceApp) || trimmed.contains("/") {
            for root in workspaceRoots() {
                if let url = fileExists(root.appendingPathComponent(trimmed)) {
                    return url
                }
            }
        }

        // Bare filename (e.g. README.md) — only try editor workspaces.
        if isEditorApp(sourceApp), trimmed.contains("/") == false {
            for root in workspaceRoots() {
                if let match = findNamedFile(named: trimmed, under: root, maxDepth: 8) {
                    return match
                }
            }
        }

        return nil
    }

    private static func looksLikeFileReference(_ text: String) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("file://") {
            return true
        }
        if text.contains("/") {
            return true
        }
        let ext = (text as NSString).pathExtension.lowercased()
        return !ext.isEmpty && ext.count <= 10 && !text.contains(" ")
    }

    private static func fileExists(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func findNamedFile(named: String, under root: URL, maxDepth: Int) -> URL? {
        guard maxDepth >= 0 else { return nil }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for entry in contents {
            if entry.lastPathComponent == named, fileExists(entry) != nil {
                return entry
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               let nested = findNamedFile(named: named, under: entry, maxDepth: maxDepth - 1) {
                return nested
            }
        }

        return nil
    }
}
