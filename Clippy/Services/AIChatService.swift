import AppKit
import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case none, openAI, chatGPT
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Off"
        case .openAI: return "OpenAI API key"
        case .chatGPT: return "ChatGPT account"
        }
    }
    static var selected: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: "textAIProvider") ?? "") ?? .none
    }
}

enum TextAIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Only the text explicitly submitted by the user goes to the selected provider.
@MainActor
final class AIChatService: ObservableObject {
    static let shared = AIChatService()
    @Published var isStreaming = false
    @Published var error: String?
    @Published var streamedText = ""
    @Published var lastPrompt = ""
    private var requestTask: Task<Void, Never>?
    private var requestID = UUID()
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func prepareForStreaming() {
        error = nil
        streamedText = ""
    }

    func sendMessageAndStream(_ message: String, onComplete: @escaping () -> Void) {
        cancel()
        let prompt = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { onComplete(); return }
        guard prompt.utf8.count <= 100_000 else {
            error = "Please send a shorter prompt (up to 100 KB)."
            onComplete()
            return
        }
        let provider = AIProvider.selected
        guard provider != .none else {
            error = "Choose an OpenAI API key or connect ChatGPT in Settings."
            SettingsWindowController.shared.showSettings()
            onComplete()
            return
        }
        let id = UUID()
        requestID = id
        lastPrompt = prompt
        streamedText = ""
        error = nil
        isStreaming = true
        requestTask = Task {
            do {
                let answer: String
                switch provider {
                case .openAI:
                    guard let key = OpenAICredentials.read(), !key.isEmpty else {
                        throw TextAIError.message("Add your OpenAI API key in Settings first.")
                    }
                    let model = UserDefaults.standard.string(forKey: "openAITextModel") ?? "gpt-5.4-mini"
                    let request = try Self.apiRequest(prompt: prompt, key: key, model: model)
                    let (data, response) = try await session.data(for: request)
                    answer = try Self.apiAnswer(data: data, response: response)
                case .chatGPT:
                    answer = try await CodexConnection.shared.reply(to: prompt)
                case .none:
                    return
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                streamedText = answer
            } catch {
                guard requestID == id, !Task.isCancelled else { return }
                // Never display raw provider responses, URLs, credentials, or process diagnostics.
                self.error = (error as? TextAIError)?.errorDescription ?? "Couldn't get a reply. Check your connection and try again."
            }
            guard requestID == id else { return }
            isStreaming = false
            requestTask = nil
            onComplete()
        }
    }

    func cancel() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        CodexConnection.shared.cancelReply()
        isStreaming = false
    }

    func clear() {
        cancel()
        streamedText = ""
        lastPrompt = ""
        error = nil
    }

    static func apiRequest(prompt: String, key: String, model: String) throws -> URLRequest {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !key.contains("\n"), !key.contains("\r") else {
            throw TextAIError.message("Check the API key and model in Settings.")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": prompt, "store": false,
            "instructions": "You are Clippy, a concise text assistant. Answer the user's request. You cannot access their clipboard, files, microphone, or other apps.",
            "max_output_tokens": 4096
        ])
        return request
    }

    static func apiAnswer(data: Data, response: URLResponse) throws -> String {
        guard let response = response as? HTTPURLResponse else {
            throw TextAIError.message("OpenAI returned an unexpected response.")
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw TextAIError.message("OpenAI couldn't authorize this request. Check your API key and model access.")
        case 429: throw TextAIError.message("Your OpenAI API quota or rate limit was reached. Check API billing or try again later.")
        default: throw TextAIError.message("OpenAI couldn't complete the request (HTTP \(response.statusCode)). Try again later.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["status"] as? String == "completed",
              let output = json["output"] as? [[String: Any]] else {
            throw TextAIError.message("OpenAI didn't finish the answer. Try a shorter request.")
        }
        let answer = output.filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { item -> String? in
                switch item["type"] as? String {
                case "output_text": return item["text"] as? String
                case "refusal": return item["refusal"] as? String
                default: return nil
                }
            }.joined(separator: "\n")
        guard !answer.isEmpty else { throw TextAIError.message("OpenAI returned no text. Try a different prompt.") }
        return answer
    }
}
