import AppKit
import Foundation

/// Singleton manager for plugin WebView windows.
/// Ensures only one plugin WebView is open at a time.
@MainActor
final class PluginWebViewManager {
    static let shared = PluginWebViewManager()
    
    private var currentWindow: PluginWebViewWindow?
    
    private init() {}
    
    /// Open a WebView window with the given HTML file.
    /// Closes any existing plugin WebView first.
    func open(
        htmlPath: String,
        title: String? = nil,
        width: CGFloat = 900,
        height: CGFloat = 700,
        onMessage: @escaping (String) -> Void
    ) {
        close()
        
        let window = PluginWebViewWindow(
            htmlPath: htmlPath,
            title: title,
            width: width,
            height: height
        )
        window.onMessageReceived = onMessage
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        currentWindow = window
        DebugLog.log("[PluginWebViewManager] Opened WebView: \(htmlPath)")
    }
    
    /// Close the current plugin WebView window.
    func close() {
        guard let window = currentWindow else { return }
        window.close()
        currentWindow = nil
        DebugLog.log("[PluginWebViewManager] Closed WebView")
    }
    
    /// Send a JSON string message to the current WebView's JS side.
    func sendMessage(_ jsonString: String) {
        guard let window = currentWindow else {
            DebugLog.log("[PluginWebViewManager] No WebView open to send message")
            return
        }
        window.sendMessage(jsonString)
    }
    
    /// Returns whether a plugin WebView is currently open.
    var isOpen: Bool {
        currentWindow != nil
    }
}
