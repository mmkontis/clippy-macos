# Build Clippy

Install Xcode, open `Clippy.xcodeproj`, and run the Clippy scheme. Or run `./build_and_run.sh`. The public checkout includes every clipboard dependency. Clipboard history needs no private service or account.

## One shared implementation

`../ClipboardKit` in the Humanlike workspace is the canonical source: edit shared clipboard behavior there once. Run `python3 scripts/sync-clipboard-kit.py` to copy it into Clippy's standalone `Packages/ClipboardKit`. `--check` detects drift.

Coworker uses the canonical package directly. Rebuild both apps after shared changes. Clippy's windows and settings stay in Clippy; Coworker's windows and settings stay in Coworker. They only need separate edits when their own interface or integration changes.

## One local history

Both updated apps opt into protocol v1 at startup and use `~/Library/Application Support/Humanlike/ClipboardHistory/shared-history.sqlite`. They discover each other through this store, merge earlier histories once, deduplicate content, and refresh within approximately one second. Neither app needs the other to be installed or running. An older Coworker binary must be updated before it can participate.

SQLite transactions protect simultaneous changes. Each app writes individual additions and deletions, never a whole stale history file. Shared images have content-based filenames. The store retains 400 items; each app's display limit only changes its own list. Deleting or clearing history affects both apps. Original imported files are retained as a recovery copy and never imported again after a successful migration.

Sandboxed App Store builds additionally require an Apple-authorized App Group shared with the companion app. The package exposes `sharedContainerURL` for that integration. The direct-download path alone does not grant access from a sandbox.

## Verify and release

Run `./scripts/test.sh` for shared storage, privacy filtering, and streaming tests. See [RELEASE.md](RELEASE.md) for signing and publication. Never commit credentials or label an unsigned development build as a ready-to-install release.
