import AppKit
import Foundation

// Compile the real AI service in isolation; no UI or network calls are made.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func showSettings() {}
}

@main
struct StreamingTests {
    static func main() {
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "https://example.invalid/ai")!
        let task = session.dataTask(with: url)
        let expected = "Καλημέρα 🐧"
        let event = "data: {\"choices\":[{\"delta\":{\"content\":\"\(expected)\"}}]}\r\n\r\ndata: [DONE]\n"
        // Every possible split verifies partial JSON and partial UTF-8 code points.
        let bytes = Data(event.utf8)
        for split in 0...bytes.count {
            var result = ""
            var finished = false
            let delegate = StreamingDelegate(onChunk: { result += $0 }, onComplete: { error in
                precondition(error == nil)
                finished = true
            })
            delegate.urlSession(session, dataTask: task, didReceive: Data(bytes.prefix(split)))
            delegate.urlSession(session, dataTask: task, didReceive: Data(bytes.dropFirst(split)))
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
            precondition(result == expected, "Lost data at byte split \(split)")
            precondition(finished)
        }
        var receivedError: Error?
        let failed = StreamingDelegate(onChunk: { _ in preconditionFailure("Error response emitted text") }, onComplete: { receivedError = $0 })
        let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
        failed.urlSession(session, dataTask: task, didReceive: response) { _ in }
        failed.urlSession(session, dataTask: task, didReceive: bytes)
        failed.urlSession(session, task: task, didCompleteWithError: nil)
        precondition((receivedError as NSError?)?.code == 503)
        var rateLimited = false
        let limited = StreamingDelegate(onChunk: { _ in preconditionFailure() }, onComplete: { _ in }, onRateLimited: { rateLimited = $0 == "Try tomorrow" })
        limited.urlSession(session, dataTask: task, didReceive: HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil)!) { _ in }
        limited.urlSession(session, dataTask: task, didReceive: Data("{\"error\":\"Try tomorrow\"}".utf8))
        limited.urlSession(session, task: task, didCompleteWithError: nil)
        precondition(rateLimited)
        session.invalidateAndCancel()
        print("Streaming passed: all \(bytes.count + 1) byte boundaries, UTF-8, HTTP errors, and rate limits.")
    }
}
