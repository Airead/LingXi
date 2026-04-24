import Foundation
import Testing
@testable import LingXi

/// Tests for `lingxi.db` Lua API (phase 1: plugin-owned databases).
///
/// All tests run against an injected temporary base directory so that we never
/// touch the real `~/.cache/LingXi/plugin-db/` on the developer machine.
struct LuaDBAPITests {
    // MARK: - Fixtures

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuaDBAPITests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) async {
        await PluginDBManager.shared.resetForTesting(
            baseDirectory: FileManager.default.temporaryDirectory
        )
        try? FileManager.default.removeItem(at: url)
    }

    private func makeState(
        db: Bool = true,
        pluginId: String = "test.db.plugin"
    ) -> LuaState {
        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        let perms = PermissionConfig(
            network: false,
            clipboard: false,
            filesystem: [],
            shell: [],
            notify: false,
            store: false,
            webview: false,
            cache: false,
            db: db
        )
        LuaAPI.registerAll(state: state, permissions: perms, pluginId: pluginId, pluginDir: "")
        return state
    }

    // MARK: - Surface

    @Test func dbTableExistsWhenEnabled() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState(db: true)
        try state.doString("""
            assert(type(lingxi.db) == 'table')
            assert(type(lingxi.db.open) == 'function')
        """)
    }

    @Test func dbOpenDeniedWhenDisabled() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState(db: false)
        try state.doString("""
            local db, err = lingxi.db.open("test")
            assert(db == nil, "expected nil db, got " .. tostring(db))
            assert(type(err) == 'string' and err:find("permission") ~= nil,
                   "expected permission error, got " .. tostring(err))
        """)
    }

    // MARK: - Basic CRUD

    @Test func openExecQueryRoundTrip() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState()
        try state.doString("""
            local db = assert(lingxi.db.open("sessions"))
            assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)") == 0)
            assert(db:exec("INSERT INTO t(name) VALUES (?)", {"alice"}) == 1)
            assert(db:exec("INSERT INTO t(name) VALUES (?)", {"bob"}) == 1)
            local rows = assert(db:query("SELECT id, name FROM t ORDER BY id"))
            assert(#rows == 2, "expected 2 rows, got " .. #rows)
            assert(rows[1].id == 1 and rows[1].name == "alice")
            assert(rows[2].id == 2 and rows[2].name == "bob")
            db:close()
        """)
    }

    @Test func parameterBindingTypes() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState()
        try state.doString("""
            local db = assert(lingxi.db.open("types"))
            db:exec("CREATE TABLE t (i INTEGER, r REAL, s TEXT, n TEXT)")
            assert(db:exec("INSERT INTO t VALUES (?, ?, ?, ?)", {42, 3.14, "hello", nil}) == 1)
            local row = assert(db:queryOne("SELECT i, r, s, n FROM t"))
            assert(row.i == 42, "integer roundtrip, got " .. tostring(row.i))
            assert(math.abs(row.r - 3.14) < 0.0001, "real roundtrip, got " .. tostring(row.r))
            assert(row.s == "hello", "text roundtrip, got " .. tostring(row.s))
            assert(row.n == nil, "null roundtrip, got " .. tostring(row.n))
            db:close()
        """)
    }

    @Test func queryOneReturnsNilWhenNoRows() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState()
        try state.doString("""
            local db = assert(lingxi.db.open("empty"))
            db:exec("CREATE TABLE t (id INTEGER)")
            local row = db:queryOne("SELECT id FROM t WHERE id = ?", {999})
            assert(row == nil, "expected nil row, got " .. tostring(row))
            db:close()
        """)
    }

    // MARK: - Error paths

    @Test func closedHandleReturnsError() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState()
        try state.doString("""
            local db = assert(lingxi.db.open("closed"))
            db:close()
            local rows, err = db:query("SELECT 1")
            assert(rows == nil, "expected nil rows after close")
            assert(type(err) == 'string' and err:find("closed") ~= nil,
                   "expected 'closed' error, got " .. tostring(err))
        """)
    }

    @Test func invalidSQLReturnsError() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState()
        try state.doString("""
            local db = assert(lingxi.db.open("badsql"))
            local rows, err = db:query("NOT A VALID STATEMENT")
            assert(rows == nil)
            assert(type(err) == 'string' and #err > 0)
            db:close()
        """)
    }

    @Test func invalidNameRejected() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState()
        try state.doString("""
            local bad = {"", "..", ".", "a/b", "a\\\\b"}
            for _, name in ipairs(bad) do
                local db, err = lingxi.db.open(name)
                assert(db == nil, "expected nil for name " .. name)
                assert(type(err) == 'string', "expected error message for name " .. name)
            end
        """)
    }

    // MARK: - Persistence

    @Test func dataPersistsAcrossOpen() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state1 = makeState()
        try state1.doString("""
            local db = assert(lingxi.db.open("persist"))
            db:exec("CREATE TABLE t (x INTEGER)")
            db:exec("INSERT INTO t VALUES (?)", {7})
            db:close()
        """)

        let state2 = makeState()
        try state2.doString("""
            local db = assert(lingxi.db.open("persist"))
            local row = assert(db:queryOne("SELECT x FROM t"))
            assert(row.x == 7)
            db:close()
        """)
    }

    @Test func pluginDataIsolated() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let stateA = makeState(pluginId: "plugin.a")
        try stateA.doString("""
            local db = assert(lingxi.db.open("data"))
            db:exec("CREATE TABLE t (x INTEGER)")
            db:exec("INSERT INTO t VALUES (1)")
            db:close()
        """)

        // Different plugin, same file name — should be a separate file.
        let stateB = makeState(pluginId: "plugin.b")
        try stateB.doString("""
            local db = assert(lingxi.db.open("data"))
            -- Table does not exist yet for plugin.b.
            local rows, err = db:query("SELECT * FROM t")
            assert(rows == nil and err ~= nil, "expected error, got " .. tostring(err))
            db:close()
        """)
    }

    // MARK: - Lifecycle

    @Test func closeAllDropsPluginConnections() async throws {
        let tmp = makeTempDir()
        defer { Task { await cleanup(tmp) } }
        await PluginDBManager.shared.resetForTesting(baseDirectory: tmp)

        let state = makeState(pluginId: "plugin.close")
        try state.doString("""
            _G.handle = assert(lingxi.db.open("cx"))
            _G.handle:exec("CREATE TABLE t (x INTEGER)")
        """)

        await PluginDBManager.shared.closeAll(pluginId: "plugin.close")

        // After host-side closeAll, the Lua-side handle is stale; next call
        // should return an error, not crash.
        try state.doString("""
            local rows, err = _G.handle:query("SELECT 1")
            assert(rows == nil, "expected nil after closeAll")
            assert(type(err) == 'string')
        """)
    }
}
