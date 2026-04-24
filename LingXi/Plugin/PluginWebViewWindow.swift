import AppKit
import WebKit
import Foundation

/// A single WKWebView window for plugin content.
/// Injects `window.lingxi` JS bridge for bidirectional communication.
@MainActor
final class PluginWebViewWindow: NSWindow {
    private var webView: WKWebView!
    private let htmlPath: String
    
    /// Called when JS sends a message via `window.lingxi.postMessage()`.
    var onMessageReceived: ((String) -> Void)?
    
    init(htmlPath: String, title: String?, width: CGFloat, height: CGFloat) {
        self.htmlPath = htmlPath
        
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        self.title = title ?? "Plugin View"
        self.minSize = NSSize(width: 400, height: 300)
        
        setupWebView()
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        
        // Inject JS bridge before document starts
        let bridgeScript = WKUserScript(
            source: PluginWebViewWindow.jsBridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)
        
        // Register message handler
        config.userContentController.add(self, name: "lingxi")
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        
        contentView?.addSubview(webView)
        
        if let contentView = contentView {
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                webView.topAnchor.constraint(equalTo: contentView.topAnchor),
                webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        
        loadHTML()
    }
    
    private func loadHTML() {
        let url = URL(fileURLWithPath: htmlPath)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    
    /// Send a JSON string message to the JS side via `window.onLingXiMessage()`.
    func sendMessage(_ jsonString: String) {
        let escaped = jsonString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        
        let script = "if (typeof window.onLingXiMessage === 'function') { window.onLingXiMessage('\(escaped)'); }"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                DebugLog.log("[PluginWebViewWindow] JS eval error: \(error)")
            }
        }
    }
    
    // MARK: - JS Bridge Source
    
    private static var jsBridgeSource: String {
        """
        window.lingxi = {
            postMessage: function(data) {
                if (typeof data === 'object') {
                    data = JSON.stringify(data);
                }
                window.webkit.messageHandlers.lingxi.postMessage(data);
            }
        };
        """
    }
}

// MARK: - WKScriptMessageHandler

extension PluginWebViewWindow: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "lingxi" else { return }
        guard let body = message.body as? String else { return }
        onMessageReceived?(body)
    }
}

// MARK: - WKNavigationDelegate

extension PluginWebViewWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.log("[PluginWebViewWindow] Loaded: \(htmlPath)")
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.log("[PluginWebViewWindow] Failed to load: \(error)")
    }
}
