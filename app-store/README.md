# App Store draft

The Clippy record is created under Univation (team `3JN6A5RJ38`), Apple app ID `6809036065`, bundle ID `ai.univation.clippy`.

[Open the draft](https://appstoreconnect.apple.com/apps/6809036065/distribution/macos/version/inflight).

Version 1.2.0 remains in Prepare for Submission. Build 8 is uploaded and attached, with its icon and five native screenshots. Pricing is free, with automatic release after approval. It has not been submitted for review.

Version 1.3.0 build 9 is in development. It replaces Gemini voice with optional OpenAI text AI using either an API key or ChatGPT sign-in. The local listing draft describes this new version and must not be submitted with build 8.

`listing.en-US.json` is the local copy. Screenshots use isolated sample data. Review them against the signed Store build before submission.

The `ClippyStore` target excludes Sparkle, uses Apple's sandbox and manual paste, and requires a provisioned App Group. The direct-download build retains Sparkle. Both Store and companion builds need the same authorized App Group before sharing across the sandbox boundary.

Release certificates and the shared App Group are configured. Remaining: finish authenticated provider tests, validate and sign the new universal build, upload it, update the Store version, and complete content rights, privacy, age rating and review access. The direct-download update also needs fresh notarization and a Sparkle signature.

The screenshots use the original Clippy logo, Coworker blue (#2563EB), and a light panel. History, search, and images/files have no promotion; only the fourth image shows the optional Coworker banner with its original logo. Recreate them with a Debug ClippyStore build and `Clippy.app/Contents/MacOS/Clippy --capture-listing /absolute/output/directory`.
