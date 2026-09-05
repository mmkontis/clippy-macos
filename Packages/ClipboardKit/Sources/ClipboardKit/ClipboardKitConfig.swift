import Foundation

/// Host-app configuration for ClipboardKit. Set these once at app launch
/// (before the singletons are touched) to point the package at the right
/// on-disk storage location and to wire host-specific settings.
public enum ClipboardKitConfig {
    public static var allowsSimulatedKeystrokes = true
    public static var sharedHistoryEnabled = false
    public static var sharedClientIdentifier = ""
    /// Set by sandboxed hosts to their authorized App Group container.
    public static var sharedContainerURL: URL?

    public static func enableSharedHistory(client: String) {
        sharedClientIdentifier = client
        sharedHistoryEnabled = true
    }

    public static var sharedHistoryDirectory: URL {
        if let sharedContainerURL { return sharedContainerURL.appendingPathComponent("ClipboardHistory", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Humanlike/ClipboardHistory", isDirectory: true)
    }

    static var legacyDirectories: [(String, URL)] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return [("clippy", support.appendingPathComponent("Clippy")),
                ("coworker", support.appendingPathComponent("Coworker/ClipboardHistory"))]
    }


    /// Hosts may supply their own history limit; Coworker retains the default.
    public static var maximumHistoryItems: () -> Int = { 400 }

    /// Folder name (under `~/Library/Application Support/`) where the package
    /// stores `history.json` and an `images/` directory. Each host app picks
    /// its own so two installs don't trample each other.
    ///
    /// Set this before `ClipboardManager.shared` is first accessed.
    public static var storageFolderName: String = "ClipboardKit"

    /// Returns whether the bottom-left recent-media stack should auto-dismiss
    /// the top tile when the user presses ⌘V / ⌃V in another app. The host's
    /// settings store decides this — by default we always dismiss.
    public static var dismissOnPasteEnabled: () -> Bool = { true }
}
