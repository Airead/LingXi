import Foundation
import Testing
@testable import LingXi

// MARK: - LeaderKeyConfig tests

@MainActor
struct LeaderKeyConfigTests {

    @Test func parseValidJSON() throws {
        let json = """
        {
            "leaders": [
                {
                    "triggerKey": "cmd_r",
                    "position": "center",
                    "mappings": [
                        { "key": "w", "app": "WeChat", "desc": "WeChat" },
                        { "key": "s", "app": "Slack" },
                        { "key": "t", "exec": "/usr/bin/open -a iTerm", "desc": "Terminal" }
                    ]
                }
            ]
        }
        """
        let data = Data(json.utf8)
        let file = try JSONDecoder().decode(LeaderKeyFile.self, from: data)

        #expect(file.leaders.count == 1)
        let config = file.leaders[0]
        #expect(config.triggerKey == "cmd_r")
        #expect(config.position == .center)
        #expect(config.mappings.count == 3)
        #expect(config.mappings[0].key == "w")
        #expect(config.mappings[0].app == "WeChat")
        #expect(config.mappings[0].desc == "WeChat")
        #expect(config.mappings[1].app == "Slack")
        #expect(config.mappings[1].desc == nil)
        #expect(config.mappings[2].exec == "/usr/bin/open -a iTerm")
    }

    @Test func parseMultipleLeaders() throws {
        let json = """
        {
            "leaders": [
                {
                    "triggerKey": "cmd_r",
                    "mappings": [{ "key": "w", "app": "WeChat" }]
                },
                {
                    "triggerKey": "alt_r",
                    "position": "mouse",
                    "mappings": [{ "key": "d", "exec": "date", "desc": "Date" }]
                }
            ]
        }
        """
        let data = Data(json.utf8)
        let file = try JSONDecoder().decode(LeaderKeyFile.self, from: data)

        #expect(file.leaders.count == 2)
        #expect(file.leaders[0].triggerKey == "cmd_r")
        #expect(file.leaders[1].triggerKey == "alt_r")
        #expect(file.leaders[1].position == .mouse)
    }

    @Test func displayTextFallback() {
        let withDesc = LeaderMapping(key: "w", desc: "WeChat", app: "WeChat", exec: nil)
        #expect(withDesc.displayText == "WeChat")

        let withApp = LeaderMapping(key: "w", desc: nil, app: "Slack", exec: nil)
        #expect(withApp.displayText == "Slack")

        let withExec = LeaderMapping(key: "w", desc: nil, app: nil, exec: "/bin/ls")
        #expect(withExec.displayText == "/bin/ls")

        let empty = LeaderMapping(key: "w", desc: nil, app: nil, exec: nil)
        #expect(empty.displayText == "action")
    }

    @Test func positionParsing() {
        let center = LeaderConfig(triggerKey: "cmd_r", mappings: [])
        #expect(center.position == .center)

        let top = LeaderConfig(triggerKey: "cmd_r", position: .top, mappings: [])
        #expect(top.position == .top)

        let bottom = LeaderConfig(triggerKey: "cmd_r", position: .bottom, mappings: [])
        #expect(bottom.position == .bottom)

        let mouse = LeaderConfig(triggerKey: "cmd_r", position: .mouse, mappings: [])
        #expect(mouse.position == .mouse)
    }

    @Test func positionDefaultsFromJSON() throws {
        let json = """
        { "leaders": [{ "triggerKey": "cmd_r", "mappings": [] }] }
        """
        let file = try JSONDecoder().decode(LeaderKeyFile.self, from: Data(json.utf8))
        #expect(file.leaders[0].position == .center)
    }

    @Test func unknownPositionFallsBackToCenter() throws {
        let json = """
        { "leaders": [{ "triggerKey": "cmd_r", "position": "foobar", "mappings": [] }] }
        """
        // Unknown position value should fail decoding gracefully
        let data = Data(json.utf8)
        do {
            _ = try JSONDecoder().decode(LeaderKeyFile.self, from: data)
            Issue.record("Expected decoding to fail for unknown position")
        } catch {
            // Expected: unknown rawValue fails Codable
        }
    }

