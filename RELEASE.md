# Releasing Clippy

Version 1.2.0, build 7 is prepared for direct Mac distribution. A successful local build does not establish that the app is notarized or published.

1. Run `python3 scripts/sync-clipboard-kit.py --check` in the Humanlike workspace. Review shared changes with Coworker. Standalone clones already include the snapshot.
2. Build for Apple Silicon and Intel. Exercise text, image and file copies, search, paste, optional permissions, first launch, banner dismissal, settings, and clear history on quit.
3. Use an existing Developer ID Application certificate and its private key belonging to the release organization. Set `CLIPPY_SIGNING_IDENTITY` to its exact name and `CLIPPY_NOTARY_PROFILE` to an existing notarytool Keychain profile. The legacy Xcode team value is not proof of current account ownership.
4. Run `./create_dmg.sh`. It signs with hardened runtime, notarizes and staples the app and DMG, assesses Gatekeeper, and signs the final DMG for Sparkle. It stops if any required step fails. It never generates signing credentials.
5. Publish the final DMG, checksum, and clean source archive. Do not publish development builds as ready-to-install releases. Do not publish the existing private repository's history or old binary while it contains the previously embedded provider key. Revoke that key in its provider account. A clean source snapshot can be published separately without old history or binaries.
6. Add the new appcast item only after the download exists. Use HTTPS URLs, build 7, version 1.2.0, the actual byte length, and the generated EdDSA signature. Retain the existing Sparkle public key so installed copies can verify future updates. Do not advertise an unavailable version.
7. Verify HTTP downloads, the appcast signature, and an upgrade from the last shipped version on a test Mac. Then update the landing page and changelog.

## Distribution choices

Direct download: repeat Developer ID signing and automated notarization for every release. Sparkle delivers updates. Full Mac App Store review is not part of this route.

Mac App Store: requires a separate sandbox-compatible build, removal of the external Sparkle updater for that channel, store metadata, and App Review for new app versions. The current non-sandboxed clipboard and event-injection design is prepared for direct distribution, not a verified Mac App Store submission.
