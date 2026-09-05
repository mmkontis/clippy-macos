#if !APP_STORE
import Foundation
import Sparkle

/// Sparkle handles verified updates and the user's installation preferences.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterDelegate()

    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/mmkontis/clippy-macos/main/appcast.xml"
    }
}

#endif
