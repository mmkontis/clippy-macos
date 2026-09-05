import Foundation

public struct ClipboardShortcutSuggestion: Identifiable, Equatable {
    public let id: String
    public let triggerPhrase: String
    public let replacementText: String
    public let copyCount: Int
    public let pasteCount: Int
    public let lastUsedAt: Date

    public init(
        id: String,
        triggerPhrase: String,
        replacementText: String,
        copyCount: Int,
        pasteCount: Int,
        lastUsedAt: Date
    ) {
        self.id = id
        self.triggerPhrase = triggerPhrase
        self.replacementText = replacementText
        self.copyCount = copyCount
        self.pasteCount = pasteCount
        self.lastUsedAt = lastUsedAt
    }

    public var totalUsageCount: Int {
        copyCount + pasteCount
    }

    public func withTriggerPhrase(_ triggerPhrase: String) -> ClipboardShortcutSuggestion {
        ClipboardShortcutSuggestion(
            id: id,
            triggerPhrase: triggerPhrase,
            replacementText: replacementText,
            copyCount: copyCount,
            pasteCount: pasteCount,
            lastUsedAt: lastUsedAt
        )
    }
}

private struct ClipboardUsageRecord: Codable {
    var text: String
    var copyCount: Int
    var pasteCount: Int
    var lastUsedAt: Date
}

@MainActor
public final class ClipboardUsageTracker {
    public static let shared = ClipboardUsageTracker()

    private let maxRecords = 800
    private let minSuggestionUsage = 2
    private let maxTrackedTextLength = 500
    private let maxReplacementLength = 240

    private var recordsByKey: [String: ClipboardUsageRecord] = [:]
    private var saveWorkItem: DispatchWorkItem?

