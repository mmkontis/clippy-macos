import AppKit
import Foundation
import IOKit

/// Service for streaming AI chat completions
class AIChatService: ObservableObject {
    static let shared = AIChatService()

    private let apiURL = "https://humanlike-node-production.up.railway.app/ai/chat"

    @Published var isStreaming = false
    @Published var error: String?
    @Published var streamedText: String = ""
    @Published var rateLimitError: String?
    @Published var lastPrompt: String = ""

    /// Call this immediately when user submits to show spinner right away
    func prepareForStreaming() {
        DispatchQueue.main.async {
            self.isStreaming = true
            self.error = nil
            self.streamedText = ""
            self.rateLimitError = nil
        }
    }

    private var currentSession: URLSession?
    private var currentTask: URLSessionDataTask?

    // Queue for serializing paste operations
    private let pasteQueue = DispatchQueue(label: "com.clippy.paste", qos: .userInteractive)
    private var pendingChunks: [String] = []
    private var isPasting = false
    private var isFirstChunk = true

    private init() {}

    // MARK: - Device ID

    /// Gets or generates a persistent device ID for rate limiting
    private func getDeviceID() -> String {
        let key = "ClippyDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        // Generate a new UUID for testing (bypassing hardware UUID)
        let deviceID = UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: key)
        return deviceID
    }

    /// Gets the Mac's hardware UUID
    private func getHardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0 else { return nil }

        guard
            let uuidCF = IORegistryEntryCreateCFProperty(
                platformExpert,
                kIOPlatformUUIDKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String
        else {
            return nil
        }

        return uuidCF
    }

    /// Sends a message and streams the response by pasting each chunk as it arrives
    func sendMessageAndStream(_ message: String, onComplete: @escaping () -> Void) {
        // Cancel any existing request.
        cancel()
        guard UserDefaults.standard.bool(forKey: "cloudAIEnabled") else {
            DispatchQueue.main.async {
                self.isStreaming = false
                self.error = "Enable optional AI paste in Settings to send prompts to Humanlike."
                SettingsWindowController.shared.showSettings()
                onComplete()
            }
            return
        }

        // Reset state
        pendingChunks = []
        isPasting = false
        isFirstChunk = true

        DispatchQueue.main.async {
            self.isStreaming = true
            self.error = nil
            self.streamedText = ""
            self.lastPrompt = message
        }

        guard let url = URL(string: apiURL) else {
            DispatchQueue.main.async {
                self.error = "Invalid URL"
                self.isStreaming = false
                onComplete()
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getDeviceID(), forHTTPHeaderField: "X-Device-ID")

        let body: [String: Any] = [
            "messages": [
                ["role": "user", "content": message]
            ],
            "stream": true,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DispatchQueue.main.async {
                self.error = "Failed to encode request"
                self.isStreaming = false
                onComplete()
            }
            return
        }

        // Use URLSession with delegate for streaming
        let delegate = StreamingDelegate(
            onChunk: { [weak self] text in
                self?.queueChunkForPasting(text)
            },
            onComplete: { [weak self] error in
                DispatchQueue.main.async {
                    self?.isStreaming = false
                    if let error = error {
                        self?.error = error.localizedDescription
                    }
                    onComplete()
                }
            },
            onRateLimited: { [weak self] errorMessage in
                DispatchQueue.main.async {
                    self?.isStreaming = false
                    self?.rateLimitError = errorMessage
                }
            }
        )

        currentSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        currentTask = currentSession?.dataTask(with: request)
        currentTask?.resume()
    }

    /// Cancels the current streaming request
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        currentSession?.invalidateAndCancel()
        currentSession = nil
        pendingChunks = []
        isPasting = false
        DispatchQueue.main.async {
            self.isStreaming = false
        }
    }

    /// Queue a chunk for pasting - processes chunks one at a time
    private func queueChunkForPasting(_ text: String) {
        // Update streamed text for display in panel
        DispatchQueue.main.async {
            self.streamedText += text
        }

        pasteQueue.async { [weak self] in
            self?.pendingChunks.append(text)
            self?.processNextChunk()
        }
    }

    /// Process the next chunk in the queue
    private func processNextChunk() {
        pasteQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isPasting else { return }
            guard !self.pendingChunks.isEmpty else { return }

            self.isPasting = true
            let chunk = self.pendingChunks.removeFirst()

            // Paste this chunk
            DispatchQueue.main.async {
                self.pasteText(chunk) {
                    self.pasteQueue.async {
                        self.isPasting = false
                        // Process next chunk if any
                        if !self.pendingChunks.isEmpty {
                            self.processNextChunk()
                        }
                    }
                }
            }
        }
    }

    /// Pastes text by putting it on clipboard and simulating Cmd+V
    private func pasteText(_ text: String, completion: @escaping () -> Void) {
        let wasFirst = isFirstChunk
        isFirstChunk = false

        // For first chunk: click to ensure focus, wait, then set clipboard and paste
        // For subsequent chunks: just set clipboard and paste quickly
        if wasFirst {
            // First chunk: simulate a click to ensure the target app has keyboard focus
            simulateClick()

            // Wait for click to register, then set clipboard and paste
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.15) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)

                // Additional delay after setting clipboard for first paste
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.2) {
                    self.simulatePaste()
                    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.1) {
                        completion()
                    }
                }
            }
        } else {
            // Subsequent chunks: quick paste
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.02) {
                self.simulatePaste()
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) {
                    completion()
                }
            }
        }
    }

    /// Simulates a mouse click at the current cursor position to ensure focus
    private func simulateClick() {
        #if APP_STORE
        return
        #endif
        let mouseLocation = NSEvent.mouseLocation
        // Convert to screen coordinates (flip Y)
        guard let screen = NSScreen.main else { return }
        let screenHeight = screen.frame.height
        let clickPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        let source = CGEventSource(stateID: .combinedSessionState)
        if let mouseDown = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint,
            mouseButton: .left)
        {
            mouseDown.post(tap: .cghidEventTap)
        }
        if let mouseUp = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint,
            mouseButton: .left)
        {
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    /// Simulates Cmd+V keystroke
    private func simulatePaste() {
        #if APP_STORE
        return
        #endif
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0.0

        // V key = 0x09
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Streaming Delegate

class StreamingDelegate: NSObject, URLSessionDataDelegate {
    let onChunk: (String) -> Void
    let onComplete: (Error?) -> Void
    let onRateLimited: ((String) -> Void)?
    private var buffer = Data()
    private var responseError: Error?
    private var isRateLimited = false
    private var rateLimitBody = Data()

    init(
        onChunk: @escaping (String) -> Void, onComplete: @escaping (Error?) -> Void,
        onRateLimited: ((String) -> Void)? = nil
    ) {
        self.onChunk = onChunk
        self.onComplete = onComplete
        self.onRateLimited = onRateLimited
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 429 {
                isRateLimited = true
            } else if !(200..<300).contains(httpResponse.statusCode) {
                responseError = NSError(domain: "ClippyAI", code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "AI service returned HTTP \(httpResponse.statusCode). Please try again later."])
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // If rate limited, collect the error response body
        if isRateLimited {
            rateLimitBody.append(data)
            return
        }

        guard responseError == nil else { return }
        // Keep bytes until a complete line arrives, including split UTF-8 characters.
        buffer.append(data)
        processBuffer()
    }

    private func processBuffer(final: Bool = false) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            processLine(line)
        }
        if final && !buffer.isEmpty {
            processLine(buffer)
            buffer.removeAll()
        }
    }

    private func processLine(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8), line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload != "[DONE]", let jsonData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return }
        onChunk(content)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        // Handle rate limit response
        if isRateLimited {
            var errorMessage = "Daily limit reached (10 requests/day)"
            if let json = try? JSONSerialization.jsonObject(with: rateLimitBody) as? [String: Any],
                let serverError = json["error"] as? String
            {
                errorMessage = serverError
            }
            onRateLimited?(errorMessage)
            onComplete(nil)
            return
        }

        // Process any remaining buffer
        if error == nil && responseError == nil {
            processBuffer(final: true)
        }
        onComplete(error ?? responseError)
    }
}