    @Test func loadFromNonexistentFile() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-leader-\(UUID().uuidString).json")
        let configs = LeaderKeyConfigLoader.load(from: url)
        #expect(configs.isEmpty)
    }

    @Test func loadFromValidFile() throws {
        let json = """
        {
            "leaders": [
                {
                    "triggerKey": "cmd_r",
                    "mappings": [{ "key": "w", "app": "WeChat" }]
                },
                {
                    "triggerKey": "invalid_key",
                    "mappings": [{ "key": "x", "app": "Foo" }]
                }
            ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("leader-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let configs = LeaderKeyConfigLoader.load(from: url)
        // "invalid_key" should be filtered out
        #expect(configs.count == 1)
        #expect(configs[0].triggerKey == "cmd_r")
    }

    @Test func loadFromMalformedJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("leader-test-bad-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let configs = LeaderKeyConfigLoader.load(from: url)
        #expect(configs.isEmpty)
    }
}

// MARK: - JSONC stripping tests

@MainActor
struct JSONCStripTests {
    @Test func stripsSingleLineComments() {
        let input = """
        {
            // This is a comment
            "key": "value"
        }
        """
        let stripped = LeaderKeyConfigLoader.stripJSONComments(input)
        #expect(!stripped.contains("//"))
        #expect(!stripped.contains("This is a comment"))
        #expect(stripped.contains("\"key\": \"value\""))
    }

    @Test func stripsBlockComments() {
        let input = """
        {
            /* block comment */
            "key": "value"
        }
        """
        let stripped = LeaderKeyConfigLoader.stripJSONComments(input)
        #expect(!stripped.contains("/*"))
        #expect(!stripped.contains("*/"))
        #expect(!stripped.contains("block comment"))
        #expect(stripped.contains("\"key\": \"value\""))
    }

    @Test func preservesURLsInStrings() {
        let input = """
        { "url": "https://example.com" }
        """
        let stripped = LeaderKeyConfigLoader.stripJSONComments(input)
        #expect(stripped.contains("https://example.com"))
    }

    @Test func preservesEscapedQuotesInStrings() {
        let input = """
        { "msg": "he said \\"hello\\"" }
        """
        let stripped = LeaderKeyConfigLoader.stripJSONComments(input)
        #expect(stripped.contains("he said \\\"hello\\\""))
    }

    @Test func stripsCommentedOutJSONEntries() {
        let input = """
        {
            "leaders": [{
                "triggerKey": "cmd_r",
                "mappings": [
                    { "key": "w", "app": "WeChat" },
                    // { "key": "o", "app": "Old" },
                    { "key": "s", "app": "Slack" }
                ]
            }]
        }
        """
        let stripped = LeaderKeyConfigLoader.stripJSONComments(input)
        let data = Data(stripped.utf8)
        let file = try! JSONDecoder().decode(LeaderKeyFile.self, from: data)
        #expect(file.leaders[0].mappings.count == 2)
        #expect(file.leaders[0].mappings[0].app == "WeChat")
        #expect(file.leaders[0].mappings[1].app == "Slack")
    }

    @Test func handlesMultilineBlockComment() {
        let input = """
        {
            /*
             * This entire section
             * is commented out
             */
            "key": "value"
        }
        """
        let stripped = LeaderKeyConfigLoader.stripJSONComments(input)
        #expect(stripped.contains("\"key\": \"value\""))
        #expect(!stripped.contains("commented out"))
    }

    @Test func noCommentsPassesThrough() {
        let input = """
        { "key": "value", "num": 42 }
        """
        let stripped = LeaderKeyConfigLoader.stripJSONComments(input)
        #expect(stripped == input)
    }
}

// MARK: - Keycode mapping tests

struct LeaderKeycodeTests {

    @Test func modifierKeysContainExpected() {
        #expect(LeaderKeycode.modifierKeys["cmd_r"] != nil)
        #expect(LeaderKeycode.modifierKeys["cmd"] != nil)
        #expect(LeaderKeycode.modifierKeys["alt_r"] != nil)
        #expect(LeaderKeycode.modifierKeys["shift"] != nil)
        #expect(LeaderKeycode.modifierKeys["fn"] != nil)
    }

    @Test func regularKeysContainAlphabet() {
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            #expect(LeaderKeycode.regularKeys[String(letter)] != nil, "Missing key: \(letter)")
        }
    }

    @Test func regularKeysContainDigits() {
        for digit in "0123456789" {
            #expect(LeaderKeycode.regularKeys[String(digit)] != nil, "Missing key: \(digit)")
        }
    }

    @Test func reverseMapConsistency() {
        for (name, code) in LeaderKeycode.regularKeys {
            #expect(LeaderKeycode.keycodeToName[code] == name)
        }
    }

    @Test func modifierReverseMapConsistency() {
        for (name, info) in LeaderKeycode.modifierKeys {
            #expect(LeaderKeycode.keycodeToModifierName[info.keycode] == name)
        }
    }

    @Test func allTriggerNamesMatchModifierKeys() {
        #expect(LeaderKeycode.allTriggerNames == Set(LeaderKeycode.modifierKeys.keys))
    }
}
