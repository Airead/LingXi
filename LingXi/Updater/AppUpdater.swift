//
//  AppUpdater.swift
//  LingXi
//
//  Auto-update: download DMG from GitHub Releases, stage the new app bundle,
//  and perform swap + relaunch via a detached shell script.
//

import AppKit
import Foundation

enum UpdateError: Error, LocalizedError {
    case notWritable(String)
    case downloadFailed(String)
    case mountFailed(String)
    case appNotFoundInDMG
    case verificationFailed(String)
    case processTimedOut(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notWritable(let path):
            return "Cannot write to \(path). Please move LingXi.app to a writable location like /Applications."
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .mountFailed(let m): return "Failed to mount DMG: \(m)"
        case .appNotFoundInDMG: return "LingXi.app not found in DMG"
        case .verificationFailed(let m): return "Code signature verification failed: \(m)"
        case .processTimedOut(let cmd): return "Process timed out: \(cmd)"
        case .cancelled: return "Update cancelled"
        }
    }
}

nonisolated final class AppUpdater: @unchecked Sendable {
    static let appName = "LingXi"
    static let stagedAppName = ".LingXi-update.app"

    let dmgURL: URL
    let version: String
    private let onProgress: (@Sendable (String) -> Void)?
    private let onError: (@Sendable (String) -> Void)?
    private let onReady: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var _cancelled = false
    private var _task: Task<Void, Never>?

    init(
        dmgURL: URL,
        version: String,
        onProgress: (@Sendable (String) -> Void)? = nil,
        onError: (@Sendable (String) -> Void)? = nil,
        onReady: (@Sendable () -> Void)? = nil
    ) {
        self.dmgURL = dmgURL
        self.version = version
        self.onProgress = onProgress
        self.onError = onError
        self.onReady = onReady
    }

    private var cancelled: Bool { lock.withLock { _cancelled } }

    static func getAppBundlePath() -> URL {
        if let override = ProcessInfo.processInfo.environment["LINGXI_APP_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.bundleURL
    }

    static func isWritable(_ appURL: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    static func stagedPath(appURL: URL? = nil) -> URL {
        let app = appURL ?? getAppBundlePath()
        return app.deletingLastPathComponent().appendingPathComponent(stagedAppName)
    }

    static func getStagedAppPath(appURL: URL? = nil) -> URL? {
        let p = stagedPath(appURL: appURL)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue {
            return p
        }
        return nil
    }

    static func cleanupStagedApp(appURL: URL? = nil) {
        let p = stagedPath(appURL: appURL)
        guard FileManager.default.fileExists(atPath: p.path) else { return }
        do {
            try FileManager.default.removeItem(at: p)
            DebugLog.log("[Updater] Cleaned up leftover staged update")
        } catch {
            DebugLog.log("[Updater] Staged app cleanup failed: \(error)")
        }
    }

    static func getAppVersion(_ appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    func start() {
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run()
        }
        lock.withLock { _task = task }
    }

    func cancel() {
        lock.withLock {
            _cancelled = true
            _task?.cancel()
        }
    }

    private func run() async {
        let appURL = Self.getAppBundlePath()
        let stagedURL = Self.stagedPath(appURL: appURL)
        var tmpDir: URL?
        var mountPoint: URL?

        do {
            if !Self.isWritable(appURL) {
                throw UpdateError.notWritable(appURL.deletingLastPathComponent().path)
            }

            onProgress?("Downloading update...")
            let dir = try createTempDir()
            tmpDir = dir
            let dmgPath = dir.appendingPathComponent("LingXi-\(version).dmg")
            try await downloadDMG(to: dmgPath)
            if cancelled { throw UpdateError.cancelled }

            onProgress?("Preparing update...")
            let mp = try mountDMG(dmgPath)
            mountPoint = mp

            let newApp = try findAppInVolume(mp)

            onProgress?("Installing update...")
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.copyItem(at: newApp, to: stagedURL)

            onProgress?("Verifying update...")
            do {
                try Self.verifyApp(stagedURL)
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                throw error
            }

            try? unmountDMG(mp)
            mountPoint = nil
            try? FileManager.default.removeItem(at: dir)
            tmpDir = nil

            onReady?()
        } catch let err as UpdateError {
            DebugLog.log("[Updater] Update failed: \(err)")
            onError?(err.localizedDescription)
        } catch {
            DebugLog.log("[Updater] Update failed unexpectedly: \(error)")
            onError?("Unexpected error: \(error.localizedDescription)")
        }

        if let mp = mountPoint { try? unmountDMG(mp) }
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func createTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func downloadDMG(to dest: URL) async throws {
        var req = URLRequest(url: dmgURL, timeoutInterval: 60)
        req.setValue("LingXi-Updater", forHTTPHeaderField: "User-Agent")

        let progressCb = onProgress
        let delegate = ProgressDownloadDelegate { pct in
            progressCb?("Downloading... \(pct)%")
        }
        let (tmpURL, _) = try await URLSession.shared.download(for: req, delegate: delegate)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpURL, to: dest)
    }

    private func mountDMG(_ dmgPath: URL) throws -> URL {
        let result = try Self.runProcess(
            "/usr/bin/hdiutil",
            args: [
                "attach", "-nobrowse", "-noverify", "-noautoopen",
                "-mountrandom", "/tmp", dmgPath.path,
            ],
            timeout: 120
        )
        if result.status != 0 {
            let detail = result.stderr.isEmpty ? "exit \(result.status)" : result.stderr
            throw UpdateError.mountFailed(detail)
        }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count >= 3 {
                let mp = String(parts.last!).trimmingCharacters(in: .whitespaces)
                var isDir: ObjCBool = false
                if !mp.isEmpty,
                   FileManager.default.fileExists(atPath: mp, isDirectory: &isDir),
                   isDir.boolValue {
                    return URL(fileURLWithPath: mp)
                }
            }
        }
        throw UpdateError.mountFailed("Could not determine mount point")
    }

    private func unmountDMG(_ mountPoint: URL) throws {
        _ = try Self.runProcess(
            "/usr/bin/hdiutil",
            args: ["detach", mountPoint.path, "-force"],
            timeout: 15
        )
    }

    private func findAppInVolume(_ mountPoint: URL) throws -> URL {
        let direct = mountPoint.appendingPathComponent("\(Self.appName).app")
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.pathExtension == "app" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                return item
            }
        }
        throw UpdateError.appNotFoundInDMG
    }

    static func verifyApp(_ appURL: URL) throws {
        let result = try runProcess(
            "/usr/bin/codesign",
            args: ["--verify", "--deep", "--strict", appURL.path],
            timeout: 30
        )
        if result.status != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.verificationFailed(detail.isEmpty ? "unknown error" : detail)
        }
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(_ executablePath: String, args: [String], timeout: TimeInterval) throws -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            throw UpdateError.processTimedOut(executablePath)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Replace the current app with the staged update and relaunch.
    ///
    /// Spawns a detached shell script that waits for this process to exit,
    /// renames the current app to `.bak`, moves the staged app into place,
    /// strips the quarantine attribute, and relaunches. On any move failure
    /// it restores from the backup.
    static func performSwapAndRelaunch(appURL: URL? = nil) -> Bool {
        let app = appURL ?? getAppBundlePath()
        let staged = stagedPath(appURL: app)
        guard FileManager.default.fileExists(atPath: staged.path) else {
            DebugLog.log("[Updater] Staged update not found")
            return false
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let qApp = shellQuote(app.path)
        let qStaged = shellQuote(staged.path)
        let qBackup = shellQuote(app.path + ".bak")
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.2
        done
        sleep 0.5
        mv \(qApp) \(qBackup) && mv \(qStaged) \(qApp)
        if [ $? -ne 0 ]; then
            mv \(qBackup) \(qApp) 2>/dev/null
            exit 1
        fi
        rm -rf \(qBackup)
        xattr -rd com.apple.quarantine \(qApp) 2>/dev/null
        open \(qApp)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        do {
            try proc.run()
        } catch {
            DebugLog.log("[Updater] Failed to spawn swap script: \(error)")
            return false
        }
        return true
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var lastPct = -1
    private let onProgress: @Sendable (Int) -> Void

    init(onProgress: @escaping @Sendable (Int) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Int(Double(totalBytesWritten) * 100 / Double(totalBytesExpectedToWrite))
        if pct != lastPct {
            lastPct = pct
            onProgress(pct)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Required by protocol; the file location is returned via the async API.
    }
}
