-- API Test Plugin: SQLite DB
-- Comprehensive test suite for lingxi.db (phase 1: plugin-owned databases)

-- ============================================================================
-- Test Framework
-- ============================================================================

local _test_results = {}
local _current_suite = nil

local function _assert(condition, message)
    if not condition then
        error(message or "assertion failed", 2)
    end
end

local function _assert_eq(actual, expected, message)
    if actual ~= expected then
        error((message or "assertion failed")
            .. "\n  expected: " .. tostring(expected)
            .. "\n  actual:   " .. tostring(actual), 2)
    end
end

local function _assert_type(value, expected_type, message)
    if type(value) ~= expected_type then
        error((message or "type assertion failed")
            .. "\n  expected: " .. expected_type
            .. "\n  actual:   " .. type(value), 2)
    end
end

local function _assert_near(actual, expected, tolerance, message)
    tolerance = tolerance or 0.0001
    if math.abs(actual - expected) > tolerance then
        error((message or "near assertion failed")
            .. "\n  expected: ~" .. tostring(expected)
            .. "\n  actual:   " .. tostring(actual), 2)
    end
end

local function _run_test(name, fn)
    local suite = _current_suite or "default"
    local result = { name = name, suite = suite, passed = false, error = nil, duration = 0 }

    local start_time = os.clock()
    local ok, err = pcall(fn)
    result.duration = os.clock() - start_time

    if ok then
        result.passed = true
    else
        result.error = tostring(err)
    end

    table.insert(_test_results, result)
    return result.passed, result.error
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- Open a fresh DB with a stable name used across the suite.
-- Drops all known test tables to ensure idempotency between test runs.
local function _open_clean(name)
    local db = assert(lingxi.db.open(name or "testdb"))
    -- Drop every user table to get a clean slate. Uses sqlite_master lookup.
    local tables = db:query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    if tables then
        for _, row in ipairs(tables) do
            db:exec("DROP TABLE IF EXISTS \"" .. row.name .. "\"")
        end
    end
    return db
end

-- ============================================================================
-- Test Suites
-- ============================================================================

local function test_surface()
    _current_suite = "surface"

    _run_test("lingxi.db is a table", function()
        _assert_type(lingxi.db, "table", "lingxi.db must be a table")
    end)

    _run_test("lingxi.db.open is a function", function()
        _assert_type(lingxi.db.open, "function", "open must be a function")
    end)

    _run_test("open returns userdata when valid", function()
        local db = lingxi.db.open("surface_probe")
        _assert(db ~= nil, "expected non-nil db handle")
        _assert(type(db) == "userdata", "expected userdata, got " .. type(db))
        db:close()
    end)

    _run_test("userdata has method metatable", function()
        local db = lingxi.db.open("surface_probe")
        _assert_type(db.exec, "function", "db:exec should be callable")
        _assert_type(db.query, "function", "db:query should be callable")
        _assert_type(db.queryOne, "function", "db:queryOne should be callable")
        _assert_type(db.close, "function", "db:close should be callable")
        db:close()
    end)
end

local function test_open_validation()
    _current_suite = "open.validation"

    local bad_names = { "", ".", "..", "a/b", "a\\b" }
    for _, name in ipairs(bad_names) do
        _run_test("rejects invalid name: '" .. name .. "'", function()
            local db, err = lingxi.db.open(name)
            _assert_eq(db, nil, "expected nil handle for bad name: " .. name)
            _assert_type(err, "string", "expected error string for bad name: " .. name)
        end)
    end

    _run_test("rejects non-string name", function()
        local db, err = lingxi.db.open(42)
        _assert_eq(db, nil, "numeric name should be rejected")
        _assert_type(err, "string", "expected error message")
    end)

    _run_test("accepts simple alphanumeric name", function()
        local db = lingxi.db.open("good_name_123")
        _assert(db ~= nil, "simple name should work")
        db:close()
    end)

    _run_test("accepts name with dots (not just '.' alone)", function()
        local db = lingxi.db.open("my.db.name")
        _assert(db ~= nil, "dotted name should work")
        db:close()
    end)
end

