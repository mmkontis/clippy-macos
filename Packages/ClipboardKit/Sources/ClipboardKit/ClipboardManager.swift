import Foundation
import SwiftUI
import ApplicationServices
import Combine

/// Manages clipboard history storage and persistence
@MainActor
public final class ClipboardManager: ObservableObject {
    public static let shared = ClipboardManager()

    /// Maximum number of items to store in history
    private var maxItems: Int { max(1, ClipboardKitConfig.maximumHistoryItems()) }

    /// The clipboard history
    @Published public private(set) var items: [ClipboardItem] = []

    /// Search query for filtering items
    @Published public var searchQuery: String = ""

    /// Cached filtered items, updated when `items` or `searchQuery` changes
    @Published public private(set) var filteredItems: [ClipboardItem] = []

    private var filterCancellable: AnyCancellable?
    private var saveWorkItem: DispatchWorkItem?

    /// Path to the history file (under the host-configured storage folder).
    private var historyFileURL: URL {
        ClipboardItem.storageDirectoryURL.appendingPathComponent("history.json")
    }

    private init() {
        loadHistory()

        filterCancellable = Publishers.CombineLatest($items, $searchQuery)
            .map { items, query in
                guard !query.isEmpty else { return items }
                let q = query.lowercased()
                return items.filter { $0.searchableText.lowercased().contains(q) }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: \.filteredItems, on: self)

        filteredItems = items
    }

    /// Adds a new item to the history
    public func addItem(_ item: ClipboardItem) {
        ClipboardUsageTracker.shared.recordCopy(of: item)

        // Check for duplicates - remove existing if found
        if let existingIndex = items.firstIndex(where: { $0 == item }) {
            let existing = items[existingIndex]
            deleteImageFile(for: existing)
            items.remove(at: existingIndex)
        }

        var newItem = item

        // Persist image data to a separate file
        if newItem.contentType == .image, let data = newItem.imageData {
            let fileName = newItem.imageFileName ?? "\(newItem.id.uuidString).png"
            newItem.imageFileName = fileName
            let url = ClipboardItem.imagesDirectoryURL.appendingPathComponent(fileName)
            try? data.write(to: url, options: .atomic)
            newItem.imageData = nil
        }

        items.insert(newItem, at: 0)

        // Surface freshly-copied media in the bottom-left "recent" stack
        if newItem.contentType == .image || newItem.contentType == .fileURL {
            RecentMediaQueue.shared.enqueue(newItem)
        }

        // Trim to max items, deleting image files for removed items
        if items.count > maxItems {
            let removed = items[maxItems...]
            for old in removed { deleteImageFile(for: old) }
            items = Array(items.prefix(maxItems))
        }

        scheduleSave()
    }

    public func enforceHistoryLimit() {
        guard items.count > maxItems else { return }
        for item in items.dropFirst(maxItems) { deleteImageFile(for: item) }
        items = Array(items.prefix(maxItems))
        saveHistory()
    }

    /// Removes an item from history
    public func removeItem(_ item: ClipboardItem) {
        deleteImageFile(for: item)
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    /// Removes an item at a specific index
    public func removeItem(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        deleteImageFile(for: items[index])
        items.remove(at: index)
        scheduleSave()
    }

    /// Clears all history
    public func clearHistory() {
        for item in items { deleteImageFile(for: item) }
        items.removeAll()
        saveHistory()
    }

    private func deleteImageFile(for item: ClipboardItem) {
        guard let fileName = item.imageFileName else { return }
        let url = ClipboardItem.imagesDirectoryURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    /// Pastes an item (copies to clipboard and optionally triggers paste)
    public func pasteItem(_ item: ClipboardItem, triggerPaste: Bool = false) {
        ClipboardUsageTracker.shared.recordPaste(of: item)

        // Move item to top of history
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
            items.insert(item, at: 0)
            scheduleSave()
        }

        // Copy to clipboard
        item.copyToPasteboard()

        // Optionally trigger paste action
        if triggerPaste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.simulatePaste()
            }
        }
    }

    /// Simulates Cmd+V keystroke
    public nonisolated func simulatePaste() {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [checkOptPrompt: false] as CFDictionary
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if accessEnabled {
            simulatePasteWithCGEvent()
        } else {
            simulatePasteWithAppleScript()
        }
    }

    /// Simulates a Return keystroke (used by hosts that want to "paste & confirm").
    public nonisolated func simulateEnter() {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [checkOptPrompt: false] as CFDictionary
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if accessEnabled {
            simulateKeyPressWithCGEvent(keyCode: 0x24)
        } else {
            simulateEnterWithAppleScript()
        }
    }

    private nonisolated func simulateKeyPressWithCGEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0.0

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else { return }
        keyDown.flags = flags
        keyDown.post(tap: .cghidEventTap)

        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private nonisolated func simulateEnterWithAppleScript() {
        let script = """
        tell application "System Events"
            key code 36
        end tell
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
        }
    }

    /// Paste using CGEvent (requires accessibility permissions)
    private nonisolated func simulatePasteWithCGEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0.0

        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        } else {
            return
        }

        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Paste using AppleScript (fallback, doesn't require accessibility)
    private nonisolated func simulatePasteWithAppleScript() {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
        }
    }

    /// Schedules a debounced save (coalesces rapid mutations)
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.saveHistoryNow()
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Saves history to disk immediately
    private func saveHistory() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveHistoryNow()
    }

    private func saveHistoryNow() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            print("Failed to save clipboard history: \(error)")
        }
    }

    /// Loads history from disk, migrating old inline image data to separate files
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([ClipboardItem].self, from: data)

            var needsResave = false
            for i in loaded.indices {
                if loaded[i].contentType == .image && loaded[i].imageFileName == nil,
                   let imgData = loaded[i].imageData {
                    let fileName = "\(loaded[i].id.uuidString).png"
                    let url = ClipboardItem.imagesDirectoryURL.appendingPathComponent(fileName)
                    try? imgData.write(to: url, options: .atomic)
                    loaded[i].imageFileName = fileName
                    loaded[i].imageData = nil
                    needsResave = true
                }
            }

            if loaded.count > maxItems {
                let removed = loaded[maxItems...]
                for old in removed { deleteImageFile(for: old) }
                loaded = Array(loaded.prefix(maxItems))
                needsResave = true
            }

            items = loaded
            if needsResave { saveHistory() }
        } catch {
            print("Failed to load clipboard history: \(error)")
            items = []
        }
    }

    /// Returns the item at a given index (1-based for keyboard shortcuts)
    public func item(at index: Int) -> ClipboardItem? {
        let adjustedIndex = index - 1
        guard adjustedIndex >= 0 && adjustedIndex < filteredItems.count else { return nil }
        return filteredItems[adjustedIndex]
    }
}
