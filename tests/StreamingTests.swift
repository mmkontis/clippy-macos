import AppKit
import Foundation

// Standalone harness: never reads the real Keychain or opens the app's settings.
enum OpenAICredentials { static func read() -> String? { "test-only-key" } }
@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func showSettings() {}
}

final class DelayedResponse: URLProtocol {
    nonisolated(unsafe) static var calls = 0
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        let index = Self.calls
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let data = Data("""
            {"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"answer \(index)"}]}]}
            """.utf8)
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = job
        DispatchQueue.global().asyncAfter(deadline: .now() + (index == 1 ? 0.3 : 0.03), execute: job)
    }
    override func stopLoading() { work?.cancel() }
}

final class ModelResponse: URLProtocol {
    nonisolated(unsafe) static var calls = 0
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        precondition(request.url?.path == "/v1/models")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key")
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let data = Data(#"{"data":[{"id":"gpt-5.4-mini"},{"id":"gpt-5.4"}]}"#.utf8)
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = job
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08, execute: job)
    }
    override func stopLoading() { work?.cancel() }
}

@main
struct TextAITests {
    @MainActor static func main() async throws {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = Data("""
        {"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"Γεια σου 👋"},{"type":"output_text","text":"Next"}]}]}
        """.utf8)
        let answer = try AIChatService.apiAnswer(data: body, response: response)
        precondition(answer == "Γεια σου 👋\nNext")
        let request = try AIChatService.apiRequest(prompt: "Only this prompt", key: "fake-secret", model: "gpt-5.4-mini")
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(json["input"] as? String == "Only this prompt")
        precondition(json["store"] as? Bool == false)
        precondition(request.url == url)
        precondition(!String(data: request.httpBody!, encoding: .utf8)!.contains("fake-secret"))
        precondition(request.value(forHTTPHeaderField: "X-Device-ID") == nil)
        for status in [401, 403, 429, 500] {
            do {
                _ = try AIChatService.apiAnswer(data: Data("private provider detail".utf8),
                    response: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
                preconditionFailure("HTTP failure treated as success")
            } catch { precondition(!error.localizedDescription.contains("private provider detail")) }
        }
        do {
            _ = try AIChatService.apiAnswer(data: Data(#"{"status":"incomplete","output":[]}"#.utf8), response: response)
            preconditionFailure("Incomplete answer treated as complete")
        } catch {}
        let refusal = try AIChatService.apiAnswer(data: Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"I cannot help with that."}]}]}"#.utf8), response: response)
        precondition(refusal == "I cannot help with that.")

        UserDefaults.standard.set("openAI", forKey: "textAIProvider")
        defer {
            for key in ["textAIProvider", "openAITextModel"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        let models = try AIModelCatalog.apiModels(Data(#"{"data":[{"id":"gpt-5.4-mini"},{"id":"gpt-5.4-mini"},{"id":"o3"},{"id":"gpt-realtime"},{"id":"gpt-image-1"},{"id":"whisper-1"},{"id":"gpt-4o-transcribe"}]}"#.utf8))
        precondition(models.map(\.id) == ["gpt-5.4-mini", "o3"])
        do {
            _ = try AIModelCatalog.apiModels(Data(#"{"error":"private detail"}"#.utf8))
            preconditionFailure("Invalid model response accepted")
        } catch { precondition(!error.localizedDescription.contains("private detail")) }
        let usage = TextTokenUsage.api(Data(#"{"model":"gpt-actual","usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":40}}}"#.utf8), model: "requested")!
        precondition(usage.model == "gpt-actual" && usage.total == 120 && usage.cached == 40)
        precondition(TextTokenUsage.api(body, model: "requested") == nil)
        let limits = AIUsageWindow.parse([
            "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 23, "windowDurationMins": 300, "resetsAt": 1_800_000_000], "secondary": NSNull()],
                                   "extra": ["limitName": "Extra", "primary": ["usedPercent": 0]]]])
        precondition(limits.count == 2 && limits[0].usedPercent == 23)
        precondition(limits[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        precondition(limits[1].resetsAt == nil && limits[1].usedPercent == 0)
        precondition(AIUsageWindow.parse([:]).isEmpty)
        precondition(AIUsageWindow.parse(["rateLimits": ["primary": ["usedPercent": 50]]]).count == 1)

        let modelConfig = URLSessionConfiguration.ephemeral
        modelConfig.protocolClasses = [ModelResponse.self]
        let catalog = AIModelCatalog(session: URLSession(configuration: modelConfig))
        UserDefaults.standard.set("gpt-5.4", forKey: "openAITextModel")
        await catalog.refresh()
        precondition(catalog.models.count == 2 && catalog.refreshedAt != nil)
        precondition(UserDefaults.standard.string(forKey: "openAITextModel") == "gpt-5.4", "Saved selection lost")
        UserDefaults.standard.set("removed-model", forKey: "openAITextModel")
        await catalog.refresh()
        precondition(UserDefaults.standard.string(forKey: "openAITextModel") == "gpt-5.4-mini", "Unavailable selection not replaced")
        catalog.invalidate()
        let stale = Task { await catalog.refresh() }
        try await Task.sleep(nanoseconds: 20_000_000)
        UserDefaults.standard.set("none", forKey: "textAIProvider")
        await catalog.refresh()
        await stale.value
        precondition(catalog.models.isEmpty && !catalog.isRefreshing, "Previous account result leaked after provider switch")
        let calls = ModelResponse.calls
        await catalog.refresh()
        precondition(ModelResponse.calls == calls, "Discovery made a network call while off")
        UserDefaults.standard.set("openAI", forKey: "textAIProvider")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedResponse.self]
        let service = AIChatService(session: URLSession(configuration: config))
        service.sendMessageAndStream("old") {}
        try await Task.sleep(nanoseconds: 70_000_000)
        service.sendMessageAndStream("new") {}
        try await Task.sleep(nanoseconds: 450_000_000)
        precondition(service.streamedText == "answer 2", "Stale request replaced newer answer")
        precondition(!service.isStreaming)
        service.clear()
        precondition(service.streamedText.isEmpty && service.lastPrompt.isEmpty)
        UserDefaults.standard.set("none", forKey: "textAIProvider")
        service.sendMessageAndStream("not sent") {}
        precondition(service.error != nil && DelayedResponse.calls == 2)

        if CommandLine.arguments.count > 1 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let bridge = CodexConnection(executableURL: URL(fileURLWithPath: CommandLine.arguments[1]), rootURL: root)
            await bridge.refreshAccount()
            precondition(!bridge.isConnected)
            precondition(bridge.status.hasPrefix("Connect your ChatGPT"), bridge.status)
            bridge.stop()
            try? FileManager.default.removeItem(at: root)
        }
        print("Text AI tests passed: response parsing, errors, privacy, cancellation, provider off, model discovery, selection, usage, account isolation, Codex handshake.")
    }
}