local function test_ddl_and_dml()
    _current_suite = "ddl.and.dml"

    _run_test("CREATE TABLE succeeds (returns 0 changes)", function()
        local db = _open_clean()
        local n = assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
        _assert_eq(n, 0, "CREATE should report 0 changes")
        db:close()
    end)

    _run_test("INSERT returns changes=1", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        local n = assert(db:exec("INSERT INTO t(name) VALUES (?)", { "alice" }))
        _assert_eq(n, 1, "single INSERT should report 1 change")
        db:close()
    end)

    _run_test("UPDATE returns number of rows changed", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        db:exec("INSERT INTO t(name) VALUES (?)", { "a" })
        db:exec("INSERT INTO t(name) VALUES (?)", { "b" })
        db:exec("INSERT INTO t(name) VALUES (?)", { "c" })
        local n = assert(db:exec("UPDATE t SET name = ?", { "x" }))
        _assert_eq(n, 3, "UPDATE affecting 3 rows should report 3")
        db:close()
    end)

    _run_test("DELETE returns number of rows deleted", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        db:exec("INSERT INTO t(id) VALUES (1),(2),(3),(4),(5)")
        local n = assert(db:exec("DELETE FROM t WHERE id > ?", { 2 }))
        _assert_eq(n, 3, "DELETE of 3 rows should report 3")
        db:close()
    end)
end

local function test_query()
    _current_suite = "query"

    _run_test("query returns empty table for empty table", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (x INTEGER)")
        local rows = assert(db:query("SELECT * FROM t"))
        _assert_type(rows, "table", "rows should be a table")
        _assert_eq(#rows, 0, "expected 0 rows")
        db:close()
    end)

    _run_test("query returns rows in insertion order (by rowid)", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        db:exec("INSERT INTO t(name) VALUES ('a'),('b'),('c')")
        local rows = assert(db:query("SELECT id, name FROM t ORDER BY id"))
        _assert_eq(#rows, 3, "expected 3 rows")
        _assert_eq(rows[1].name, "a")
        _assert_eq(rows[2].name, "b")
        _assert_eq(rows[3].name, "c")
        db:close()
    end)

    _run_test("query with WHERE and parameter binding", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, tag TEXT)")
        db:exec("INSERT INTO t(tag) VALUES ('foo'),('bar'),('foo'),('baz')")
        local rows = assert(db:query("SELECT id FROM t WHERE tag = ? ORDER BY id", { "foo" }))
        _assert_eq(#rows, 2, "expected 2 matching rows")
        db:close()
    end)

    _run_test("column keys map correctly", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (x INTEGER, y INTEGER)")
        db:exec("INSERT INTO t(x, y) VALUES (1, 2)")
        local row = assert(db:queryOne("SELECT y, x FROM t"))
        _assert_eq(row.x, 1, "x should be 1")
        _assert_eq(row.y, 2, "y should be 2")
        db:close()
    end)

    _run_test("aliased columns use the alias name", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (raw INTEGER)")
        db:exec("INSERT INTO t(raw) VALUES (100)")
        local row = assert(db:queryOne("SELECT raw AS pretty FROM t"))
        _assert_eq(row.pretty, 100)
        _assert_eq(row.raw, nil, "raw should not be set when aliased")
        db:close()
    end)
end

local function test_queryOne()
    _current_suite = "queryOne"

    _run_test("returns nil when no rows match", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (id INTEGER)")
        local row = db:queryOne("SELECT id FROM t WHERE id = ?", { 999 })
        _assert_eq(row, nil, "expected nil for no match")
        db:close()
    end)

    _run_test("returns first row when multiple match", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        db:exec("INSERT INTO t(name) VALUES ('a'),('b'),('c')")
        local row = assert(db:queryOne("SELECT name FROM t ORDER BY id"))
        _assert_eq(row.name, "a", "should return first row")
        db:close()
    end)

    _run_test("returns a plain table (not array-wrapped)", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (x INTEGER)")
        db:exec("INSERT INTO t(x) VALUES (7)")
        local row = assert(db:queryOne("SELECT x FROM t"))
        _assert_type(row, "table", "row should be a table")
        _assert_eq(row.x, 7)
        -- Should NOT be { { x = 7 } } — that would be a query() result.
        _assert_eq(row[1], nil, "row should not have array index 1")
        db:close()
    end)
end

local function test_type_mapping()
    _current_suite = "type.mapping"

    _run_test("INTEGER roundtrip", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        db:exec("INSERT INTO t(v) VALUES (?)", { 42 })
        local row = assert(db:queryOne("SELECT v FROM t"))
        _assert_eq(row.v, 42)
        _assert_type(row.v, "number", "v should be a number")
        db:close()
    end)

    _run_test("large 64-bit integer roundtrip", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        -- 2^53 + 1 would lose precision as double; Lua 5.3+ preserves as int.
        local big = 9007199254740993
        db:exec("INSERT INTO t(v) VALUES (?)", { big })
        local row = assert(db:queryOne("SELECT v FROM t"))
        _assert_eq(row.v, big, "large int should survive roundtrip")
        db:close()
    end)

    _run_test("REAL roundtrip", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v REAL)")
        db:exec("INSERT INTO t(v) VALUES (?)", { 3.14159 })
        local row = assert(db:queryOne("SELECT v FROM t"))
        _assert_near(row.v, 3.14159, 0.0001)
        db:close()
    end)

    _run_test("TEXT roundtrip (including unicode)", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v TEXT)")
        db:exec("INSERT INTO t(v) VALUES (?)", { "héllo 世界 🌍" })
        local row = assert(db:queryOne("SELECT v FROM t"))
        _assert_eq(row.v, "héllo 世界 🌍")
        db:close()
    end)

    _run_test("NULL via explicit SQL", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v TEXT)")
        db:exec("INSERT INTO t(v) VALUES (NULL)")
        local row = assert(db:queryOne("SELECT v FROM t"))
        _assert_eq(row.v, nil, "SQL NULL should map to Lua nil")
        db:close()
    end)

    _run_test("boolean bound as integer (1/0)", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        db:exec("INSERT INTO t(v) VALUES (?)", { true })
        db:exec("INSERT INTO t(v) VALUES (?)", { false })
        local rows = assert(db:query("SELECT v FROM t ORDER BY rowid"))
        _assert_eq(rows[1].v, 1, "true -> 1")
        _assert_eq(rows[2].v, 0, "false -> 0")
        db:close()
    end)

    _run_test("empty string is distinct from NULL", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v TEXT)")
        db:exec("INSERT INTO t(v) VALUES (?)", { "" })
        db:exec("INSERT INTO t(v) VALUES (NULL)")
        local rows = assert(db:query("SELECT v, v IS NULL AS is_null FROM t ORDER BY rowid"))
        _assert_eq(rows[1].v, "", "empty string preserved")
        _assert_eq(rows[1].is_null, 0, "empty string is not NULL")
        _assert_eq(rows[2].v, nil, "second row is NULL")
        _assert_eq(rows[2].is_null, 1, "second row IS NULL")
        db:close()
    end)
