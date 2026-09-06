# Build Clippy

Install Xcode, run python3 scripts/fetch-codex.py to verify and prepare the pinned Codex runtime for Apple Silicon and Intel, then open `Clippy.xcodeproj`, and run the Clippy scheme. Or run `./build_and_run.sh`. The public checkout includes every clipboard dependency. Clipboard history needs no private service or account.

## One shared implementation

`../ClipboardKit` in the Humanlike workspace is the canonical source: edit shared clipboard behavior there once. Run `python3 scripts/sync-clipboard-kit.py` to copy it into Clippy's standalone `Packages/ClipboardKit`. `--check` detects drift.

Coworker uses the canonical package directly. Rebuild both apps after shared changes. Clippy's windows and settings stay in Clippy; Coworker's windows and settings stay in Coworker. They only need separate edits when their own interface or integration changes.

## One local history

Both updated apps opt into protocol v1 at startup and use `~/Library/Application Support/Humanlike/ClipboardHistory/shared-history.sqlite`. They discover each other through this store, merge earlier histories once, deduplicate content, and refresh within approximately one second. Neither app needs the other to be installed or running. An older Coworker binary must be updated before it can participate.

SQLite transactions protect simultaneous changes. Each app writes individual additions and deletions, never a whole stale history file. Shared images have content-based filenames. The store retains 400 items; each app's display limit only changes its own list. Deleting or clearing history affects both apps. Original imported files are retained as a recovery copy and never imported again after a successful migration.

Sandboxed App Store builds additionally require an Apple-authorized App Group shared with the companion app. The package exposes `sharedContainerURL` for that integration. The direct-download path alone does not grant access from a sandbox.

## Verify and release

Run `./scripts/test.sh` for shared storage, privacy filtering, and text AI tests. See [RELEASE.md](RELEASE.md) for signing and publication. Never commit credentials or label an unsigned development build as a ready-to-install release.

## Text AI

Both targets include the same text panel and two providers. API keys use macOS Keychain and the Responses API. ChatGPT sign-in uses the bundled Codex 0.153.4 App Server over stdio with a separate Clippy credential store. The helper inherits the Store sandbox; it is included at build time and never downloaded by the installed app. Its Apache license and notice ship in Resources. Do not copy a private binary from the ChatGPT desktop app.

For a native-only development build, prepare python3 scripts/fetch-codex.py --arch arm64 (or x86_64) and set both ARCHS and CLIPPY_CODEX_ARCH to that architecture. Release builds must use the default universal runtime. The build fails when the required helper is missing or has the wrong architecture.

Before publication, test browser sign-in, cancel, reconnect, logout, API success and quota failures, sandbox launch, and both architectures. An App Store upload must use the new text-only binary; build 8 still contains Gemini voice.
