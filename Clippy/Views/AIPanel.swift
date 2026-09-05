import SwiftUI
import Carbon.HIToolbox

/// The AI chat panel view - activated with Cmd+Shift+C
/// Shows spinner while streaming, streams response directly to active input
struct AIPanel: View {
    @ObservedObject var aiService = AIChatService.shared
    @Binding var isPresented: Bool
    var onSubmit: ((_ prompt: String) -> Void)?
    var onHide: (() -> Void)?
    var onSwitchToClipboard: (() -> Void)?
    
    @State private var inputText = ""
    @State private var isHovered = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // AI sparkle button / spinner
                if aiService.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Button(action: {
                        submitPrompt()
                    }) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.isEmpty)
                }
                
                // Input field, streaming preview, or rate limit error
                if let rateLimitError = aiService.rateLimitError {
                    Text(rateLimitError)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if aiService.isStreaming {
                    Text(aiService.streamedText.isEmpty ? aiService.lastPrompt : aiService.streamedText)
                        .font(.system(size: 13))
                        .foregroundColor(aiService.streamedText.isEmpty ? .primary.opacity(0.7) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Ask AI...", text: $inputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isInputFocused)
                        .onSubmit {
                            submitPrompt()
                        }
                        .onKeyPress(.return) {
                            submitPrompt()
                            return .handled
                        }
                }
                
                // Button to switch to Clipboard panel (Cmd+Shift+V style)
                Button(action: {
                    onSwitchToClipboard?()
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(aiService.isStreaming)
                .help("Switch to Clipboard (Cmd+Shift+V)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 400)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(0.95)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isHovered {
                    isHovered = true
                    NSCursor.pointingHand.push()
                }
            case .ended:
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
        }
        .onDisappear {
            if isHovered {
                isHovered = false
                NSCursor.pop()
            }
        }
        .onAppear {
            inputText = ""
            // Auto-focus after a tiny delay to ensure view is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
        }
        .onKeyPress(.escape) {
            if aiService.isStreaming {
                aiService.cancel()
            }
            closePanel()
            return .handled
        }
        .onChange(of: aiService.isStreaming) { _, isStreaming in
            // When streaming completes, hide the panel
            if !isStreaming && inputText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onHide?()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func submitPrompt() {
        let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard !aiService.isStreaming else { return }
        
        // Store the message and clear input
        let prompt = message
        inputText = ""
        
        // Call submit handler - this will activate previous app and start streaming
        // But panel stays open to show spinner
        onSubmit?(prompt)
    }
    
    private func closePanel() {
        isPresented = false
    }
}

#Preview {
    AIPanel(isPresented: .constant(true))
}
