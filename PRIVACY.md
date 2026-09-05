# Privacy

Direct-download builds store clipboard history and images locally in `~/Library/Application Support/Humanlike/ClipboardHistory`. The Store target requires an authorized local App Group container. File entries reference the original files. They are not encrypted by Clippy. macOS account access and FileVault protect the underlying disk according to your Mac's configuration. You can remove items, clear history, or enable clear history on quit in Settings.

No Clippy account is required. Updated Clippy and Coworker builds share this local history automatically. Copies and deletions appear in both apps. Nothing is synchronized across devices. Earlier history files are imported once and retained in their original folders as recovery copies; clearing the shared history does not erase those old recovery files. Content marked as concealed or transient by the copying app is excluded; ordinary copied secrets can still enter history.

AI paste is optional and off by default. When enabled, the prompt you explicitly submit and a random persistent installation ID are sent to Humanlike's online AI endpoint. The endpoint uses the ID for service limits and may process requests through an AI provider. Do not enable this option for material you do not want processed online.

Voice is optional. A voice conversation sends microphone audio to Google's Gemini API using your own key. The key is kept in macOS Keychain. Clippy does not write voice responses, transcripts, or session tokens to its debug log. Google applies its own terms and data handling policies.

Sparkle can contact the update server to check for releases. The server can receive normal connection metadata such as IP address. Automatic installation is off by default. Users can control update checks through Sparkle.

Opening a promotional or support link opens a website in your browser. The Coworker banner does not upload your clipboard history.
