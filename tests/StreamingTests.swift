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
        defer { UserDefaults.standard.removeObject(forKey: "textAIProvider") }
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
        print("Text AI tests passed: response parsing, errors, privacy, cancellation, provider off, Codex handshake.")
    }
}