    private var usageFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(ClipboardKitConfig.storageFolderName)
            .appendingPathComponent("clipboard-usage.json")
    }

    private init() {
        load()
    }

    /// Suggestions must not preserve text that has been deleted from shared history.
    public func retainHistory(_ items: [ClipboardItem]) {
        let keys = Set(items.compactMap { $0.textContent }.map(Self.normalizedKey))
        let retained = recordsByKey.filter { keys.contains($0.key) }
        guard retained.count != recordsByKey.count else { return }
        recordsByKey = retained
        save()
    }

    public func remove(_ item: ClipboardItem) {
        guard let text = item.textContent else { return }
        recordsByKey.removeValue(forKey: Self.normalizedKey(text))
        save()
    }

    public func clear() {
        recordsByKey.removeAll()
        save()
    }

    public func recordCopy(of item: ClipboardItem) {
        record(item, mutation: { $0.copyCount += 1 })
    }

    public func recordPaste(of item: ClipboardItem) {
        record(item, mutation: { $0.pasteCount += 1 })
    }

    public func suggestions(excludingExisting existingEntries: [(trigger: String, replacement: String?)], limit: Int = 8) -> [ClipboardShortcutSuggestion] {
        let existingTriggers = Set(existingEntries.map { Self.normalizedKey($0.trigger) })
        let existingReplacements = Set(existingEntries.compactMap { entry in
            entry.replacement.map { Self.normalizedKey($0) }
        })

        var usedTriggers = existingTriggers
        return recordsByKey.values
            .filter { record in
                record.copyCount + record.pasteCount >= minSuggestionUsage &&
                !existingReplacements.contains(Self.normalizedKey(record.text)) &&
                !Self.looksSensitive(record.text)
            }
            .sorted {
                let lhsTotal = $0.copyCount + $0.pasteCount
                let rhsTotal = $1.copyCount + $1.pasteCount
                if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
                return $0.lastUsedAt > $1.lastUsedAt
            }
            .compactMap { record in
                guard let trigger = Self.makeTriggerPhrase(for: record.text, avoiding: usedTriggers) else {
                    return nil
                }
                usedTriggers.insert(Self.normalizedKey(trigger))
                return ClipboardShortcutSuggestion(
                    id: Self.normalizedKey(record.text),
                    triggerPhrase: trigger,
                    replacementText: record.text,
                    copyCount: record.copyCount,
                    pasteCount: record.pasteCount,
                    lastUsedAt: record.lastUsedAt
                )
            }
            .prefix(limit)
            .map { $0 }
    }

    private func record(_ item: ClipboardItem, mutation: (inout ClipboardUsageRecord) -> Void) {
        guard item.contentType == .text || item.contentType == .richText,
              let text = item.textContent,
              let normalizedText = Self.normalizedSuggestionText(text, maxLength: maxReplacementLength) else {
            return
        }

        let key = Self.normalizedKey(normalizedText)
        var record = recordsByKey[key] ?? ClipboardUsageRecord(
            text: normalizedText,
            copyCount: 0,
            pasteCount: 0,
            lastUsedAt: Date()
        )
        mutation(&record)
        record.lastUsedAt = Date()
        recordsByKey[key] = record
        pruneIfNeeded()
        scheduleSave()
    }

    private func pruneIfNeeded() {
        guard recordsByKey.count > maxRecords else { return }
        let keepKeys = Set(recordsByKey
            .sorted {
                let lhsTotal = $0.value.copyCount + $0.value.pasteCount
                let rhsTotal = $1.value.copyCount + $1.value.pasteCount
                if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
                return $0.value.lastUsedAt > $1.value.lastUsedAt
            }
            .prefix(maxRecords)
            .map(\.key))
        recordsByKey = recordsByKey.filter { keepKeys.contains($0.key) }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.save()
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: usageFileURL.path),
              let data = try? Data(contentsOf: usageFileURL) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([String: ClipboardUsageRecord].self, from: data)
            recordsByKey = records.filter { _, record in
                Self.normalizedSuggestionText(record.text, maxLength: maxTrackedTextLength) != nil
            }
            pruneIfNeeded()
        } catch {
            recordsByKey = [:]
        }
    }

    private func save() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(recordsByKey)
            try FileManager.default.createDirectory(at: usageFileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: usageFileURL, options: .atomic)
        } catch {
            print("Failed to save clipboard usage: \(error)")
        }
    }

    private static func normalizedSuggestionText(_ text: String, maxLength: Int) -> String? {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count >= 8,
              normalized.count <= maxLength,
              !looksSensitive(normalized) else {
            return nil
        }

        return normalized
    }

    private static func normalizedKey(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private static func makeTriggerPhrase(for text: String, avoiding existing: Set<String>) -> String? {
        if let urlTrigger = makeURLTriggerPhrase(for: text, avoiding: existing) {
            return urlTrigger
        }

        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                word.count >= 2 && !Self.stopWords.contains(word) && !Self.urlNoiseWords.contains(word)
            }

        let seedWords = Array(words.prefix(4))
        guard !seedWords.isEmpty else { return nil }

        let initials = seedWords.compactMap(\.first).map(String.init).joined()
        let firstWord = seedWords[0]
        var candidates: [String] = []

        if seedWords.count >= 2 {
            candidates.append("\(seedWords[0]) \(seedWords[1])")
        }
        candidates.append(firstWord)

        if seedWords.count >= 2 {
            candidates.append("\(String(seedWords[0].prefix(8))) \(String(seedWords[1].prefix(8)))")
        }

        return firstAvailableTrigger(from: candidates, avoiding: existing, maxLength: 28)
    }

    private static func makeURLTriggerPhrase(for text: String, avoiding existing: Set<String>) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parseableText: String
        if trimmed.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) != nil {
            parseableText = trimmed
        } else if trimmed.contains(".") {
            parseableText = "https://\(trimmed)"
        } else {
            return nil
        }

        guard let url = URL(string: parseableText),
              let host = url.host(percentEncoded: false)?.lowercased() else {
            return nil
        }

        let hostParts = host
            .components(separatedBy: ".")
            .filter { !$0.isEmpty && !Self.urlNoiseWords.contains($0) }
        guard let brand = hostParts.first else { return nil }

        let pathWords = url.path
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !Self.stopWords.contains($0) && !Self.urlNoiseWords.contains($0) }

        var candidates: [String] = []
        if let firstPathWord = pathWords.first {
            candidates.append("\(firstPathWord) \(brand)")
            candidates.append("\(brand) \(firstPathWord)")
        }

        candidates.append("\(brand) url")
        candidates.append(brand)

        if brand.count > 4 {
            candidates.append(String(brand.prefix(8)))
        }

        return firstAvailableTrigger(from: candidates, avoiding: existing, maxLength: 32)
    }

    private static func firstAvailableTrigger(from candidates: [String], avoiding existing: Set<String>, maxLength: Int) -> String? {
        for candidate in candidates {
            let cleaned = candidate
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .prefix(maxLength)
            let trigger = displayPhrase(String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines))
            if trigger.count >= 3, !existing.contains(normalizedKey(trigger)) {
                return trigger
            }
        }

        guard let first = candidates.first else { return nil }
        let base = String(first
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(maxLength - 2)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        guard !base.isEmpty else { return nil }

        for suffix in 2...9 {
            let cleaned = displayPhrase("\(base) \(suffix)")
            if !existing.contains(normalizedKey(cleaned)) {
                return cleaned
            }
        }

        return nil
    }

    private static func displayPhrase(_ phrase: String) -> String {
        phrase
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { word in
                let lowercased = word.lowercased()
                if lowercased == "url" { return "URL" }
                if lowercased == "ai" { return "AI" }
                if lowercased == "linkedin" { return "LinkedIn" }
                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func looksSensitive(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let sensitiveTerms = ["password", "passcode", "secret", "token", "api key", "apikey", "bearer "]
        if sensitiveTerms.contains(where: { lowercased.contains($0) }) {
            return true
        }

        let digits = text.filter(\.isNumber).count
        if digits >= 12 {
            return true
        }

        return text.contains("-----BEGIN") || lowercased.contains("private key")
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "your", "you", "are",
        "was", "were", "will", "have", "has", "had", "not", "but", "our", "their",
        "his", "her", "she", "him", "they", "them", "there", "here", "into", "onto",
        "about", "because", "than", "then", "when", "where", "what", "which", "who"
    ]

    private static let urlNoiseWords: Set<String> = [
        "http", "https", "www", "com", "net", "org", "io", "ai", "app", "dev",
        "co", "us", "uk", "in", "me", "to", "ly", "is", "id", "utm", "ref"
    ]
}
