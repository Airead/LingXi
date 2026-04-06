import AppKit
import Foundation

/// Coordinates the leader key feature: loads configuration, manages the
/// CGEventTap monitor, shows/hides the HUD panel, and executes actions.
@MainActor
final class LeaderKeyManager {

    private let monitor = LeaderKeyMonitor()
    private let panel = LeaderKeyPanel()

    init() {
        monitor.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        let loaded = LeaderKeyConfigLoader.load()
        var configs = [String: LeaderConfig]()
        for config in loaded { configs[config.triggerKey] = config }
        guard !configs.isEmpty else { return }
        monitor.updateConfigs(configs)
        monitor.start()
    }

    func stop() {
        monitor.stop()
        closePanel()
    }

    func suppress() {
        monitor.suppress()
    }

    func resume() {
        monitor.resume()
    }

    // MARK: - Panel

    private func showPanel(for config: LeaderConfig) {
        panel.show(
            triggerKey: config.triggerKey,
            mappings: config.mappings,
            position: config.position
        )
    }

    private func closePanel() {
        if panel.isVisible { panel.close() }
    }

    // MARK: - Action execution

    private func executeMapping(_ mapping: LeaderMapping) {
        closePanel()
        if let app = mapping.app {
            launchApp(app)
        } else if let exec = mapping.exec {
            executeShellCommand(exec)
        }
    }

    private func launchApp(_ nameOrPath: String) {
        Task { @concurrent in
            if nameOrPath.hasSuffix(".app") {
                let url = URL(fileURLWithPath: nameOrPath)
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            } else {
                // Handles both app names ("WeChat") and non-.app paths
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", nameOrPath]
                do {
                    try process.run()
                } catch {
                    print("LeaderKeyManager: failed to launch \(nameOrPath): \(error)")
                }
            }
        }
    }

    private func executeShellCommand(_ command: String) {
        Task { @concurrent in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                print("LeaderKeyManager: failed to execute command: \(error)")
            }
        }
    }
}

// MARK: - LeaderKeyMonitorDelegate

extension LeaderKeyManager: LeaderKeyMonitorDelegate {
    func leaderMonitorDidActivate(_ config: LeaderConfig) {
        showPanel(for: config)
    }

    func leaderMonitorDidDeactivate() {
        closePanel()
    }

    func leaderMonitorDidMatch(_ mapping: LeaderMapping) {
        executeMapping(mapping)
    }
}
