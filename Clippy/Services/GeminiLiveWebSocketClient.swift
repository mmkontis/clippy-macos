import Foundation
import AppKit

// #region agent log helper
func writeGeminiDebugLog(_ message: String, data: [String: Any]? = nil) {
    // Do not persist transcripts, audio, session tokens, or provider responses.
}

// #endregion

/// Simple WebSocket client for Gemini Live API
class GeminiLiveWebSocketClient: NSObject, URLSessionWebSocketDelegate, ObservableObject {
    
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case ready
    }
    
    @Published var state: ConnectionState = .disconnected
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var storedApiKey: String?
    private var resumptionToken: String?
    private var intentionalDisconnect = false
    
    // Callbacks
    var onAudioReceived: ((Data) -> Void)?
    var onTextReceived: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onModelSpeakingChanged: ((Bool) -> Void)?
    
    func connect(apiKey: String) {
        // #region agent log
        writeGeminiDebugLog("WebSocket connect called", data: ["hypothesisId": "B", "hasResumptionToken": resumptionToken != nil])
        // #endregion
        guard state == .disconnected else { return }
        
        storedApiKey = apiKey
        intentionalDisconnect = false
        
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            // #region agent log
            writeGeminiDebugLog("Invalid URL string", data: ["hypothesisId": "B"])
            // #endregion
            return
        }
        
        state = .connecting
        
        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        webSocketTask = session?.webSocketTask(with: url)
        
        webSocketTask?.resume()
        receiveMessage()
    }
    
    func disconnect() {
        intentionalDisconnect = true
        resumptionToken = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session = nil
        DispatchQueue.main.async {
            self.state = .disconnected
        }
    }
    
    // Send initial configuration
    func sendSetup() {
        let custom = PenguinCustomization.shared
        let personalityBlock = custom.personalityPrompt

        let systemPrompt = """
You are a penguin assistant living on the user's desktop. \(personalityBlock)

RULES:
- NEVER repeat what the user just said back to them. Jump straight into your response.
- Keep it short and punchy. 1-3 sentences max unless they ask for detail.
- Always move the conversation forward — ask a cheeky follow-up or suggest something.
- Sound like a real character with personality, not a generic assistant.
\(custom.name.isEmpty ? "" : "- Your name is \(custom.name). Refer to yourself by name occasionally.")
"""
        
        var setup: [String: Any] = [
            "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
            "generationConfig": [
                "responseModalities": ["AUDIO"]
            ],
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contextWindowCompression": [
                "slidingWindow": [String: Any](),
                "triggerTokens": 8000
            ],
            "sessionResumption": [String: Any]()
        ]
        
        if let token = resumptionToken {
            setup["sessionResumption"] = ["handle": token]
            // #region agent log
            writeGeminiDebugLog("Resuming session with token", data: ["hypothesisId": "B", "tokenPrefix": String(token.prefix(20))])
            // #endregion
        }
        
        let setupMessage: [String: Any] = ["setup": setup]
        
        sendMessage(setupMessage)
        
        if resumptionToken == nil {
            let kickstart: [String: Any] = [
                "clientContent": [
                    "turns": [
                        [
                            "role": "user",
                            "parts": [
                                ["text": "Hey penguin, what's up?"]
                            ]
                        ]
                    ],
                    "turnComplete": true
                ]
            ]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendMessage(kickstart)
            }
        }
    }
    
    func sendTextContext(_ text: String) {
        guard state == .ready || state == .connected else { return }
        let message: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [["text": text]]
                    ]
                ],
                "turnComplete": true
            ]
        ]
        sendMessage(message)
    }
    
    func sendAudio(pcmData: Data) {
        guard state == .ready else { return }
        guard pcmData.count > 0 else { return }
        let base64String = pcmData.base64EncodedString()
        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": base64String
                    ]
                ]
            ]
        ]
        sendMessage(message)
    }
    
    private func sendMessage(_ dictionary: [String: Any]) {
        guard let task = webSocketTask else { return }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            if let string = String(data: data, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(string)
                task.send(message) { [weak self] error in
                    if let error = error {
                        // #region agent log
                        writeGeminiDebugLog("WebSocket Send Error", data: ["hypothesisId": "D", "error": error.localizedDescription])
                        // #endregion
                        self?.onError?(error)
                    }
                }
            }
        } catch {
            // #region agent log
            writeGeminiDebugLog("Failed to serialize message", data: ["hypothesisId": "D", "error": error.localizedDescription])
            // #endregion
        }
    }
    
    private func receiveMessage() {
        guard let task = webSocketTask else { return }
        
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    // #region agent log
                    writeGeminiDebugLog("Received WebSocket String", data: ["hypothesisId": "A,B", "length": text.count, "prefix": String(text.prefix(100))])
                    // #endregion
                    self?.handleIncomingText(text)
                case .data(let data):
                    // #region agent log
                    writeGeminiDebugLog("Received WebSocket Data", data: ["hypothesisId": "A,B", "bytes": data.count])
                    // #endregion
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleIncomingText(text)
                    }
                @unknown default:
                    break
                }
                // Keep listening
                self?.receiveMessage()
                
            case .failure(let error):
                print("Voice connection ended.")
                self?.onError?(error)
                self?.disconnect()
            }
        }
    }
    
    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let topKeys = Array(json.keys)
                // #region agent log
                writeGeminiDebugLog("Parsed JSON", data: ["hypothesisId": "E", "keys": topKeys.joined(separator: ",")])
                // #endregion
                
                if let serverContent = json["serverContent"] as? [String: Any] {
                    let scKeys = Array(serverContent.keys)
                    // #region agent log
                    writeGeminiDebugLog("serverContent keys", data: ["hypothesisId": "E", "keys": scKeys.joined(separator: ",")])
                    // #endregion
                    
                    if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                       let parts = modelTurn["parts"] as? [[String: Any]] {
                        
                        var hasAudio = false
                        for part in parts {
                            if let inlineData = part["inlineData"] as? [String: Any] {
                                let mimeType = inlineData["mimeType"] as? String ?? "unknown"
                                
                                if let base64String = inlineData["data"] as? String,
                                   let pcmData = Data(base64Encoded: base64String) {
                                    // #region agent log
                                    writeGeminiDebugLog("Decoded audio", data: ["hypothesisId": "E", "mimeType": mimeType, "pcmBytes": pcmData.count])
                                    // #endregion
                                    hasAudio = true
                                    self.onAudioReceived?(pcmData)
                                } else {
                                    // #region agent log
                                    writeGeminiDebugLog("Failed to decode inlineData", data: ["hypothesisId": "E", "mimeType": mimeType])
                                    // #endregion
                                }
                            }
                            
                            if let textPart = part["text"] as? String {
                                // #region agent log
                                writeGeminiDebugLog("Got text from AI", data: ["hypothesisId": "E", "text": String(textPart.prefix(80))])
                                // #endregion
                                DispatchQueue.main.async {
                                    self.onTextReceived?(textPart)
                                }
                            }
                        }
                        
                        if hasAudio {
                            DispatchQueue.main.async {
                                self.onModelSpeakingChanged?(true)
                            }
                        }
                    }
                    
                    if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                        // #region agent log
                        writeGeminiDebugLog("Turn complete received", data: ["hypothesisId": "E"])
                        // #endregion
                        DispatchQueue.main.async {
                            self.onModelSpeakingChanged?(false)
                        }
                    }
                    
                    if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
                        // #region agent log
                        writeGeminiDebugLog("Model interrupted", data: ["hypothesisId": "E"])
                        // #endregion
                        DispatchQueue.main.async {
                            self.onModelSpeakingChanged?(false)
                        }
                    }
                }
                
                if json["setupComplete"] != nil {
                    // #region agent log
                    writeGeminiDebugLog("Setup complete received! Marking as READY", data: ["hypothesisId": "E"])
                    // #endregion
                    DispatchQueue.main.async {
                        self.state = .ready
                    }
                }
                
                if let update = json["sessionResumptionUpdate"] as? [String: Any],
                   let token = update["newHandle"] as? String, !token.isEmpty {
                    self.resumptionToken = token
                    // #region agent log
                    writeGeminiDebugLog("Got resumption token", data: ["hypothesisId": "B", "tokenPrefix": String(token.prefix(20))])
                    // #endregion
                }
                
                if json["goAway"] != nil {
                    // #region agent log
                    writeGeminiDebugLog("GoAway received, will auto-reconnect", data: ["hypothesisId": "B"])
                    // #endregion
                }
            }
        } catch {
            // #region agent log
            writeGeminiDebugLog("JSON parse error", data: ["hypothesisId": "E", "error": error.localizedDescription])
            // #endregion
        }
    }
    
    // MARK: - URLSessionWebSocketDelegate
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // #region agent log
        writeGeminiDebugLog("WebSocket Opened", data: ["hypothesisId": "B"])
        // #endregion
        DispatchQueue.main.async {
            self.state = .connected
        }
        sendSetup()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // #region agent log
        let reasonStr = reason != nil ? String(data: reason!, encoding: .utf8) ?? "unknown" : "nil"
        writeGeminiDebugLog("WebSocket Closed", data: ["hypothesisId": "B,D", "closeCode": closeCode.rawValue, "reason": reasonStr, "hasToken": resumptionToken != nil, "intentional": intentionalDisconnect])
        // #endregion
        
        self.webSocketTask = nil
        self.session = nil
        
        DispatchQueue.main.async {
            self.state = .disconnected
            
            if !self.intentionalDisconnect, self.resumptionToken != nil, let apiKey = self.storedApiKey {
                // #region agent log
                writeGeminiDebugLog("Auto-reconnecting with resumption token", data: ["hypothesisId": "B"])
                // #endregion
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.connect(apiKey: apiKey)
                }
            } else {
                self.onError?(NSError(domain: "GeminiLive", code: Int(closeCode.rawValue), userInfo: [NSLocalizedDescriptionKey: "Session ended"]))
            }
        }
    }
}