# App Store draft

The Clippy record is created under Univation (team `3JN6A5RJ38`), Apple app ID `6809036065`, bundle ID `ai.univation.clippy`.

[Open the draft](https://appstoreconnect.apple.com/apps/6809036065/distribution/macos/version/inflight).

Version 1.2.0 is in Prepare for Submission. Listing copy, no-login review instructions, manual release, and two native screenshot drafts have been saved. Subtitle and Utilities/Productivity categories are configured. No binary upload or review submission has been completed.

`listing.en-US.json` is the local copy. Screenshots use isolated sample data. Review them against the signed Store build before submission.

The `ClippyStore` target excludes Sparkle, uses Apple's sandbox and manual paste, and requires a provisioned App Group. The direct-download build retains Sparkle. Both Store and companion builds need the same authorized App Group before sharing across the sandbox boundary.

Remaining: approve creation of release certificates and the shared App Group, provision and test signed builds, upload the Store package, complete privacy and age-rating answers, set free pricing and availability, and complete account compliance where Apple requires it. The direct-download installer additionally needs notarization authentication.