end

local function test_parameter_binding()
    _current_suite = "params"

    _run_test("no params works (missing param arg)", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        db:exec("INSERT INTO t(v) VALUES (1)")
        local row = assert(db:queryOne("SELECT v FROM t"))
        _assert_eq(row.v, 1)
        db:close()
    end)

    _run_test("empty params table works", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        db:exec("INSERT INTO t(v) VALUES (2)", {})
        local row = assert(db:queryOne("SELECT v FROM t"))
        _assert_eq(row.v, 2)
        db:close()
    end)

    _run_test("multiple positional params in order", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (a INTEGER, b TEXT, c REAL)")
        db:exec("INSERT INTO t(a, b, c) VALUES (?, ?, ?)", { 1, "two", 3.0 })
        local row = assert(db:queryOne("SELECT a, b, c FROM t"))
        _assert_eq(row.a, 1)
        _assert_eq(row.b, "two")
        _assert_near(row.c, 3.0)
        db:close()
    end)

    _run_test("non-table params rejected with error", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        local n, err = db:exec("INSERT INTO t(v) VALUES (?)", "not a table")
        _assert_eq(n, nil, "expected nil for bad params type")
        _assert_type(err, "string", "expected error message")
        db:close()
    end)

    _run_test("param count mismatch → NULL defaults (SQLite behavior)", function()
        -- SQLite binds unspecified positional params as NULL rather than
        -- erroring. Document the behavior so plugin authors know.
        local db = _open_clean()
        db:exec("CREATE TABLE t (a INTEGER, b TEXT)")
        db:exec("INSERT INTO t(a, b) VALUES (?, ?)", { 42 })
        local row = assert(db:queryOne("SELECT a, b FROM t"))
        _assert_eq(row.a, 42)
        _assert_eq(row.b, nil, "missing param binds as NULL")
        db:close()
    end)
