# Clippy

A free, open source clipboard manager for macOS 14 or later. No account, subscription, or sign-in is required for clipboard history.

Copy text, images, and files, then press `⌘⇧V` or click the menu bar clipboard to search and reuse them. Customize shortcuts in Settings. The single welcome screen is optional. Accessibility enables automatic paste; manual copy and paste works without it.

## Build from source

Install Xcode with the macOS SDK, open `Clippy.xcodeproj`, and run the Clippy scheme. Choose your own signing team for development. The project includes its ClipboardKit dependency; no Humanlike monorepo or private service is needed to build or use clipboard history. Xcode downloads the pinned Sparkle dependency from its public repository.

For a local development build:

```sh
./build_and_run.sh
```

This builds and opens a local copy without replacing an installed app. Public distribution needs Developer ID signing and notarization. See [RELEASE.md](RELEASE.md).

## Optional AI

AI paste is off by default. Enable it in Settings to send explicitly submitted prompts and a random installation identifier to Humanlike's online AI service. Service availability and usage limits apply; the server is not part of this repository.

The optional voice penguin requires your own Gemini API key, stored in macOS Keychain. Starting a conversation sends microphone audio to Google. Provider charges may apply. Neither feature is needed for the free clipboard manager. See [PRIVACY.md](PRIVACY.md).

## Relationship to Coworker

Clippy and Coworker's built-in clipboard use the same ClipboardKit source. Clippy bundles a snapshot in `Packages/ClipboardKit` so a standalone clone builds independently.

Within the Humanlike workspace, `../ClipboardKit` remains the canonical shared implementation. Run `python3 scripts/sync-clipboard-kit.py` after changing it, then review and commit the snapshot. `--check` detects drift. App-specific panels, settings, and keyboard shortcuts remain separate and do not automatically sync.

Clipboard history is local and separate: Clippy uses `~/Library/Application Support/Clippy`; Coworker uses `~/Library/Application Support/Coworker/ClipboardHistory`. There is no account sync, history migration, or cross-device sync. Both can observe new copies from the Mac's system clipboard while running. Avoid assigning both apps the same shortcut.

The dismissible banner below clipboard history introduces Coworker's separate dictation app. Dismissal persists, and a compact link remains. Coworker has its own service terms and onboarding; using it is optional.

## License

MIT. See [LICENSE](LICENSE). Sparkle is separately licensed under its [upstream license](https://github.com/sparkle-project/Sparkle/blob/2.9.0/LICENSE).
