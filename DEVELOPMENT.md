# Development

See [README.md](README.md) for setup and the relationship to Coworker's shared clipboard package. See [RELEASE.md](RELEASE.md) for release signing and publication.

The public checkout must build without sibling directories. `Packages/ClipboardKit` is the committed snapshot of the canonical Humanlike workspace package. Refresh it using `scripts/sync-clipboard-kit.py` and keep all shared changes in the canonical source first.

Local builds can use `./build_and_run.sh`. Do not commit credentials, development logs, `.history`, or signed archives. Do not copy a development binary to the public download location.
