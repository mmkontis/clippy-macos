import Foundation

enum FileContentLoader {
    private static let maxModalBytes = 512_000

    static func loadText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]).prefix(maxModalBytes) else {
            return nil
        }

        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .windowsCP1252)

        guard let text, !text.isEmpty else { return nil }

        if data.count >= maxModalBytes {
            return text + "\n\n…"
        }
        return text
    }
}
