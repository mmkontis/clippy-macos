import SwiftUI

struct AIPanel: View {
    @ObservedObject var aiService = AIChatService.shared
    @Binding var isPresented: Bool
    var onSubmit: ((_ prompt: String) -> Void)?
    var onHide: (() -> Void)?
    var onSwitchToClipboard: (() -> Void)?
    @State private var inputText = ""
    @State private var copied = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ask Clippy", systemImage: "sparkles").font(.headline)
                Spacer()
                Button { SettingsWindowController.shared.showSettings() } label: {
                    Image(systemName: "gearshape")
                }.help("AI settings")
                Button { onSwitchToClipboard?() } label: {
                    Image(systemName: "clipboard")
                }.help("Clipboard history")
                Button {
                    aiService.cancel()
                    onHide?()
                } label: { Image(systemName: "xmark") }.help("Close")
            }
            HStack(alignment: .bottom) {
                TextField("Write, rewrite, summarize…", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit { submit() }
                if aiService.isStreaming {
                    Button("Stop") { aiService.cancel() }
                } else {
                    Button("Send") { submit() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.145, green: 0.388, blue: 0.922))
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error = aiService.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if aiService.isStreaming {
                HStack { ProgressView().controlSize(.small); Text("Thinking…").font(.callout) }
            }
            ScrollView {
                Text(aiService.streamedText.isEmpty ? "Your answer will appear here." : aiService.streamedText)
                    .font(.system(size: 14))
                    .foregroundStyle(aiService.streamedText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("Only text you send is shared with OpenAI.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    aiService.clear()
                    copied = false
                }.disabled(aiService.isStreaming)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(aiService.streamedText, forType: .string)
                    copied = true
                }.disabled(aiService.streamedText.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 380)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .onAppear { isInputFocused = true }
        .onKeyPress(.escape) {
            aiService.cancel()
            onHide?()
            return .handled
        }
    }

    private func submit() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !aiService.isStreaming else { return }
        copied = false
        onSubmit?(prompt)
    }
}
