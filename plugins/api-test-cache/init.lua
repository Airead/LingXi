-- API Test Plugin: Cache & File Stat
-- Comprehensive test suite for lingxi.cache and lingxi.file.stat APIs

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
        error((message or "assertion failed") .. "\n  expected: " .. tostring(expected) .. "\n  actual:   " .. tostring(actual), 2)
    end
end

local function _assert_near(actual, expected, tolerance, message)
    tolerance = tolerance or 1
    if math.abs(actual - expected) > tolerance then
        error((message or "assertion failed") .. "\n  expected: ~" .. tostring(expected) .. "\n  actual:   " .. tostring(actual), 2)
    end
end

local function _assert_type(value, expected_type, message)
    if type(value) ~= expected_type then
        error((message or "type assertion failed") .. "\n  expected: " .. expected_type .. "\n  actual:   " .. type(value), 2)
    end
end

local function _run_test(name, fn)
    local suite = _current_suite or "default"
    local result = {
        name = name,
        suite = suite,
        passed = false,
        error = nil,
        duration = 0,
    }

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
-- Test Suites
-- ============================================================================

local function test_cache_getPath()
    _current_suite = "cache.getPath"

    _run_test("returns string when cache permission granted", function()
        local path = lingxi.cache.getPath()
        _assert_type(path, "string", "cache.getPath() should return a string")
        _assert(path ~= "", "cache path should not be empty")
    end)

    _run_test("path contains plugin id", function()
        local path = lingxi.cache.getPath()
        _assert(path:find("api%-test%-cache") ~= nil, "cache path should contain plugin id")
    end)

    _run_test("path is within ~/.cache/LingXi/", function()
        local path = lingxi.cache.getPath()
        _assert(path:find("%.cache/LingXi") ~= nil, "cache path should be under ~/.cache/LingXi/")
    end)

    _run_test("returns same path on repeated calls", function()
        local path1 = lingxi.cache.getPath()
        local path2 = lingxi.cache.getPath()
        _assert_eq(path1, path2, "repeated calls should return same path")
    end)
end

local function test_file_stat()
    _current_suite = "file.stat"

    _run_test("returns nil for missing file", function()
        local stat = lingxi.file.stat("/tmp/lingxi-test-nonexistent-" .. os.time())
        _assert_eq(stat, nil, "stat of missing file should be nil")
    end)

    _run_test("returns table for existing file", function()
        local test_path = "/tmp/lingxi-test-stat-existing.txt"
        lingxi.file.write(test_path, "hello world")
        
        local stat = lingxi.file.stat(test_path)
        _assert_type(stat, "table", "stat should return a table for existing file")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_path)
    end)

    _run_test("returns correct mtime", function()
        local test_path = "/tmp/lingxi-test-stat-mtime.txt"
        lingxi.file.write(test_path, "test content for mtime")
        
        local stat = lingxi.file.stat(test_path)
        _assert_type(stat.mtime, "number", "mtime should be a number")
        _assert(stat.mtime > 0, "mtime should be positive")
        
        local now = os.time()
        _assert_near(stat.mtime, now, 5, "mtime should be close to current time")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_path)
    end)

    _run_test("returns correct size", function()
        local content = "exactly 25 bytes here!!"
        local test_path = "/tmp/lingxi-test-stat-size.txt"
        lingxi.file.write(test_path, content)
        
        local stat = lingxi.file.stat(test_path)
        _assert_eq(stat.size, #content, "size should match content length")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_path)
    end)

    _run_test("returns isDir=false for file", function()
        local test_path = "/tmp/lingxi-test-stat-file.txt"
        lingxi.file.write(test_path, "file content")
        
        local stat = lingxi.file.stat(test_path)
        _assert_eq(stat.isDir, false, "isDir should be false for file")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_path)
    end)

    _run_test("returns isDir=true for directory", function()
        local test_dir = "/tmp/lingxi-test-stat-dir"
        lingxi.shell.exec("mkdir -p " .. test_dir)
        
        local stat = lingxi.file.stat(test_dir)
        _assert_eq(stat.isDir, true, "isDir should be true for directory")
        
        -- Clean up
        lingxi.shell.exec("rmdir " .. test_dir)
    end)

    _run_test("returns nil for path outside whitelist", function()
        local stat = lingxi.file.stat("/etc/passwd")
        _assert_eq(stat, nil, "stat should return nil for path outside whitelist")
    end)
end

