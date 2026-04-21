import Foundation
import Testing
@testable import LingXi

struct TOMLParserTests {

    @Test func parseBasicKeyValue() throws {
        let doc = try TOMLParser.parse("""
            [plugin]
            id = "test.plugin"
            name = "Test Plugin"
        """)

        #expect(doc.string("plugin", "id") == "test.plugin")
        #expect(doc.string("plugin", "name") == "Test Plugin")
    }

    @Test func parseBoolValues() throws {
        let doc = try TOMLParser.parse("""
            [permissions]
            network = true
            clipboard = false
        """)

        #expect(doc.bool("permissions", "network") == true)
        #expect(doc.bool("permissions", "clipboard") == false)
    }

    @Test func parseStringArray() throws {
        let doc = try TOMLParser.parse("""
            [permissions]
            shell = ["echo", "ls", "date"]
        """)

        let arr = doc.stringArray("permissions", "shell")
        #expect(arr == ["echo", "ls", "date"])
    }

    @Test func parseEmptyArray() throws {
        let doc = try TOMLParser.parse("""
            [permissions]
            shell = []
        """)

        let arr = doc.stringArray("permissions", "shell")
        #expect(arr == [])
    }

    @Test func parseTableArray() throws {
        let doc = try TOMLParser.parse("""
            [[commands]]
            name = "cmd1"
            title = "Command 1"

            [[commands]]
            name = "cmd2"
            title = "Command 2"
        """)

        let tables = doc.tableArray("commands")
        #expect(tables?.count == 2)
        #expect(tables?[0]["name"]?.stringValue == "cmd1")
        #expect(tables?[1]["name"]?.stringValue == "cmd2")
    }

    @Test func parseIgnoresComments() throws {
        let doc = try TOMLParser.parse("""
            # This is a comment
            [plugin]
            id = "test" # inline comment
            name = "name"
        """)

        #expect(doc.string("plugin", "id") == "test")
        #expect(doc.string("plugin", "name") == "name")
    }

    @Test func parseIgnoresEmptyLines() throws {
        let doc = try TOMLParser.parse("""

            [plugin]

            id = "test"

        """)

        #expect(doc.string("plugin", "id") == "test")
    }

    @Test func parseMissingKeyReturnsNil() throws {
        let doc = try TOMLParser.parse("""
            [plugin]
            id = "test"
        """)

        #expect(doc.string("plugin", "missing") == nil)
        #expect(doc.string("missing", "id") == nil)
    }

    @Test func parseIntegerValue() throws {
        let doc = try TOMLParser.parse("""
            [search]
            debounce = 150
            timeout = 3000
        """)

        #expect(doc.int("search", "debounce") == 150)
        #expect(doc.int("search", "timeout") == 3000)
    }

    @Test func parseMultipleSections() throws {
        let doc = try TOMLParser.parse("""
            [plugin]
            id = "my.plugin"
            name = "My Plugin"

            [permissions]
            network = true

            [search]
            prefix = "mp"
        """)

        #expect(doc.string("plugin", "id") == "my.plugin")
        #expect(doc.bool("permissions", "network") == true)
        #expect(doc.string("search", "prefix") == "mp")
    }
}
