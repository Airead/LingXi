import Foundation

@MainActor
protocol PluginAwareModule {
    func afterPluginsLoaded() async
}
