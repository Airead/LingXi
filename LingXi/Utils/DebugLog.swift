//
//  DebugLog.swift
//  LingXi
//

import Darwin.Mach
import Foundation

enum DebugLog {
    /// Log current process physical memory (RSS) with a tag for tracking memory changes.
    static func logMemory(_ tag: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let rss = result == KERN_SUCCESS ? info.resident_size : 0
        let mb = Double(rss) / 1_048_576
        log("[Memory] \(tag): RSS=\(String(format: "%.1f", mb)) MB")
    }

    nonisolated(unsafe) private static var fileHandle: FileHandle?

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LingXi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print(line, terminator: "")

        if fileHandle == nil {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: logURL)
            fileHandle?.seekToEndOfFile()
        }
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }
}
