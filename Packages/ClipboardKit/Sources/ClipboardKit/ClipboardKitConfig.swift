import Foundation

/// Host-app configuration for ClipboardKit. Set these once at app launch
/// (before the singletons are touched) to point the package at the right
/// on-disk storage location and to wire host-specific settings.
public enum ClipboardKitConfig {

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
