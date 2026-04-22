import Foundation
import AppKit

/// Exposes panel-level operations to `SearchProviderModule`s so they can
/// interact with the system clipboard and window focus without knowing about
/// `PanelManager` directly.
@MainActor
protocol PanelContext: AnyObject {
    /// The application that was active before the panel was shown.
    var previousApp: NSRunningApplication? { get }

    /// Paste the current pasteboard content and re-activate the target app.
    func pasteAndActivate(target: NSRunningApplication?)

    /// Hide the search panel.
    func hidePanel()

    /// Paste text to the previous application.
    /// This hides the panel, activates the previous app, and simulates paste.
    func pasteText(_ text: String)
}
