import CoreGraphics
import Foundation
import Testing
@testable import LingXi

struct SnippetExpanderTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingXiExpanderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeExpander(snippets: [(keyword: String, content: String, autoExpand: Bool)] = []) async throws -> (SnippetExpander, URL) {
        let dir = try makeTempDir()
        let store = SnippetStore(directory: dir)
        for s in snippets {
            await store.add(name: s.keyword, keyword: s.keyword, content: s.content, autoExpand: s.autoExpand)
        }
        let expander = SnippetExpander(store: store)
        await expander.refreshSnippets()
        return (expander, dir)
    }

    // MARK: - Buffer management

    @Test func bufferAccumulatesAndMatchesAfterMultipleKeys() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        #expect(expander.processKey(keycode: 0, flags: [], character: "a") == nil)
        #expect(expander.processKey(keycode: 0, flags: [], character: "b") == nil)
        #expect(expander.processKey(keycode: 0, flags: [], character: "c") == "abc")
    }

    @Test func modifierKeysClearBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        // Cmd modifier clears buffer
        expander.processKey(keycode: 0, flags: .maskCommand, character: "x")
        // Now type "c" — buffer is just "c", not "abc"
        let match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    @Test func controlKeyClearsBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        // Ctrl modifier clears buffer
        expander.processKey(keycode: 0, flags: .maskControl, character: "c")
        let match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    @Test func altKeyClearsBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        // Alt modifier clears buffer
        expander.processKey(keycode: 0, flags: .maskAlternate, character: "c")
        let match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    @Test func returnKeyClearsBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        // Return keycode (36) clears buffer
        expander.processKey(keycode: 36, flags: [], character: "\r")
        let match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    @Test func escapeKeyClearsBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        // Escape keycode (53) clears buffer
        expander.processKey(keycode: 53, flags: [], character: "\u{1B}")
        let match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    @Test func tabKeyClearsBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        // Tab keycode (48) clears buffer
        expander.processKey(keycode: 48, flags: [], character: "\t")
        let match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    @Test func backspaceKeyClearsBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        // Backspace keycode (51) clears buffer
        expander.processKey(keycode: 51, flags: [], character: "")
        let match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    @Test func arrowKeysClearBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        // Left arrow (123)
        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        expander.processKey(keycode: 123, flags: [], character: "")
        var match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)

        // Right arrow (124)
        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        expander.processKey(keycode: 124, flags: [], character: "")
        match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    @Test func nonPrintableCharactersIgnored() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "ab", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        // Non-printable character should be ignored, buffer stays "a"
        expander.processKey(keycode: 0, flags: [], character: "\u{0003}")
        let match = expander.processKey(keycode: 0, flags: [], character: "b")
        #expect(match == "ab")
    }

    @Test func emptyCharacterIgnored() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "ab", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        // Empty character should be ignored
        expander.processKey(keycode: 0, flags: [], character: "")
        let match = expander.processKey(keycode: 0, flags: [], character: "b")
        #expect(match == "ab")
    }

    // MARK: - Keyword matching

    @Test func matchesKeywordAtBufferEnd() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: ";;email", content: "user@example.com", autoExpand: true),
        ])
        defer { cleanup(dir) }

        var result: String?
        for char in "hello;;email" {
            result = expander.processKey(keycode: 0, flags: [], character: String(char))
        }
        #expect(result == ";;email")
    }

    @Test func noMatchForPartialKeyword() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: ";;email", content: "user@example.com", autoExpand: true),
        ])
        defer { cleanup(dir) }

        var result: String?
        for char in ";;emai" {
            result = expander.processKey(keycode: 0, flags: [], character: String(char))
        }
        #expect(result == nil)
    }

    @Test func autoExpandFalseNotMatched() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: ";;skip", content: "should not match", autoExpand: false),
        ])
        defer { cleanup(dir) }

        var result: String?
        for char in ";;skip" {
            result = expander.processKey(keycode: 0, flags: [], character: String(char))
        }
        #expect(result == nil)
    }

    @Test func multipleSnippetsMatchCorrectOne() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: ";;a", content: "alpha", autoExpand: true),
            (keyword: ";;b", content: "beta", autoExpand: true),
        ])
        defer { cleanup(dir) }

        var result: String?
        for char in ";;b" {
            result = expander.processKey(keycode: 0, flags: [], character: String(char))
        }
        #expect(result == ";;b")
    }

    @Test func keywordWithSurroundingText() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "/sig/", content: "-- Signature", autoExpand: true),
        ])
        defer { cleanup(dir) }

        var result: String?
        for char in "some text /sig/" {
            result = expander.processKey(keycode: 0, flags: [], character: String(char))
        }
        #expect(result == "/sig/")
    }

    // MARK: - Suppress / Resume

    @Test func suppressedExpanderDoesNotMatch() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: ";;go", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.suppress()

        var result: String?
        for char in ";;go" {
            result = expander.processKey(keycode: 0, flags: [], character: String(char))
        }
        #expect(result == nil)
    }

    @Test func resumeAfterSuppressAllowsMatch() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: ";;go", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.suppress()
        expander.resume()

        var result: String?
        for char in ";;go" {
            result = expander.processKey(keycode: 0, flags: [], character: String(char))
        }
        #expect(result == ";;go")
    }

    @Test func suppressClearsBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "abc", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        expander.processKey(keycode: 0, flags: [], character: "a")
        expander.processKey(keycode: 0, flags: [], character: "b")
        expander.suppress()
        expander.resume()
        // Buffer was cleared, so typing just "c" won't match "abc"
        let match = expander.processKey(keycode: 0, flags: [], character: "c")
        #expect(match == nil)
    }

    // MARK: - snippetForKeyword

    @Test func snippetForKeywordReturnsContent() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: ";;hi", content: "Hello World", autoExpand: true),
        ])
        defer { cleanup(dir) }

        let info = expander.snippetForKeyword(";;hi")
        #expect(info?.content == "Hello World")
        #expect(info?.raw == false)
    }

    @Test func snippetForKeywordReturnsNilForUnknown() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: ";;hi", content: "Hello", autoExpand: true),
        ])
        defer { cleanup(dir) }

        let info = expander.snippetForKeyword(";;nope")
        #expect(info == nil)
    }

    // MARK: - Buffer overflow

    @Test func bufferTruncatesToMaxLength() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "z", content: "match", autoExpand: true),
        ])
        defer { cleanup(dir) }

        // Type 200 characters to overflow buffer (max 128)
        for _ in 0..<200 {
            expander.processKey(keycode: 0, flags: [], character: "a")
        }
        // Should still work — buffer is truncated, not broken
        let match = expander.processKey(keycode: 0, flags: [], character: "z")
        #expect(match == "z")
    }

    // MARK: - Shift modifier does not clear buffer

    @Test func shiftModifierDoesNotClearBuffer() async throws {
        let (expander, dir) = try await makeExpander(snippets: [
            (keyword: "AB", content: "expanded", autoExpand: true),
        ])
        defer { cleanup(dir) }

        // Shift is used for uppercase — should NOT clear buffer
        let r1 = expander.processKey(keycode: 0, flags: .maskShift, character: "A")
        #expect(r1 == nil)
        let r2 = expander.processKey(keycode: 0, flags: .maskShift, character: "B")
        #expect(r2 == "AB")
    }
}