end

local function test_errors()
    _current_suite = "errors"

    _run_test("invalid SQL returns nil + error", function()
        local db = _open_clean()
        local rows, err = db:query("NOT VALID SQL !!!")
        _assert_eq(rows, nil)
        _assert_type(err, "string", "expected error string")
        _assert(#err > 0, "error message should not be empty")
        db:close()
    end)

    _run_test("UNIQUE constraint violation returns error", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (k TEXT UNIQUE)")
        db:exec("INSERT INTO t(k) VALUES ('x')")
        local n, err = db:exec("INSERT INTO t(k) VALUES ('x')")
        _assert_eq(n, nil, "expected nil for constraint violation")
        _assert_type(err, "string", "expected error message")
        _assert(err:lower():find("constraint") ~= nil or err:lower():find("unique") ~= nil,
            "error should mention constraint/unique: " .. err)
        db:close()
    end)

    _run_test("selecting from missing table returns error", function()
        local db = _open_clean()
        local rows, err = db:query("SELECT * FROM does_not_exist")
        _assert_eq(rows, nil)
        _assert_type(err, "string")
        db:close()
    end)

    _run_test("non-string sql rejected", function()
        local db = _open_clean()
        local rows, err = db:query(123)
        _assert_eq(rows, nil)
        _assert_type(err, "string", "expected error message")
        db:close()
    end)
end

local function test_lifecycle()
    _current_suite = "lifecycle"

    _run_test("close returns true", function()
        local db = lingxi.db.open("lifecycle_close")
        local ok = db:close()
        _assert_eq(ok, true)
    end)

    _run_test("double close is safe", function()
        local db = lingxi.db.open("lifecycle_double")
        db:close()
        local ok = db:close()
        _assert_eq(ok, true, "second close should still return true")
    end)

    _run_test("query on closed handle returns nil + err", function()
        local db = lingxi.db.open("lifecycle_after_close")
        db:close()
        local rows, err = db:query("SELECT 1")
        _assert_eq(rows, nil)
        _assert_type(err, "string")
        _assert(err:find("closed") ~= nil, "error should mention 'closed': " .. err)
    end)

    _run_test("exec on closed handle returns nil + err", function()
        local db = lingxi.db.open("lifecycle_exec_closed")
        db:close()
        local n, err = db:exec("SELECT 1")
        _assert_eq(n, nil)
        _assert_type(err, "string")
    end)

    _run_test("handles go out of scope without crashing (relies on __gc)", function()
        -- Rapidly open and drop references to exercise __gc path.
        for i = 1, 20 do
            local db = lingxi.db.open("gc_test_" .. i)
            db:exec("CREATE TABLE IF NOT EXISTS t (x INTEGER)")
            -- No explicit close — let GC handle it.
        end
        collectgarbage("collect")
        collectgarbage("collect")
        _assert(true, "should not crash")
    end)
end

local function test_persistence()
    _current_suite = "persistence"

    _run_test("data persists across reopen", function()
        local marker = "persist-" .. os.time() .. "-" .. math.random(100000)

        local db1 = assert(lingxi.db.open("persist_db"))
        db1:exec("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)")
        db1:exec("INSERT OR REPLACE INTO kv(k, v) VALUES (?, ?)", { "marker", marker })
        db1:close()

        local db2 = assert(lingxi.db.open("persist_db"))
        local row = assert(db2:queryOne("SELECT v FROM kv WHERE k = ?", { "marker" }))
        _assert_eq(row.v, marker, "value should survive close/reopen")
        db2:close()
    end)

    _run_test("separate db names are isolated files", function()
        local db_a = assert(lingxi.db.open("isolated_a"))
        db_a:exec("DROP TABLE IF EXISTS only_in_a")
        db_a:exec("CREATE TABLE only_in_a (x INTEGER)")
        db_a:close()

        local db_b = assert(lingxi.db.open("isolated_b"))
        local rows, err = db_b:query("SELECT * FROM only_in_a")
        _assert_eq(rows, nil, "table from db_a should not be visible in db_b")
        _assert_type(err, "string", "expected 'no such table' error")
        db_b:close()
    end)

    _run_test("multiple handles to same db see same data", function()
        local db_x = assert(lingxi.db.open("shared_probe"))
        db_x:exec("DROP TABLE IF EXISTS shared")
        db_x:exec("CREATE TABLE shared (v INTEGER)")
        db_x:exec("INSERT INTO shared(v) VALUES (?)", { 777 })

        local db_y = assert(lingxi.db.open("shared_probe"))
        local row = assert(db_y:queryOne("SELECT v FROM shared"))
        _assert_eq(row.v, 777, "second handle should see committed data")

        db_x:close()
        db_y:close()
    end)
end

local function test_transactions_manual()
    _current_suite = "transactions.manual"
    -- Phase 1 does not expose db:transaction(fn); use raw BEGIN/COMMIT/ROLLBACK.

    _run_test("manual COMMIT persists changes", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        db:exec("BEGIN")
        db:exec("INSERT INTO t(v) VALUES (1)")
        db:exec("INSERT INTO t(v) VALUES (2)")
        db:exec("COMMIT")
        local rows = assert(db:query("SELECT v FROM t ORDER BY v"))
        _assert_eq(#rows, 2)
        db:close()
    end)

    _run_test("manual ROLLBACK discards changes", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        db:exec("INSERT INTO t(v) VALUES (100)")
        db:exec("BEGIN")
        db:exec("INSERT INTO t(v) VALUES (200)")
        db:exec("INSERT INTO t(v) VALUES (300)")
        db:exec("ROLLBACK")
        local rows = assert(db:query("SELECT v FROM t ORDER BY v"))
        _assert_eq(#rows, 1, "only pre-transaction row should remain")
        _assert_eq(rows[1].v, 100)
        db:close()
    end)
end

local function test_transaction()
    _current_suite = "transaction"

    _run_test("COMMIT on normal return", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        local ok = db:transaction(function()
            db:exec("INSERT INTO t(v) VALUES (1)")
            db:exec("INSERT INTO t(v) VALUES (2)")
        end)
        _assert_eq(ok, true)
        local rows = assert(db:query("SELECT v FROM t"))
        _assert_eq(#rows, 2)
        db:close()
    end)

    _run_test("passes through return values after ok", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        db:exec("INSERT INTO t(v) VALUES (7)")
        local ok, val, note = db:transaction(function()
            local row = assert(db:queryOne("SELECT v FROM t"))
            return row.v, "ok"
        end)
        _assert_eq(ok, true)
        _assert_eq(val, 7)
        _assert_eq(note, "ok")
        db:close()
    end)

    _run_test("ROLLBACK on explicit false return", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        local ok, err = db:transaction(function()
            db:exec("INSERT INTO t(v) VALUES (100)")
            return false, "nope"
        end)
        _assert_eq(ok, false)
        _assert_eq(err, "nope")
        local rows = assert(db:query("SELECT v FROM t"))
        _assert_eq(#rows, 0)
        db:close()
    end)

    _run_test("ROLLBACK + rethrow on Lua error", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        local ok, err = pcall(function()
            db:transaction(function()
                db:exec("INSERT INTO t(v) VALUES (42)")
                error("boom")
            end)
        end)
        _assert_eq(ok, false)
        _assert(tostring(err):find("boom") ~= nil, "error preserved")
        local rows = assert(db:query("SELECT v FROM t"))
        _assert_eq(#rows, 0, "rolled back on raise")
        db:close()
    end)

    _run_test("nested transaction rejected", function()
        local db = _open_clean()
        db:exec("CREATE TABLE t (v INTEGER)")
        local inner_err
        pcall(function()
            db:transaction(function()
                local r_ok, r_err = db:transaction(function() return true end)
                inner_err = r_err
                error(r_err or "no error")
            end)
        end)
        _assert_type(inner_err, "string")
        _assert(inner_err:find("already") ~= nil,
            "inner error should mention 'already': " .. tostring(inner_err))
        db:close()
    end)

    _run_test("rejects non-function argument", function()
        local db = _open_clean()
        local ok, err = db:transaction("not a function")
        _assert_eq(ok, nil)
        _assert_type(err, "string")
        db:close()
    end)
end

local function test_external_demo()
    _current_suite = "external.demo"
    -- Demonstrates that openExternal is permission-gated. This plugin's
    -- manifest does NOT declare db_external_paths, so every call should
    -- be rejected. This is non-functional — only confirms the gate exists.

    _run_test("openExternal is a function", function()
        _assert_type(lingxi.db.openExternal, "function", "openExternal must exist")
    end)

    _run_test("openExternal denied (no db_external_paths)", function()
        local db, err = lingxi.db.openExternal("/tmp/anything.sqlite")
        _assert_eq(db, nil, "expected nil db without whitelist")
        _assert_type(err, "string", "expected error string")
        _assert(err:find("external") ~= nil,
            "error should mention 'external': " .. tostring(err))
    end)

    _run_test("openExternal rejects non-string path", function()
        local db, err = lingxi.db.openExternal(42)
        _assert_eq(db, nil)
        _assert_type(err, "string")
    end)
end

-- ============================================================================
-- Result Reporting
-- ============================================================================

local function _format_results()
    local suites = {}
    local total_passed = 0
    local total_failed = 0

    for _, result in ipairs(_test_results) do
        if not suites[result.suite] then
            suites[result.suite] = { passed = 0, failed = 0, tests = {} }
        end
        table.insert(suites[result.suite].tests, result)
        if result.passed then
            suites[result.suite].passed = suites[result.suite].passed + 1
            total_passed = total_passed + 1
        else
            suites[result.suite].failed = suites[result.suite].failed + 1
            total_failed = total_failed + 1
        end
    end

    return suites, total_passed, total_failed
end

local function _build_result_items()
    local suites, total_passed, total_failed = _format_results()
    local items = {}

    local summary_status = total_failed == 0 and "ALL PASSED" or (total_failed .. " FAILED")
    table.insert(items, {
        title = summary_status,
        subtitle = total_passed .. " passed, " .. total_failed .. " failed across " .. #_test_results .. " tests",
    })

    -- Stable suite order
    local suite_names = {}
    for name in pairs(suites) do table.insert(suite_names, name) end
    table.sort(suite_names)

    for _, suite_name in ipairs(suite_names) do
        local suite_data = suites[suite_name]
        local suite_status = suite_data.failed == 0 and "✓" or "✗"
        table.insert(items, {
            title = suite_status .. " " .. suite_name,
            subtitle = suite_data.passed .. " passed, " .. suite_data.failed .. " failed",
        })
        for _, test in ipairs(suite_data.tests) do
            if not test.passed then
                local error_msg = test.error or "unknown error"
                if #error_msg > 120 then
                    error_msg = error_msg:sub(1, 117) .. "..."
                end
                table.insert(items, {
                    title = "  ✗ " .. test.name,
                    subtitle = error_msg,
                })
            end
        end
    end

    return items
end

local function _format_results_text()
    local suites, total_passed, total_failed = _format_results()
    local lines = {}
    table.insert(lines, "=== lingxi.db API Test Results ===")
    table.insert(lines, "")
    table.insert(lines, "Summary: " .. total_passed .. " passed, " .. total_failed .. " failed")
    table.insert(lines, "")

    local suite_names = {}
    for name in pairs(suites) do table.insert(suite_names, name) end
    table.sort(suite_names)

    for _, suite_name in ipairs(suite_names) do
        local suite_data = suites[suite_name]
        local status = suite_data.failed == 0 and "✓" or "✗"
        table.insert(lines, status .. " " .. suite_name .. " (" .. suite_data.passed .. "/" .. (suite_data.passed + suite_data.failed) .. ")")
        for _, test in ipairs(suite_data.tests) do
            if test.passed then
                table.insert(lines, "  ✓ " .. test.name)
            else
                table.insert(lines, "  ✗ " .. test.name)
                table.insert(lines, "      Error: " .. (test.error or "unknown"))
            end
        end
        table.insert(lines, "")
    end

    return table.concat(lines, "\n")
end

-- ============================================================================
-- Runners
-- ============================================================================

local function run_all()
    _test_results = {}
    test_surface()
    test_open_validation()
    test_ddl_and_dml()
    test_query()
    test_queryOne()
    test_type_mapping()
    test_parameter_binding()
    test_errors()
    test_lifecycle()
    test_persistence()
    test_transactions_manual()
    test_transaction()
    test_external_demo()
    return _build_result_items()
end

local _subsuites = {
    surface        = test_surface,
    validation     = test_open_validation,
    ddl            = test_ddl_and_dml,
    query          = test_query,
    queryone       = test_queryOne,
    types          = test_type_mapping,
    params         = test_parameter_binding,
    errors         = test_errors,
    lifecycle      = test_lifecycle,
    persistence    = test_persistence,
    manualtx       = test_transactions_manual,
    transaction    = test_transaction,
    external       = test_external_demo,
}

local function run_subsuite(key)
    _test_results = {}
    _subsuites[key]()
    return _build_result_items()
end

-- ============================================================================
-- Public API
-- ============================================================================

function search(query)
    query = query or ""
    query = query:gsub("^%s*test%-db%s*", ""):gsub("^%s*", ""):gsub("%s*$", "")

    if query == "" or query == "help" then
        return {
            { title = "test-db run",         subtitle = "Run all lingxi.db tests" },
            { title = "test-db surface",     subtitle = "Test API surface: table & method shapes" },
            { title = "test-db validation",  subtitle = "Test open() name validation" },
            { title = "test-db ddl",         subtitle = "Test CREATE/INSERT/UPDATE/DELETE" },
            { title = "test-db query",       subtitle = "Test query() result shape & ordering" },
            { title = "test-db queryone",    subtitle = "Test queryOne() single-row behavior" },
            { title = "test-db types",       subtitle = "Test INTEGER/REAL/TEXT/NULL/bool mapping" },
            { title = "test-db params",      subtitle = "Test parameter binding edge cases" },
            { title = "test-db errors",      subtitle = "Test error paths (bad SQL, constraint, etc)" },
            { title = "test-db lifecycle",   subtitle = "Test close/__gc/double-close" },
            { title = "test-db persistence", subtitle = "Test data survival & DB isolation" },
            { title = "test-db transaction", subtitle = "Test db:transaction(fn) commit/rollback semantics" },
            { title = "test-db manualtx",    subtitle = "Test manual BEGIN/COMMIT/ROLLBACK via exec" },
            { title = "test-db external",    subtitle = "Demo: openExternal permission gate (no whitelist)" },
            { title = "test-db:run-all",     subtitle = "Command: Run full test suite (copies to clipboard)" },
            { title = "test-db:clear-results", subtitle = "Command: Clear all test results" },
        }
    end

    if query == "run" or query == "all" then
        return run_all()
    end

    if _subsuites[query] then
        return run_subsuite(query)
    end

    return {
        { title = "Unknown command: " .. query, subtitle = "Type 'test-db help' for available commands" },
    }
end

function cmd_run_all(args)
    local items = run_all()
    local _, total_passed, total_failed = _format_results()

    if total_failed == 0 then
        lingxi.alert.show("All " .. total_passed .. " DB tests passed!", 2.0)
    else
        lingxi.alert.show(total_failed .. " DB tests failed out of " .. (total_passed + total_failed), 3.0)
    end

    local text = _format_results_text()
    lingxi.clipboard.write(text)

    local summary_text = total_failed == 0
        and "All tests passed!"
        or (total_failed .. " failed, " .. total_passed .. " passed")
    table.insert(items, 1, {
        title = "✅ Results copied to clipboard",
        subtitle = summary_text .. " - Paste anywhere to see full details",
    })

    return items
end

function cmd_clear_results(args)
    _test_results = {}
    lingxi.alert.show("DB test results cleared", 1.5)
    return { { title = "Results cleared", subtitle = "All test history has been reset" } }
end
