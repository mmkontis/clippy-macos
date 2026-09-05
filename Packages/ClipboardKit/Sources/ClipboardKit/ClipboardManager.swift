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
    private var sharedStore: SharedClipboardStore?
    private var sharedRefreshTimer: Timer?
    private var lastSharedRevision: Int64 = -1
    private var lastSharedLimit = 0
    @Published public private(set) var storageError: String?
    @Published public private(set) var companionDetected = false
    public var usesSharedHistory: Bool { sharedStore != nil }


    /// Path to the history file (under the host-configured storage folder).
    private var historyFileURL: URL {
        ClipboardItem.storageDirectoryURL.appendingPathComponent("history.json")
    }

    private init() {
        if ClipboardKitConfig.sharedHistoryEnabled {
            do {
                let store = try SharedClipboardStore(directory: ClipboardKitConfig.sharedHistoryDirectory)
                sharedStore = store
                try store.register(client: ClipboardKitConfig.sharedClientIdentifier)
                importLegacyHistory()
                refreshSharedHistory()
                sharedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshSharedHistory() }
                }
                if let sharedRefreshTimer { RunLoop.current.add(sharedRefreshTimer, forMode: .common) }
            } catch { storageError = "Shared history is unavailable. Your earlier history is still on this Mac." }
        } else {
            loadHistory()
        }

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

    private func importLegacyHistory() {
        guard let sharedStore else { return }
        for (identifier, directory) in ClipboardKitConfig.legacyDirectories {
            do { try sharedStore.importLegacy(directory: directory, identifier: identifier) }
            catch { storageError = "Some earlier history could not be imported. The original files have been kept." }
        }
    }

    public func refreshSharedHistory() {
        guard let sharedStore else { return }
        do {
            let snapshot = try sharedStore.snapshot(limit: 400)
            if snapshot.revision != lastSharedRevision || lastSharedLimit != maxItems {
                items = Array(snapshot.items.prefix(maxItems))
                ClipboardUsageTracker.shared.retainHistory(snapshot.items)
                let retainedIDs = Set(snapshot.items.map(\.id))
                for queued in RecentMediaQueue.shared.items where !retainedIDs.contains(queued.id) {
                    RecentMediaQueue.shared.dismiss(queued)
                }
                lastSharedRevision = snapshot.revision
                lastSharedLimit = maxItems
            }
            let companion = ClipboardKitConfig.sharedClientIdentifier == "clippy" ? "coworker" : "clippy"
            companionDetected = try sharedStore.hasClient(companion)
        } catch { storageError = "Shared history could not be refreshed. Please try again." }
    }

    private func sharedMutation(_ operation: (SharedClipboardStore) throws -> Void) -> Bool {
        guard ClipboardKitConfig.sharedHistoryEnabled else { return false }
        guard let sharedStore else { return true }
        do {
            try operation(sharedStore)
            refreshSharedHistory()
        } catch { storageError = "That change could not be saved. Please try again." }
        return true
    }

    /// Adds a new item to the history
    public func addItem(_ item: ClipboardItem) {
        ClipboardUsageTracker.shared.recordCopy(of: item)
        var savedSuccessfully = false
        if sharedMutation({ try $0.upsert(item); savedSuccessfully = true }) {
            if savedSuccessfully, let saved = items.first, saved.contentType == .image || saved.contentType == .fileURL {
                RecentMediaQueue.shared.enqueue(saved)
            }
            return
        }

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
        if usesSharedHistory {
            lastSharedRevision = -1
            refreshSharedHistory()
            return
        }
        guard items.count > maxItems else { return }
        for item in items.dropFirst(maxItems) { deleteImageFile(for: item) }
        items = Array(items.prefix(maxItems))
        saveHistory()
    }

    /// Removes an item from history
    public func removeItem(_ item: ClipboardItem) {
        if sharedMutation({ try $0.remove(id: item.id) }) { return }
        ClipboardUsageTracker.shared.remove(item)
        RecentMediaQueue.shared.dismiss(item)
        deleteImageFile(for: item)
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    /// Removes an item at a specific index
    public func removeItem(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        if sharedMutation({ try $0.remove(id: items[index].id) }) { return }
        ClipboardUsageTracker.shared.remove(items[index])
        RecentMediaQueue.shared.dismiss(items[index])
        deleteImageFile(for: items[index])
        items.remove(at: index)
        scheduleSave()
    }

    /// Clears all history
    public func clearHistory() {
        if sharedMutation({ try $0.clear() }) { return }
        ClipboardUsageTracker.shared.clear()
        RecentMediaQueue.shared.dismissAll()
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
        if sharedMutation({ try $0.moveToFront(id: item.id) }) {
            // The item can still be copied, but a stale selection never restores a deleted row.
        } else if let index = items.firstIndex(where: { $0.id == item.id }) {
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
        guard ClipboardKitConfig.allowsSimulatedKeystrokes else { return }
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
        guard ClipboardKitConfig.allowsSimulatedKeystrokes else { return }
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
        guard !ClipboardKitConfig.sharedHistoryEnabled else { return }
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