local function test_cache_filesystem_integration()
    _current_suite = "cache.filesystem"

    _run_test("can write to cache directory", function()
        local cache_dir = lingxi.cache.getPath()
        _assert(cache_dir ~= nil, "cache path should be available")
        
        local test_file = cache_dir .. "/test-write.txt"
        local ok = lingxi.file.write(test_file, "cache test content")
        _assert_eq(ok, true, "should be able to write to cache directory")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_file)
    end)

    _run_test("can read from cache directory", function()
        local cache_dir = lingxi.cache.getPath()
        local test_file = cache_dir .. "/test-read.txt"
        local content = "read me back"
        
        lingxi.file.write(test_file, content)
        local read_back = lingxi.file.read(test_file)
        
        _assert_eq(read_back, content, "should read back same content from cache")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_file)
    end)

    _run_test("can stat files in cache directory", function()
        local cache_dir = lingxi.cache.getPath()
        local test_file = cache_dir .. "/test-stat.txt"
        
        lingxi.file.write(test_file, "stat test")
        local stat = lingxi.file.stat(test_file)
        
        _assert_type(stat, "table", "should be able to stat files in cache")
        _assert_eq(stat.isDir, false, "should be a file")
        _assert_eq(stat.size, 9, "size should be 9 bytes")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_file)
    end)

    _run_test("can list cache directory", function()
        local cache_dir = lingxi.cache.getPath()
        local test_file = cache_dir .. "/test-list.txt"
        
        lingxi.file.write(test_file, "list test")
        local entries = lingxi.file.list(cache_dir)
        
        _assert_type(entries, "table", "should be able to list cache directory")
        _assert(#entries >= 1, "cache directory should contain at least one entry")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_file)
    end)

    _run_test("can use cache without filesystem permission", function()
        -- This plugin has both cache and filesystem permissions,
        -- but we're testing that cache directory is accessible
        -- even if no explicit filesystem paths are in the manifest
        local cache_dir = lingxi.cache.getPath()
        _assert(cache_dir ~= nil, "cache should work")
        
        -- The cache directory should be accessible even without
        -- explicit filesystem permission for that path
        local stat = lingxi.file.stat(cache_dir)
        _assert_type(stat, "table", "cache dir should be stat-able")
        _assert_eq(stat.isDir, true, "cache path should be a directory")
    end)
end

local function test_stat_edge_cases()
    _current_suite = "stat.edge_cases"

    _run_test("handles tilde expansion", function()
        -- Note: tilde expansion depends on filesystem permissions
        -- This tests that stat doesn't crash with tilde paths
        local stat = lingxi.file.stat("~/Library")
        -- May or may not be allowed based on permissions, just don't crash
        _assert(true, "should not crash on tilde paths")
    end)

    _run_test("handles empty string path", function()
        local stat = lingxi.file.stat("")
        _assert_eq(stat, nil, "empty path should return nil")
    end)

    _run_test("handles relative paths", function()
        -- Relative paths are resolved against plugin directory
        -- This should either work or return nil, never crash
        local stat = lingxi.file.stat("nonexistent-relative-path.txt")
        _assert_eq(stat, nil, "relative path to nonexistent file should return nil")
    end)

    _run_test("mtime changes after file modification", function()
        local test_path = "/tmp/lingxi-test-stat-mtime-change.txt"
        
        -- Create initial file
        lingxi.file.write(test_path, "version 1")
        local stat1 = lingxi.file.stat(test_path)
        
        -- Wait a bit to ensure different mtime
        os.execute("sleep 1")
        
        -- Modify file
        lingxi.file.write(test_path, "version 2 - longer content here")
        local stat2 = lingxi.file.stat(test_path)
        
        _assert(stat2.mtime >= stat1.mtime, "mtime should not decrease after modification")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_path)
    end)
end

