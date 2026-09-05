import SwiftUI
import WebKit
import AVFoundation

class ClickThroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point)
    }
    
    override func mouseDown(with event: NSEvent) {
        self.nextResponder?.mouseDown(with: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        self.nextResponder?.mouseDragged(with: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        self.nextResponder?.mouseUp(with: event)
    }
}

class PenguinStateModel: ObservableObject {
    @Published var currentState: PenguinState = .thinking
    @Published var isLiveSessionActive = false
    @Published var latestTranscript: String = "Click me to start!"
    
    private var jumpingTimer: Timer?
    private var speakingStopWork: DispatchWorkItem?
    
    private let geminiLive = GeminiLiveWebSocketClient()
    private let audioService = AudioService.shared
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        geminiLive.onAudioReceived = { [weak self] pcmData in
            self?.audioService.playIncomingAudio(data: pcmData)
        }
        
        geminiLive.onTextReceived = { [weak self] text in
            DispatchQueue.main.async {
                self?.latestTranscript = "AI: \(text)"
            }
        }
        
        audioService.onAudioCaptured = { [weak self] pcmData in
            guard self?.isLiveSessionActive == true else { return }
            self?.geminiLive.sendAudio(pcmData: pcmData)
        }
        
        geminiLive.onModelSpeakingChanged = { [weak self] isSpeaking in
            DispatchQueue.main.async {
                self?.speakingStopWork?.cancel()
                if isSpeaking {
                    if self?.currentState != .jumping {
                        self?.currentState = .speaking
                    }
                } else {
                    let work = DispatchWorkItem { [weak self] in
                        if self?.currentState == .speaking {
                            self?.currentState = .thinking
                        }
                    }
                    self?.speakingStopWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                }
            }
        }
    }
    
    private func requestMicPermissionIfNeeded() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.audioService.restartEngineWithMic()
                    }
                }
            }
        } else if status == .authorized && !audioService.isRecording {
            audioService.restartEngineWithMic()
        } else if status == .denied || status == .restricted {
            DispatchQueue.main.async { [weak self] in
                self?.latestTranscript = "Mic denied. Open System Settings > Privacy > Microphone."
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    private func startLiveSession() {
        guard let apiKey = VoiceCredentials.read(), !apiKey.isEmpty else {
            latestTranscript = "Add your Gemini API key in Settings to enable voice."
            SettingsWindowController.shared.showSettings()
            return
        }
        
        isLiveSessionActive = true
        latestTranscript = "Connecting to Gemini..."
        
        geminiLive.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.isLiveSessionActive = false
                self?.currentState = .thinking
                self?.latestTranscript = "Session ended. Click me to restart!"
                self?.audioService.stopRecording()
            }
        }
        
        geminiLive.connect(apiKey: apiKey)
        audioService.checkPermissionsAndStart()
        
        jump()
    }
    
    func stop() {
        isLiveSessionActive = false
        latestTranscript = "Click me to start!"
        geminiLive.disconnect()
        audioService.stopRecording()
        currentState = .thinking
    }
    
    /// Called on single click: start session if not active, or flip + send context if active
    func handleClick() {
        if isLiveSessionActive {
            flipAndNotifyAI()
        } else {
            startLiveSession()
        }
    }
    
    /// Called on double click: always flip
    func handleDoubleClick() {
        if isLiveSessionActive {
            flipAndNotifyAI()
        } else {
            jump()
        }
    }
    
    private func flipAndNotifyAI() {
        jump()
        geminiLive.sendTextContext("The user just flipped you! React to it playfully.")
    }
    
    func jump() {
        jumpingTimer?.invalidate()
        currentState = .jumping
        jumpingTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            if self?.currentState == .jumping {
                self?.currentState = .thinking
            }
        }
    }
}

struct SVGWebView: NSViewRepresentable {
    let svgName: String
    var colorTheme: PenguinColorTheme?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var pendingTheme: PenguinColorTheme?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let theme = pendingTheme {
                injectThemeColors(webView: webView, theme: theme)
            }
        }

        func injectThemeColors(webView: WKWebView, theme: PenguinColorTheme) {
            let js = """
            (function() {
                function setStop(gradId, idx, color) {
                    var el = document.getElementById(gradId);
                    if (el && el.children[idx]) el.children[idx].setAttribute('stop-color', color);
                }
                setStop('bodyGrad', 0, '\(theme.light)');
                setStop('bodyGrad', 1, '\(theme.mid)');
                setStop('bodyGrad', 2, '\(theme.dark)');
                setStop('flipperLeftGrad', 0, '\(theme.mid)');
                setStop('flipperLeftGrad', 1, '\(theme.dark)');
                setStop('flipperRightGrad', 0, '\(theme.mid)');
                setStop('flipperRightGrad', 1, '\(theme.dark)');
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = ClickThroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator

        let script = WKUserScript(source: "document.documentElement.style.webkitUserSelect='none';", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingTheme = colorTheme

        if let url = Bundle.main.url(forResource: svgName, withExtension: "svg", subdirectory: "Resources") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

    }
}

enum PenguinState {
    case thinking
    case speaking
    case jumping
}

struct PenguinView: View {
    @ObservedObject var state: PenguinStateModel
    @ObservedObject private var customization = PenguinCustomization.shared
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                SVGWebView(svgName: "club_penguin_pseudo3d", colorTheme: customization.colorTheme)
                    .frame(width: 350, height: 350)
                    .scaleEffect(150.0/350.0)
                    .frame(width: 150, height: 150)
                    .opacity(state.currentState == .thinking ? 1 : 0)
                    
                SVGWebView(svgName: "club_penguin_pseudo3d_speaking", colorTheme: customization.colorTheme)
                    .frame(width: 350, height: 350)
                    .scaleEffect(150.0/350.0)
                    .frame(width: 150, height: 150)
                    .opacity(state.currentState == .speaking ? 1 : 0)
                    
                SVGWebView(svgName: "club_penguin_jump_spin", colorTheme: customization.colorTheme)
                    .frame(width: 350, height: 350)
                    .scaleEffect(150.0/350.0)
                    .frame(width: 150, height: 150)
                    .opacity(state.currentState == .jumping ? 1 : 0)
                
                if state.isLiveSessionActive {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button(action: { state.stop() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                                    .shadow(color: .black.opacity(0.5), radius: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                        }
                    }
                    .frame(width: 150, height: 150)
                }
            }
            
            if !state.latestTranscript.isEmpty {
                Text(state.latestTranscript)
                    .font(.caption)
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 250)
            }
        }
    }
}
