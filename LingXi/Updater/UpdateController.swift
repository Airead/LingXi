//
//  UpdateController.swift
//  LingXi
//
//  Periodically polls the GitHub Releases API and drives the auto-update flow.
//

import AppKit
import Foundation
import Observation

struct GitHubAsset: Sendable, Equatable {
    let name: String
    let downloadURL: String
}

struct GitHubReleaseData: Sendable, Equatable {
    let tagName: String
    let htmlURL: String
    let assets: [GitHubAsset]

    static func parse(from data: Data) throws -> GitHubReleaseData {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any] else {
            throw NSError(domain: "GitHubReleaseData", code: -1, userInfo: [NSLocalizedDescriptionKey: "not a JSON object"])
        }
        let tag = dict["tag_name"] as? String ?? ""
        let html = dict["html_url"] as? String ?? ""
        let assetsRaw = dict["assets"] as? [[String: Any]] ?? []
        let assets = assetsRaw.compactMap { d -> GitHubAsset? in
            guard let name = d["name"] as? String,
                  let url = d["browser_download_url"] as? String else { return nil }
            return GitHubAsset(name: name, downloadURL: url)
        }
        return GitHubReleaseData(tagName: tag, htmlURL: html, assets: assets)
    }
}

@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum State: Equatable {
        case idle
        case available(version: String)
        case downloading(message: String)
        case ready(version: String)
    }

    private(set) var state: State = .idle

    private let githubAPIURL = URL(string: "https://api.github.com/repos/Airead/LingXi/releases/latest")!
    private let intervalSeconds: TimeInterval = 6 * 3600
    private let requestTimeout: TimeInterval = 10

    private var releaseURL: URL?
    private var releaseData: GitHubReleaseData?
    private var updater: AppUpdater?
    private var checkTask: Task<Void, Never>?

    private let currentVersion: String

    private init() {
        self.currentVersion = Self.resolveCurrentVersion()
    }

    /// Resolve the running app's version, honoring `LINGXI_FAKE_CURRENT_VERSION`
    /// for end-to-end testing of the update flow against a lower fake version.
    nonisolated static func resolveCurrentVersion(
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundleVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    ) -> String {
        if let override = env["LINGXI_FAKE_CURRENT_VERSION"], !override.isEmpty {
            return override
        }
        return bundleVersion ?? "dev"
    }

    var isFrozen: Bool {
        if ProcessInfo.processInfo.environment["LINGXI_FORCE_AUTO_UPDATE"] == "1" { return true }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    func start() {
        if checkTask != nil { return }
        guard isFrozen else {
            DebugLog.log("[Updater] Skipping (dev mode)")
            return
        }
        if tryApplyStagedUpdate() { return }
        scheduleChecks()
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
        updater?.cancel()
        updater = nil
    }

    @discardableResult
    func tryApplyStagedUpdate() -> Bool {
        guard let staged = AppUpdater.getStagedAppPath() else { return false }

        do {
            try AppUpdater.verifyApp(staged)
        } catch {
            DebugLog.log("[Updater] Staged update failed verification: \(error)")
            AppUpdater.cleanupStagedApp()
            return false
        }

        guard let stagedVersion = AppUpdater.getAppVersion(staged) else {
            DebugLog.log("[Updater] Cannot read staged app version")
            AppUpdater.cleanupStagedApp()
            return false
        }

        if !Self.isNewer(stagedVersion, than: currentVersion) {
            DebugLog.log("[Updater] Staged \(stagedVersion) not newer than \(currentVersion)")
            AppUpdater.cleanupStagedApp()
            return false
        }

        let display = Self.normalizeDisplayVersion(stagedVersion)
        let confirmed = topmostAlert(
            title: "LingXi \(display) is ready to install",
            message: "Restart LingXi now to finish updating?",
            ok: "Restart Now",
            cancel: "Later"
        )
        if !confirmed { return false }

        if !AppUpdater.performSwapAndRelaunch() {
            DebugLog.log("[Updater] Swap script failed to spawn")
            AppUpdater.cleanupStagedApp()
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    private func scheduleChecks() {
        checkTask = Task { [weak self] in
            await self?.runCheckLoop()
        }
    }

    private func runCheckLoop() async {
        await performCheck()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            await performCheck()
        }
    }

    private func performCheck() async {
        guard currentVersion != "dev" else { return }
        guard let release = await fetchLatestRelease() else { return }

        if Self.isNewer(release.tagName, than: currentVersion) {
            DebugLog.log("[Updater] New version available: \(release.tagName) (current \(currentVersion))")
            self.releaseData = release
            self.releaseURL = URL(string: release.htmlURL)
            // Don't overwrite an in-flight download or staged-ready state.
            switch state {
            case .idle, .available:
                self.state = .available(version: Self.normalizeDisplayVersion(release.tagName))
            case .downloading, .ready:
                break
            }
        } else if case .available = state {
            self.state = .idle
        }
    }

    private func fetchLatestRelease() async -> GitHubReleaseData? {
        var req = URLRequest(url: githubAPIURL, timeoutInterval: requestTimeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LingXi-UpdateChecker", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try GitHubReleaseData.parse(from: data)
        } catch {
            DebugLog.log("[Updater] Update check failed: \(error)")
            return nil
        }
    }

    func handleMenuClick() {
        switch state {
        case .available:
            tryAutoUpdate()
        case .ready:
            confirmRestart()
        case .downloading, .idle:
            break
        }
    }

    private func tryAutoUpdate() {
        guard case .available = state,
              let release = releaseData,
              let dmgURL = Self.findDMGURL(release.assets) else {
            openReleaseInBrowser()
            return
        }
        let appURL = AppUpdater.getAppBundlePath()
        if !AppUpdater.isWritable(appURL) {
            _ = topmostAlert(
                title: "Cannot update LingXi automatically",
                message: "LingXi.app is not in a writable location: \(appURL.deletingLastPathComponent().path). Please move it to /Applications.",
                ok: "OK",
                cancel: nil
            )
            openReleaseInBrowser()
            return
        }
        let display = Self.normalizeDisplayVersion(release.tagName)
        let confirmed = topmostAlert(
            title: "LingXi \(display) is available",
            message: "Download and install now?",
            ok: "Install",
            cancel: "Cancel"
        )
        if !confirmed { return }
        startAutoUpdate(dmgURL: dmgURL, version: release.tagName)
    }

    private func startAutoUpdate(dmgURL: URL, version: String) {
        if updater != nil { return }
        state = .downloading(message: "Downloading update...")
        updater = AppUpdater(
            dmgURL: dmgURL,
            version: version,
            onProgress: { [weak self] msg in
                Task { @MainActor in self?.state = .downloading(message: msg) }
            },
            onError: { [weak self] msg in
                Task { @MainActor in self?.handleUpdaterError(msg) }
            },
            onReady: { [weak self] in
                Task { @MainActor in self?.handleUpdaterReady() }
            }
        )
        updater?.start()
    }

    private func handleUpdaterError(_ msg: String) {
        updater = nil
        if let release = releaseData {
            state = .available(version: Self.normalizeDisplayVersion(release.tagName))
        } else {
            state = .idle
        }
        let go = topmostAlert(
            title: "Update failed",
            message: msg,
            ok: "Open Browser",
            cancel: "Cancel"
        )
        if go { openReleaseInBrowser() }
    }

    private func handleUpdaterReady() {
        updater = nil
        guard let release = releaseData else { return }
        state = .ready(version: Self.normalizeDisplayVersion(release.tagName))
    }

    private func confirmRestart() {
        guard case .ready(let display) = state else { return }
        let confirmed = topmostAlert(
            title: "Restart LingXi to update to \(display)?",
            message: "LingXi will close and relaunch with the new version.",
            ok: "Restart Now",
            cancel: "Later"
        )
        if !confirmed { return }

        if !AppUpdater.performSwapAndRelaunch() {
            _ = topmostAlert(
                title: "Update failed",
                message: "Could not start the update. Please download manually.",
                ok: "OK",
                cancel: nil
            )
            openReleaseInBrowser()
            return
        }
        NSApp.terminate(nil)
    }

    private func openReleaseInBrowser() {
        if let url = releaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Pure helpers

    nonisolated static func parseVersion(_ s: String) -> [Int]? {
        var cleaned = s.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        if cleaned.isEmpty { return nil }
        var parts: [Int] = []
        for piece in cleaned.split(separator: ".") {
            guard let n = Int(piece) else { return nil }
            parts.append(n)
        }
        return parts.isEmpty ? nil : parts
    }

    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = parseVersion(latest), let c = parseVersion(current) else { return false }
        let len = max(l.count, c.count)
        for i in 0..<len {
            let x = i < l.count ? l[i] : 0
            let y = i < c.count ? c[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func findDMGURL(_ assets: [GitHubAsset]) -> URL? {
        for asset in assets where asset.name.hasSuffix(".dmg") {
            if let url = URL(string: asset.downloadURL) {
                return url
            }
        }
        return nil
    }

    nonisolated static func normalizeDisplayVersion(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return trimmed
        }
        return "v" + trimmed
    }
}

@MainActor
private func topmostAlert(title: String, message: String, ok: String, cancel: String?) -> Bool {
    let prevPolicy = NSApp.activationPolicy()
    if prevPolicy == .accessory {
        NSApp.setActivationPolicy(.regular)
    }
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: ok)
    if let cancel { alert.addButton(withTitle: cancel) }

    let response = alert.runModal()

    if prevPolicy == .accessory {
        NSApp.setActivationPolicy(.accessory)
    }
    return response == .alertFirstButtonReturn
}