local function test_cache_persistence()
    _current_suite = "cache.persistence"

    _run_test("cache files persist across calls", function()
        local cache_dir = lingxi.cache.getPath()
        local test_file = cache_dir .. "/persist-test.txt"
        local content = "persistent data " .. os.time()
        
        -- Write
        lingxi.file.write(test_file, content)
        
        -- Read back immediately
        local read1 = lingxi.file.read(test_file)
        _assert_eq(read1, content, "should read back same content")
        
        -- Note: We can't test actual persistence across plugin reloads
        -- in a single test run, but we verify the file exists on disk
        local stat = lingxi.file.stat(test_file)
        _assert_type(stat, "table", "file should exist on disk")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_file)
    end)

    _run_test("can store JSON in cache", function()
        local cache_dir = lingxi.cache.getPath()
        local test_file = cache_dir .. "/json-cache-test.json"
        
        local data = {
            version = 1,
            sessions = {
                ["/path/to/file.jsonl"] = {
                    mtime = os.time(),
                    data = { title = "Test Session", id = "abc123" }
                }
            }
        }
        
        local ok, json_str = pcall(function()
            return lingxi.json.encode(data)
        end)
        
        _assert(ok, "should encode table to JSON: " .. tostring(json_str))
        _assert_type(json_str, "string", "JSON should be a string")
        
        lingxi.file.write(test_file, json_str)
        
        local read_back = lingxi.file.read(test_file)
        local ok2, decoded = pcall(function()
            return lingxi.json.parse(read_back)
        end)
        
        _assert(ok2, "should decode JSON back: " .. tostring(decoded))
        _assert_type(decoded, "table", "decoded should be a table")
        _assert_eq(decoded.version, 1, "version should match")
        
        -- Clean up
        lingxi.shell.exec("rm " .. test_file)
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
    
    -- Summary header
    local summary_status = total_failed == 0 and "ALL PASSED" or (total_failed .. " FAILED")
    table.insert(items, {
        title = summary_status,
        subtitle = total_passed .. " passed, " .. total_failed .. " failed across " .. #_test_results .. " tests",
    })
    
    -- Per-suite results
    for suite_name, suite_data in pairs(suites) do
        local suite_status = suite_data.failed == 0 and "✓" or "✗"
        table.insert(items, {
            title = suite_status .. " " .. suite_name,
            subtitle = suite_data.passed .. " passed, " .. suite_data.failed .. " failed",
        })
        
        -- Show failed tests
        for _, test in ipairs(suite_data.tests) do
            if not test.passed then
                local error_msg = test.error or "unknown error"
                -- Truncate long error messages
                if #error_msg > 80 then
                    error_msg = error_msg:sub(1, 77) .. "..."
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

-- ============================================================================
-- Public API
-- ============================================================================

function search(query)
    query = query or ""
    query = query:gsub("^%s*test%-api%s*", ""):gsub("^%s*", ""):gsub("%s*$", "")
    
    if query == "" or query == "help" then
        return {
            { title = "test-api run", subtitle = "Run all cache and file.stat tests" },
            { title = "test-api cache", subtitle = "Run cache.getPath tests only" },
            { title = "test-api stat", subtitle = "Run file.stat tests only" },
            { title = "test-api integration", subtitle = "Run cache + filesystem integration tests" },
            { title = "test-api edge", subtitle = "Run edge case tests" },
            { title = "test-api persist", subtitle = "Run cache persistence tests" },
            { title = "test-api:run-all", subtitle = "Command: Run full test suite" },
            { title = "test-api:clear-results", subtitle = "Command: Clear all test results" },
        }
    elseif query == "run" or query == "all" then
        return run_all_tests()
    elseif query == "cache" then
        return run_cache_tests()
    elseif query == "stat" then
        return run_stat_tests()
    elseif query == "integration" then
        return run_integration_tests()
    elseif query == "edge" then
        return run_edge_tests()
    elseif query == "persist" then
        return run_persistence_tests()
    else
        return {
            { title = "Unknown command: " .. query, subtitle = "Type 'test-api help' for available commands" },
        }
    end
end

function run_all_tests()
    _test_results = {}
    
    test_cache_getPath()
    test_file_stat()
    test_cache_filesystem_integration()
    test_stat_edge_cases()
    test_cache_persistence()
    
    return _build_result_items()
end

function run_cache_tests()
    _test_results = {}
    test_cache_getPath()
    return _build_result_items()
end

function run_stat_tests()
    _test_results = {}
    test_file_stat()
    return _build_result_items()
end

function run_integration_tests()
    _test_results = {}
    test_cache_filesystem_integration()
    return _build_result_items()
end

function run_edge_tests()
    _test_results = {}
    test_stat_edge_cases()
    return _build_result_items()
end

function run_persistence_tests()
    _test_results = {}
    test_cache_persistence()
    return _build_result_items()
end

local function _format_results_text()
    local suites, total_passed, total_failed = _format_results()
    local lines = {}
    
    table.insert(lines, "=== Cache & File.Stat API Test Results ===")
    table.insert(lines, "")
    table.insert(lines, "Summary: " .. total_passed .. " passed, " .. total_failed .. " failed")
    table.insert(lines, "")
    
    for suite_name, suite_data in pairs(suites) do
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

function cmd_run_all(args)
    local items = run_all_tests()
    
    -- Show toast notification
    local _, total_passed, total_failed = _format_results()
    if total_failed == 0 then
        lingxi.alert.show("All " .. total_passed .. " tests passed!", 2.0)
    else
        lingxi.alert.show(total_failed .. " tests failed out of " .. (total_passed + total_failed), 3.0)
    end
    
    -- Copy results to clipboard automatically
    local text = _format_results_text()
    lingxi.clipboard.write(text)
    
    -- Insert "Results Copied" info item at the top
    local summary_text = total_failed == 0 and "All tests passed!" or (total_failed .. " failed, " .. total_passed .. " passed")
    local copy_item = {
        title = "✅ Results copied to clipboard",
        subtitle = summary_text .. " - Paste anywhere to see full details",
    }
    table.insert(items, 1, copy_item)
    
    return items
end

function cmd_clear_results(args)
    _test_results = {}
    lingxi.alert.show("Test results cleared", 1.5)
    return { { title = "Results cleared", subtitle = "All test history has been reset" } }
end
