import SwiftUI
import WebKit

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
    @Published var latestTranscript = "Click me to ask Clippy."
    private var jumpingTimer: Timer?

    func stop() {
        jumpingTimer?.invalidate()
        currentState = .thinking
    }

    func handleClick() {
        Task { @MainActor in AppDelegate.shared?.showAIPanelNearCursor() }
    }

    func handleDoubleClick() { jump() }

    func jump() {
        jumpingTimer?.invalidate()
        currentState = .jumping
        jumpingTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            self?.currentState = .thinking
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
