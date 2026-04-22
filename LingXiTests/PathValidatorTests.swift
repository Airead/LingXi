import Foundation
import Testing
@testable import LingXi

struct PathValidatorTests {
    private func makeValidator(allowedPaths: [String]) -> PathValidator {
        PathValidator(allowedPaths: allowedPaths)
    }

    @Test func allowsPathInsideWhitelist() {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validator = makeValidator(allowedPaths: [tempDir.path])
        let subPath = tempDir.appendingPathComponent("sub/file.txt").path

        let result = validator.validate(subPath)
        #expect(result != nil)
    }

    @Test func deniesPathOutsideWhitelist() {
        let tempDir = makeTestTempDir()
        let otherDir = makeTestTempDir()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: otherDir)
        }

        let validator = makeValidator(allowedPaths: [tempDir.path])
        let result = validator.validate(otherDir.path)

        #expect(result == nil)
    }

    @Test func expandsTildeToHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let validator = makeValidator(allowedPaths: ["~/.config/LingXi"])

        let result = validator.validate("~/.config/LingXi/plugins/test.txt")
        #expect(result != nil)
        #expect(result?.hasPrefix(home) == true)
    }

    @Test func deniesDirectoryTraversal() {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validator = makeValidator(allowedPaths: [tempDir.path])
        let maliciousPath = tempDir.appendingPathComponent("../../etc/passwd").path

        let result = validator.validate(maliciousPath)
        #expect(result == nil)
    }

    @Test func allowsExactWhitelistMatch() {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validator = makeValidator(allowedPaths: [tempDir.path])
        let result = validator.validate(tempDir.path)

        #expect(result != nil)
    }

    @Test func deniesEmptyWhitelist() {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validator = makeValidator(allowedPaths: [])
        let result = validator.validate(tempDir.path)

        #expect(result == nil)
    }

    @Test func resolvesSymlinksBeforeChecking() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realDir = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        let linkDir = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let validator = makeValidator(allowedPaths: [realDir.path])
        let result = validator.validate(linkDir.path)

        #expect(result != nil)
    }

    @Test func deniesSymlinkEscape() throws {
        let tempDir = makeTestTempDir()
        let outsideDir = makeTestTempDir()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let linkDir = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: outsideDir)

        let validator = makeValidator(allowedPaths: [tempDir.path])
        let result = validator.validate(linkDir.path)

        #expect(result == nil)
    }
}
