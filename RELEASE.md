# Releasing Clippy

Version 1.2.0, build 8 is prepared for direct Mac distribution. A successful local build does not establish that the app is notarized or published.

1. Run `python3 scripts/sync-clipboard-kit.py --check` in the Humanlike workspace. Review shared changes with Coworker. Standalone clones already include the snapshot.
2. Build for Apple Silicon and Intel. Exercise text, image and file copies, search, paste, optional permissions, first launch, banner dismissal, settings, and clear history on quit.
3. Use an existing Developer ID Application certificate and its private key belonging to the release organization. Set `CLIPPY_SIGNING_IDENTITY` to its exact name and `CLIPPY_NOTARY_PROFILE` to an existing notarytool Keychain profile. The Univation team was verified as `3JN6A5RJ38` on September 5, 2026. Browser sign-in does not automatically install signing certificates or authenticate notarization tools.
4. Run `./create_dmg.sh`. It signs with hardened runtime, notarizes and staples the app and DMG, assesses Gatekeeper, and signs the final DMG for Sparkle. It stops if any required step fails. It never generates signing credentials.
5. Publish the final DMG, checksum, and clean source archive. Do not publish development builds as ready-to-install releases. Do not publish the existing private repository's history or old binary while it contains the previously embedded provider key. Revoke that key in its provider account. A clean source snapshot can be published separately without old history or binaries.
6. Add the new appcast item only after the download exists. Use HTTPS URLs, build 8, version 1.2.0, the actual byte length, and the generated EdDSA signature. Retain the existing Sparkle public key so installed copies can verify future updates. Do not advertise an unavailable version.
7. Verify HTTP downloads, the appcast signature, and an upgrade from the last shipped version on a test Mac. Then update the landing page and changelog.

## Distribution choices

Direct download: repeat Developer ID signing and automated notarization for every release. Sparkle delivers updates. Full Mac App Store review is not part of this route.

Mac App Store: the `ClippyStore` target is sandboxed, excludes Sparkle, and uses manual paste. `scripts/archive-app-store.sh` requires the verified team, provisioning profile, and App Group. Signed sandbox testing and App Review remain required. Both Store and companion builds need the same authorized App Group before their histories can combine. Listing copy and native screenshot drafts are in `app-store/`.

## Signing keys and backups

Keep the existing Sparkle EdDSA private key in macOS Keychain. Its public key in `Info.plist` is intentionally public and is safe in source control. Confirm that `generate_keys -p` matches `SUPublicEDKey` before signing. Never generate a new key for an ordinary update.

Keep an encrypted backup of the Sparkle private key and a password-protected export of each Apple release certificate with its private key (.p12). Store a recovery copy in a trusted password manager or encrypted offline storage, separately from this Mac. A certificate or CSR alone cannot replace a lost private key. Do not put private keys, .p12 files, notarization passwords, or API keys in Git, the website, DMGs, release assets, logs, or chat. Never commit unencrypted exports. Encrypted backup storage and its recovery password must be kept separate.

Sparkle supports exporting an existing key with `generate_keys -x /secure/destination/key` and importing with `-f`. That export is plaintext: only use a destination inside encrypted storage and do not leave a loose temporary copy. Back up Apple identities through Keychain Access or Xcode with a strong export password. Test recovery on a separate authorized Mac before relying on the backup. If keys must change, follow Sparkle's documented rotation process; do not change both trust mechanisms in one update.

The website hosts the public feed and installers only. Signing secrets stay on the release Mac or in explicitly configured CI secret storage. In the Humanlike workspace, `Humanlike-next/scripts/prepare-clippy-update.py` verifies the notarized DMG, existing Sparkle key, and actual public download before updating the feed and website download manifest together. See `Humanlike-next/docs/clippy-updates.md` for the command.

## Store preparation status

The `ClippyStore` target uses the registered `group.ai.univation.clipboard` App Group. The Apple Distribution and Mac Installer Distribution certificates were issued for Univation, and profile `Clippy Mac App Store 2026` was generated on September 6, 2026. A universal version 1.2.0 (build 8) archive and installer passed local signature, sandbox entitlement, App Group, and Sparkle exclusion checks.

The Store draft contains five screenshots, including the native media bar. This is not a published release. Upload requires an Xcode account with App Store Connect access. Content rights, age rating, app privacy, reviewer contact completion, and signed runtime validation must be finished before submission.

## Direct-download update feed

New GitHub builds use `https://raw.githubusercontent.com/mmkontis/clippy-macos/main/appcast.xml`. Publish and verify the signed download before committing its Sparkle enclosure to this feed. The website feed can mirror it after deployment. The legacy website feed is not a release dependency for new GitHub installations.

## Xcode account notarization

The first GitHub download is a ZIP containing the Developer ID signed and stapled app. Xcode can upload an archive for notarization using its signed-in Apple account (`-exportArchive`, `method=developer-id`, `destination=upload`). After Apple accepts it, run `scripts/package-notarized-app.py --archive /path/to/Clippy.xcarchive --sparkle-bin /path/to/Sparkle/bin`. It verifies notarization, signatures, architecture, and the existing update key before exporting the ZIP. Users unzip it and drag Clippy.app into Applications.

The DMG workflow in `create_dmg.sh` remains available when a notarytool Keychain profile is configured. Never distribute the old unsigned preview. Store build 8 has uploaded successfully and passed processing; public App Review submission still requires the remaining listing declarations.
