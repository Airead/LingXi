import Testing
@testable import LingXi

struct AppDelegateRelaunchTests {
    @Test func relaunchScriptEmbedsPidAndQuotedPath() {
        let script = AppDelegate.relaunchScript(pid: 4242, appPath: "/Applications/LingXi.app")
        #expect(script.contains("kill -0 4242"))
        #expect(script.contains("open '/Applications/LingXi.app'"))
        #expect(script.hasPrefix("#!/bin/bash"))
    }

    @Test func relaunchScriptEscapesSingleQuotes() {
        let script = AppDelegate.relaunchScript(pid: 1, appPath: "/tmp/Bob's App.app")
        // Single quote in path is escaped as '\'' inside surrounding quotes.
        #expect(script.contains("open '/tmp/Bob'\\''s App.app'"))
    }
}
