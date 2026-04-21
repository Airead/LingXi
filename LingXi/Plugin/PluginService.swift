import Foundation

protocol PluginService: Sendable {
    func dispatchEvent(name: String, data: [String: String]) async
}
