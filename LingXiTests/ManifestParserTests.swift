import Foundation
import Testing
@testable import LingXi

struct ManifestParserTests {

    @Test func parseTOMLManifest() throws {
        let toml = """
            [plugin]
            id = "com.test.plugin"
            name = "Test Plugin"
            version = "1.0.0"
            author = "Test Author"
            description = "A test plugin"
            minLingXiVersion = "0.1.0"

            [search]
            prefix = "tp"
            debounce = 150
            timeout = 3000
            usage_boost = false

            [permissions]
            network = true
            clipboard = false
            filesystem = ["/tmp", "~/.config"]
            shell = ["echo", "ls"]
            notify = true

            [[commands]]
            name = "hello"
            title = "Say Hello"
            subtitle = "Greets you"
            action = "sayHello"
        """

        let manifest = try ManifestParser.parseTOML(toml)

        #expect(manifest.id == "com.test.plugin")
        #expect(manifest.name == "Test Plugin")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.author == "Test Author")
        #expect(manifest.description == "A test plugin")
        #expect(manifest.minLingXiVersion == "0.1.0")
        #expect(manifest.prefix == "tp")
        #expect(manifest.debounce == 150)
        #expect(manifest.timeout == 3000)
        #expect(manifest.usageBoost == false)
        #expect(manifest.permissions.network == true)
        #expect(manifest.permissions.clipboard == false)
        #expect(manifest.permissions.filesystem == ["/tmp", "~/.config"])
        #expect(manifest.permissions.shell == ["echo", "ls"])
        #expect(manifest.permissions.notify == true)
        #expect(manifest.permissions.store == false)
        #expect(manifest.commands.count == 1)
        #expect(manifest.commands[0].name == "hello")
        #expect(manifest.commands[0].title == "Say Hello")
        #expect(manifest.commands[0].subtitle == "Greets you")
        #expect(manifest.commands[0].actionFunctionName == "sayHello")
    }

    @Test func parseTOMLWithDefaults() throws {
        let toml = """
            [plugin]
            id = "minimal"
            name = "Minimal Plugin"
        """

        let manifest = try ManifestParser.parseTOML(toml)

        #expect(manifest.prefix == "minimal")
        #expect(manifest.debounce == 100)
        #expect(manifest.timeout == 5000)
        #expect(manifest.usageBoost == true)
        #expect(manifest.permissions.network == false)
        #expect(manifest.permissions.clipboard == false)
        #expect(manifest.permissions.filesystem == [])
        #expect(manifest.permissions.shell == [])
        #expect(manifest.permissions.notify == false)
        #expect(manifest.permissions.store == false)
        #expect(manifest.commands.isEmpty)
    }

    @Test func parseTOMLRequiresId() throws {
        let toml = """
            [plugin]
            name = "No ID"
        """

        #expect(throws: TOMLParser.Error.self) {
            try ManifestParser.parseTOML(toml)
        }
    }

    @Test func parseTOMLRequiresName() throws {
        let toml = """
            [plugin]
            id = "no.name"
        """

        #expect(throws: TOMLParser.Error.self) {
            try ManifestParser.parseTOML(toml)
        }
    }

    @Test func parseTOMLManifestFromDirectory() throws {
        let dir = makeTestTempDir(label: "ManifestParserTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let toml = """
            [plugin]
            id = "dir.test"
            name = "Dir Test"
        """
        try toml.write(
            to: dir.appendingPathComponent("plugin.toml"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = try ManifestParser.parseTOMLManifest(from: dir)
        #expect(manifest.id == "dir.test")
        #expect(manifest.name == "Dir Test")
    }

    @Test func parseTOMLManifestMissingFile() throws {
        let dir = makeTestTempDir(label: "ManifestParserTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: TOMLParser.Error.self) {
            try ManifestParser.parseTOMLManifest(from: dir)
        }
    }
}
