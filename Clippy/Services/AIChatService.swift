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
    @Published private(set) var lastUsage: TextTokenUsage?
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
        lastUsage = nil
        streamedText = ""
        error = nil
        isStreaming = true
        requestTask = Task {
            do {
                let answer: String
                var usage: TextTokenUsage?
                switch provider {
                case .openAI:
                    guard let key = OpenAICredentials.read(), !key.isEmpty else {
                        throw TextAIError.message("Add your OpenAI API key in Settings first.")
                    }
                    let model = UserDefaults.standard.string(forKey: "openAITextModel") ?? "gpt-5.4-mini"
                    let request = try Self.apiRequest(prompt: prompt, key: key, model: model)
                    let (data, response) = try await session.data(for: request)
                    usage = TextTokenUsage.api(data, model: model)
                    answer = try Self.apiAnswer(data: data, response: response)
                case .chatGPT:
                    let model = UserDefaults.standard.string(forKey: "chatGPTTextModel")
                    answer = try await CodexConnection.shared.reply(to: prompt, model: model)
                    usage = CodexConnection.shared.lastUsage
                case .none:
                    return
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                streamedText = answer
                lastUsage = usage
                if provider == .chatGPT { Task { await AIModelCatalog.shared.refresh() } }
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
        lastUsage = nil
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

struct AIModelOption: Identifiable, Equatable {
    let id: String
    let title: String
    var isDefault = false
}

struct TextTokenUsage: Equatable {
    let provider: AIProvider
    let model: String
    let input: Int
    let output: Int
    let cached: Int
    var total: Int { input + output }

    static func api(_ data: Data, model: String) -> TextTokenUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int else { return nil }
        let cached = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        return .init(provider: .openAI, model: json["model"] as? String ?? model,
                     input: max(0, input), output: max(0, output), cached: max(0, cached))
    }
}

struct AIUsageWindow: Identifiable, Equatable {
    let id: String
    let title: String
    let usedPercent: Int
    let resetsAt: Date?

    static func parse(_ result: [String: Any]) -> [AIUsageWindow] {
        let buckets: [String: [String: Any]]
        if let all = result["rateLimitsByLimitId"] as? [String: [String: Any]], !all.isEmpty {
            buckets = all
        } else if let single = result["rateLimits"] as? [String: Any] {
            buckets = [single["limitId"] as? String ?? "codex": single]
        } else { return [] }
        return buckets.keys.sorted().flatMap { key -> [AIUsageWindow] in
            guard let bucket = buckets[key] else { return [] }
            return ["primary", "secondary"].compactMap { kind in
                guard let window = bucket[kind] as? [String: Any], let used = window["usedPercent"] as? Int else { return nil }
                let minutes = window["windowDurationMins"] as? Int
                let duration: String
                if let minutes, minutes > 0 {
                    if minutes % 1440 == 0 { duration = "\(minutes / 1440) days" }
                    else if minutes % 60 == 0 { duration = "\(minutes / 60) hours" }
                    else { duration = "\(minutes) minutes" }
                } else { duration = kind == "primary" ? "Current window" : "Longer window" }
                let name = bucket["limitName"] as? String ?? (key == "codex" ? "Codex" : key)
                let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return .init(id: "\(key).\(kind)", title: "\(name) · \(duration)", usedPercent: max(0, used), resetsAt: reset)
            }
        }
    }
}

/// Account-scoped discovery. Only the selection is saved; lists and quota data
/// are fetched again on each launch and discarded when credentials change.
@MainActor final class AIModelCatalog: ObservableObject {
    static let shared = AIModelCatalog()
    @Published private(set) var models: [AIModelOption] = []
    @Published private(set) var windows: [AIUsageWindow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var modelsError: String?
    @Published private(set) var usageError: String?
    @Published private(set) var refreshedAt: Date?
    private var provider: AIProvider = .none
    private var generation = UUID()
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    static func selectionKey(_ provider: AIProvider) -> String {
        provider == .chatGPT ? "chatGPTTextModel" : "openAITextModel"
    }

    func invalidate() {
        generation = UUID()
        isRefreshing = false
        models = []
        windows = []
        modelsError = nil
        usageError = nil
        refreshedAt = nil
    }

    func refresh() async {
        let selected = AIProvider.selected
        if isRefreshing, provider == selected { return }
        if provider != selected { invalidate() }
        provider = selected
        guard selected != .none else { return }
        let ticket = UUID()
        generation = ticket
        isRefreshing = true
        modelsError = nil
        defer { if generation == ticket { isRefreshing = false } }
        do {
            let fetched: [AIModelOption]
            if selected == .chatGPT {
                fetched = try await CodexConnection.shared.availableModels()
            } else {
                guard let key = OpenAICredentials.read(), !key.isEmpty, !key.contains("\n"), !key.contains("\r") else {
                    throw TextAIError.message("Save your OpenAI API key to discover models.")
                }
                var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
                request.timeoutInterval = 30
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw TextAIError.message("Couldn't fetch models. Check your key and connection, then refresh.")
                }
                fetched = try Self.apiModels(data)
            }
            guard generation == ticket, AIProvider.selected == selected else { return }
            guard !fetched.isEmpty else { throw TextAIError.message("No text models were returned. Try refreshing.") }
            models = fetched
            let key = Self.selectionKey(selected)
            let saved = UserDefaults.standard.string(forKey: key)
            if !fetched.contains(where: { $0.id == saved }) {
                let preferred = fetched.first(where: { $0.isDefault }) ?? fetched.first(where: { $0.id == "gpt-5.4-mini" }) ?? fetched[0]
                UserDefaults.standard.set(preferred.id, forKey: key)
            }
            refreshedAt = Date()
        } catch {
            guard generation == ticket else { return }
            modelsError = (error as? TextAIError)?.errorDescription ?? "Couldn't refresh models. Try again."
        }
        if selected == .chatGPT, generation == ticket {
            do {
                let result = try await CodexConnection.shared.readRateLimits()
                guard generation == ticket, AIProvider.selected == selected else { return }
                windows = AIUsageWindow.parse(result)
                usageError = windows.isEmpty ? "Your account hasn't returned an allowance yet." : nil
            } catch {
                guard generation == ticket else { return }
                windows = []
                usageError = "Allowance unavailable. Refresh to try again."
            }
        }
    }

    func updateLimits(_ result: [String: Any]) {
        guard AIProvider.selected == .chatGPT else { return }
        windows = AIUsageWindow.parse(result)
        usageError = windows.isEmpty ? "Your account hasn't returned an allowance yet." : nil
    }

    static func apiModels(_ data: Data) throws -> [AIModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else {
            throw TextAIError.message("OpenAI returned an unexpected model list.")
        }
        // /models exposes IDs, not endpoint capabilities. Exclude recognizable
        // non-text families; actual Responses access is still checked on send.
        let excluded = ["audio", "realtime", "transcrib", "tts", "image", "search", "deep-research", "computer-use", "instruct", "chat-latest"]
        let ids = Set(items.compactMap { $0["id"] as? String }.filter { id in
            let family = id.hasPrefix("gpt-") || id.range(of: "^o[0-9]", options: .regularExpression) != nil
            return family && !excluded.contains(where: { id.contains($0) })
        })
        return ids.sorted().map { AIModelOption(id: $0, title: $0) }
    }
}
