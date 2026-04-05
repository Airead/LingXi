//
//  DebugLog.swift
//  LingXi
//

import Foundation

enum DebugLog {
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
