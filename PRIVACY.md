# Privacy

Direct-download builds store clipboard history and images locally in `~/Library/Application Support/Humanlike/ClipboardHistory`. The Store target requires an authorized local App Group container. File entries reference the original files. They are not encrypted by Clippy. macOS account access and FileVault protect the underlying disk according to your Mac's configuration. You can remove items, clear history, or enable clear history on quit in Settings.

No Clippy account is required. Updated Clippy and Coworker builds share this local history automatically. Copies and deletions appear in both apps. Nothing is synchronized across devices. Earlier history files are imported once and retained in their original folders as recovery copies; clearing the shared history does not erase those old recovery files. Content marked as concealed or transient by the copying app is excluded; ordinary copied secrets can still enter history.

## Text AI in version 1.3

Text AI is off until you choose a provider. Clippy sends only the prompt you explicitly submit to OpenAI. It does not attach clipboard history, files, microphone audio, or a device ID. Answers appear in Clippy; copying them is an explicit action.

The API-key option uses OpenAI's Responses API with storage disabled. The key stays in macOS Keychain, and usage is billed to your OpenAI API account. OpenAI's provider-side retention and policies still apply.

The ChatGPT option uses the bundled, Apache-licensed Codex runtime and your ChatGPT account's Codex allowance. Codex manages sign-in in a Clippy-specific Keychain credential store. Clippy does not read OAuth tokens or your other Codex account. It uses temporary conversations and disables tools and local environment access. Model requests include the submitted text and the standard context needed by the Codex service. OpenAI's ChatGPT/Codex terms, plan limits, and data controls apply.

With AI enabled, Clippy fetches available models at startup and after connection changes. ChatGPT also provides account allowance and reset times. Model lists and usage figures stay in memory; only your chosen model is saved. API token counts cover the latest successful Clippy reply, not your account-wide bill.

Clippy does not keep a transcript log. The current prompt and answer remain in memory until cleared or the app exits. Disconnect ChatGPT or remove the API key in Settings to remove the respective saved credentials. No microphone permission or voice service is included in version 1.3.

## Earlier downloads

Version 1.2.0, still the public download until 1.3 is released, includes optional Humanlike AI paste (submitted prompt and random installation ID) and optional Gemini voice (microphone audio with the user's Gemini key). Those features are removed in the 1.3 source.


Sparkle can contact the update server to check for releases. The server can receive normal connection metadata such as IP address. Automatic installation is off by default. Users can control update checks through Sparkle.

Opening a promotional or support link opens a website in your browser. The Coworker banner does not upload your clipboard history.
