import Foundation

enum PluginStatus: String, Sendable {
    case notInstalled = "not_installed"
    case installed = "installed"
    case updateAvailable = "update_available"
    case manuallyPlaced = "manually_placed"
    case disabled = "disabled"
}
