-- API Showcase Plugin
-- Demonstrates every LingXi plugin API and capability.
-- This is a reference implementation for plugin developers.

-- ============================================================================
-- Utility Functions
-- ============================================================================

--- Format a number with commas for readability
local function format_number(n)
    local s = tostring(n)
    local result = ""
    local count = 0
    for i = #s, 1, -1 do
        if count > 0 and count % 3 == 0 then
            result = "," .. result
        end
        result = s:sub(i, i) .. result
        count = count + 1
    end
    return result
end

--- Get current timestamp as ISO 8601 string
local function iso_timestamp()
    local result = lingxi.shell.exec("date -u +%Y-%m-%dT%H:%M:%SZ")
    if result.exitCode == 0 then
        return result.stdout:gsub("%s+$", "")
    end
    return "unknown"
end

--- Increment a counter in the plugin store
local function increment_counter(key)
    local raw = lingxi.store.get(key)
    local current = 0
    if type(raw) == "number" then
        current = raw
    elseif type(raw) == "boolean" then
        -- Previously stored as boolean due to CFNumberGetType bug; clean up and restart
        lingxi.store.delete(key)
        current = 0
    end
    local ok = lingxi.store.set(key, current + 1)
    lingxi.log.write("[increment_counter] key=" .. key .. " old=" .. current .. " new=" .. (current + 1) .. " ok=" .. tostring(ok))
    return current + 1
end

--- Get a counter value from the plugin store
local function get_counter(key)
    local value = lingxi.store.get(key)
    if type(value) == "number" then
        lingxi.log.write("[get_counter] key=" .. key .. " value=" .. value)
        return value
    elseif type(value) == "boolean" then
        -- Previously stored as boolean due to CFNumberGetType bug; clean up
        lingxi.store.delete(key)
        lingxi.log.write("[get_counter] key=" .. key .. " boolean value (legacy) -> delete and return 0")
        return 0
    end
    return 0
end

-- ============================================================================
-- Search Provider
-- ============================================================================

--- Main search function. Returns results based on the query.
-- Available subcommands:
--   "http"     - HTTP request demonstration
--   "clip"     - Clipboard read/write demonstration
--   "file"     - Filesystem operations demonstration
--   "shell"    - Shell command execution demonstration
--   "store"    - Persistent store demonstration
--   "notify"   - Notification demonstration
--   "alert"    - Toast alert demonstration
--   "event"    - Event system information
--   "stats"    - Runtime statistics
--   "help"     - List all available commands
function search(query)
    query = query or ""
    query = query:gsub("^%s*api%s*", ""):gsub("^%s*", ""):gsub("%s*$", "")

    -- Track search invocations
    increment_counter("searches")

    if query == "" or query == "help" then
        return show_help()
    elseif query == "http" then
        return demo_http()
    elseif query == "clip" or query == "clipboard" then
        return demo_clipboard()
    elseif query == "file" or query == "fs" then
        return demo_filesystem()
    elseif query == "shell" or query == "cmd" then
        return demo_shell()
    elseif query == "store" or query == "persist" then
        return demo_store()
    elseif query == "notify" or query == "notification" then
        return demo_notify()
    elseif query == "alert" or query == "toast" then
        return demo_alert()
    elseif query == "event" or query == "events" then
        return demo_events()
    elseif query == "stats" or query == "status" then
        return demo_stats()
    else
        return {
            {
                title = "Unknown command: " .. query,
                subtitle = "Type 'api help' to see all available demonstrations",
            }
        }
    end
end

-- ============================================================================
-- Demonstration Functions
-- ============================================================================

--- Show help with all available demonstrations
function show_help()
    return {
        { title = "api http", subtitle = "Demonstrate HTTP GET/POST requests" },
        { title = "api clip", subtitle = "Demonstrate clipboard read/write operations" },
        { title = "api file", subtitle = "Demonstrate filesystem read/write/list operations" },
        { title = "api shell", subtitle = "Demonstrate shell command execution" },
        { title = "api store", subtitle = "Demonstrate persistent key-value storage" },
        { title = "api notify", subtitle = "Demonstrate system notifications" },
        { title = "api alert", subtitle = "Demonstrate toast alert messages" },
        { title = "api event", subtitle = "Show event system information and handlers" },
        { title = "api stats", subtitle = "Show plugin runtime statistics" },
        { title = "api:stats", subtitle = "Command: Display detailed runtime statistics" },
        { title = "api:clear", subtitle = "Command: Clear all stored plugin data" },
        { title = "api:notify", subtitle = "Command: Send a test notification" },
    }
end

--- Demonstrate HTTP API: lingxi.http.get and lingxi.http.post
function demo_http()
    increment_counter("http_demos")

    -- Perform a GET request to httpbin.org
    local response = lingxi.http.get("https://httpbin.org/get")

    local status_info = "Status: " .. tostring(response.status)
    if response.status == 200 then
        status_info = status_info .. " (OK)"
    else
        status_info = status_info .. " (Failed)"
    end

    return {
        { title = "HTTP GET Request", subtitle = status_info },
        { title = "Response Body Preview", subtitle = response.body:sub(1, 80):gsub("\n", " ") .. "..." },
        { title = "Response Headers Count", subtitle = tostring(count_headers(response.headers)) .. " headers received" },
        { title = "HTTP API Usage", subtitle = "lingxi.http.get(url [, headers_table])" },
        { title = "HTTP POST Usage", subtitle = "lingxi.http.post(url, body [, content_type])" },
    }
end

--- Count headers in response
function count_headers(headers)
    local count = 0
    for _ in pairs(headers) do
        count = count + 1
    end
    return count
end

--- Demonstrate Clipboard API: lingxi.clipboard.read and lingxi.clipboard.write
function demo_clipboard()
    increment_counter("clipboard_demos")

    -- Read current clipboard content
    local content = lingxi.clipboard.read()
    local preview = content or "(empty)"
    if #preview > 60 then
        preview = preview:sub(1, 60) .. "..."
    end

    return {
        { title = "Clipboard Read", subtitle = "Content: " .. preview },
        { title = "Clipboard Write", subtitle = "lingxi.clipboard.write(text) -> boolean" },
        { title = "Write Demo Text", subtitle = "Click to copy sample text to clipboard", action = "action_clipboard_write" },
    }
end

--- Demonstrate Filesystem API: lingxi.file.read, write, list, exists
function demo_filesystem()
    increment_counter("file_demos")

    -- Write a test file in a temporary directory
    local test_dir = "/tmp/lingxi-api-showcase"
    local test_file = test_dir .. "/demo.txt"
    lingxi.file.write(test_file, "Hello from API Showcase plugin!\nCreated at: " .. iso_timestamp())

    -- Read it back
    local content = lingxi.file.read(test_file) or "(failed to read)"
    local file_exists = lingxi.file.exists(test_file)

    -- List directory
    local entries = lingxi.file.list(test_dir) or {}
    local entry_count = #entries

    return {
        { title = "File Write", subtitle = "lingxi.file.write(path, content) -> boolean" },
        { title = "File Read", subtitle = "Content: " .. content:gsub("\n", " "):sub(1, 60) },
        { title = "File Exists", subtitle = test_file .. " exists: " .. tostring(file_exists) },
        { title = "Directory List", subtitle = test_dir .. " contains " .. entry_count .. " entries" },
        { title = "File API Summary", subtitle = "read | write | list | exists (all sandboxed)" },
    }
end

--- Demonstrate Shell API: lingxi.shell.exec
function demo_shell()
    increment_counter("shell_demos")

    -- Execute a safe command: get system info
    local result = lingxi.shell.exec("sw_vers")

    local exit_info = "Exit code: " .. tostring(result.exitCode)
    local output_preview = result.stdout:gsub("\n", " "):sub(1, 60)
    if #result.stdout == 0 then
        output_preview = result.stderr:gsub("\n", " "):sub(1, 60)
    end

    return {
        { title = "Shell Execution", subtitle = exit_info },
        { title = "Output Preview", subtitle = output_preview },
        { title = "Shell API Usage", subtitle = "lingxi.shell.exec(cmd) -> {exitCode, stdout, stderr}" },
        { title = "Whitelisted Commands", subtitle = "Only 'date' and 'sw_vers' are permitted" },
    }
end

--- Demonstrate Store API: lingxi.store.get, set, delete
function demo_store()
    increment_counter("store_demos")

    -- Set a demo value
    lingxi.store.set("demo_key", "Hello from store! " .. iso_timestamp())

    -- Retrieve it
    local value = lingxi.store.get("demo_key") or "(not found)"

    -- Show all store keys for this plugin
    local keys = list_store_keys()

    return {
        { title = "Store Set", subtitle = "lingxi.store.set(key, value) -> boolean" },
        { title = "Store Get", subtitle = "Value: " .. tostring(value):sub(1, 60) },
        { title = "Store Delete", subtitle = "lingxi.store.delete(key) -> boolean" },
        { title = "Stored Keys", subtitle = #keys .. " keys in plugin namespace" },
        { title = "Store API Summary", subtitle = "get | set | delete (isolated per plugin)" },
    }
end

--- List all store keys for this plugin (best effort)
function list_store_keys()
    -- StoreManager does not provide enumeration, so we track known keys manually
    local known_keys = {
        "demo_key",
        "searches",
        "http_demos",
        "clipboard_demos",
        "file_demos",
        "shell_demos",
        "store_demos",
        "notify_demos",
        "alert_demos",
        "event_count_clipboard",
        "event_count_search",
        "event_count_screenshot",
        "last_event",
    }
    local existing = {}
    for _, key in ipairs(known_keys) do
        if lingxi.store.get(key) ~= nil then
            table.insert(existing, key)
        end
    end
    return existing
end

--- Demonstrate Notify API: lingxi.notify.send
function demo_notify()
    increment_counter("notify_demos")

    -- Send a test notification
    local ok = lingxi.notify.send("API Showcase", "This is a test notification from the plugin!")

    return {
        { title = "Notification Sent", subtitle = "Result: " .. tostring(ok) },
        { title = "Notify API Usage", subtitle = "lingxi.notify.send(title, message) -> boolean" },
        { title = "Permission Required", subtitle = "notify = true in plugin.toml" },
    }
end

--- Demonstrate Alert/Toast API: lingxi.alert.show
function demo_alert()
    increment_counter("alert_demos")

    -- Show a toast
    local ok = lingxi.alert.show("Hello from API Showcase plugin!", 3.0)

    return {
        { title = "Toast Shown", subtitle = "Result: " .. tostring(ok) },
        { title = "Alert API Usage", subtitle = "lingxi.alert.show(text, duration?) -> boolean" },
        { title = "Default Duration", subtitle = "2.0 seconds if not specified" },
    }
end

--- Show event system information
function demo_events()
    increment_counter("event_demos")

    local clipboard_count = get_counter("event_count_clipboard")
    local search_count = get_counter("event_count_search")
    local screenshot_count = get_counter("event_count_screenshot")
    local last_event = lingxi.store.get("last_event") or "none"

    return {
        { title = "Event: clipboard_change", subtitle = "Received " .. clipboard_count .. " times" },
        { title = "Event: search_activate", subtitle = "Received " .. search_count .. " times" },
        { title = "Event: screenshot_captured", subtitle = "Received " .. screenshot_count .. " times" },
        { title = "Last Event", subtitle = "Last received: " .. tostring(last_event):sub(1, 60) },
        { title = "Handler Pattern", subtitle = "function on_clipboard_change(data) ... end" },
        { title = "Generic Handler", subtitle = "function on_event(name, data) ... end" },
    }
end

--- Show runtime statistics
function demo_stats()
    local stats = {
        searches = get_counter("searches"),
        http = get_counter("http_demos"),
        clipboard = get_counter("clipboard_demos"),
        file = get_counter("file_demos"),
        shell = get_counter("shell_demos"),
        store = get_counter("store_demos"),
        notify = get_counter("notify_demos"),
        alert = get_counter("alert_demos"),
        events = get_counter("event_count_clipboard") + get_counter("event_count_search") + get_counter("event_count_screenshot"),
    }

    return {
        { title = "Total Searches", subtitle = format_number(stats.searches) },
        { title = "HTTP Demos", subtitle = format_number(stats.http) },
        { title = "Clipboard Demos", subtitle = format_number(stats.clipboard) },
        { title = "Filesystem Demos", subtitle = format_number(stats.file) },
        { title = "Shell Demos", subtitle = format_number(stats.shell) },
        { title = "Store Demos", subtitle = format_number(stats.store) },
        { title = "Notification Demos", subtitle = format_number(stats.notify) },
        { title = "Alert Demos", subtitle = format_number(stats.alert) },
        { title = "Total Events", subtitle = format_number(stats.events) },
    }
end

-- ============================================================================
-- Command Actions
-- ============================================================================

--- Command: Show detailed statistics
function cmd_stats(args)
    local stats = {
        searches = get_counter("searches"),
        http = get_counter("http_demos"),
        clipboard = get_counter("clipboard_demos"),
        file = get_counter("file_demos"),
        shell = get_counter("shell_demos"),
        store = get_counter("store_demos"),
        notify = get_counter("notify_demos"),
        alert = get_counter("alert_demos"),
        events = get_counter("event_count_clipboard") + get_counter("event_count_search") + get_counter("event_count_screenshot"),
    }

    local lines = {
        "=== API Showcase Statistics ===",
        "",
        "Total Searches:     " .. format_number(stats.searches),
        "HTTP Demos:         " .. format_number(stats.http),
        "Clipboard Demos:    " .. format_number(stats.clipboard),
        "Filesystem Demos:   " .. format_number(stats.file),
        "Shell Demos:        " .. format_number(stats.shell),
        "Store Demos:        " .. format_number(stats.store),
        "Notification Demos: " .. format_number(stats.notify),
        "Alert Demos:        " .. format_number(stats.alert),
        "Total Events:       " .. format_number(stats.events),
        "",
        "Current Time:       " .. iso_timestamp(),
    }

    local text = table.concat(lines, "\n")
    lingxi.clipboard.write(text)
    lingxi.alert.show("Statistics copied to clipboard!", 2.0)

    return { { title = "Statistics copied to clipboard", subtitle = "Use cmd+v to paste" } }
end

--- Command: Clear all plugin data
function cmd_clear(args)
    -- Delete all known keys
    local keys = {
        "searches", "http_demos", "clipboard_demos", "file_demos",
        "shell_demos", "store_demos", "notify_demos", "alert_demos",
        "event_count_clipboard", "event_count_search", "event_count_screenshot",
        "last_event", "demo_key",
    }

    for _, key in ipairs(keys) do
        lingxi.store.delete(key)
    end

    lingxi.alert.show("All plugin data cleared!", 2.0)
    return { { title = "Plugin data cleared", subtitle = "All counters and stored values reset" } }
end

--- Command: Send test notification
function cmd_notify(args)
    increment_counter("notify_demos")
    local ok = lingxi.notify.send("API Showcase", "Test notification triggered by command!")
    return { { title = "Notification sent", subtitle = "Result: " .. tostring(ok) } }
end

-- ============================================================================
-- Search Action Handlers
-- ============================================================================

--- Handle "Write Demo Text" action from clipboard demo
function action_clipboard_write(args)
    local text = "Hello from API Showcase! This text was written by the plugin at " .. iso_timestamp()
    local ok = lingxi.clipboard.write(text)
    lingxi.alert.show("Demo text copied to clipboard!", 2.0)
    return { { title = "Copied to clipboard", subtitle = "Result: " .. tostring(ok) } }
end

-- ============================================================================
-- Event Handlers
-- ============================================================================

--- Handle clipboard_change events
function on_clipboard_change(data)
    increment_counter("event_count_clipboard")
    lingxi.store.set("last_event", "clipboard_change")

    local content_type = data.type or "unknown"
    if content_type == "text" then
        local text = data.text or ""
        if #text > 50 then
            text = text:sub(1, 50) .. "..."
        end
        -- Silently track, don't spam user
    elseif content_type == "image" then
        local path = data.image_path or ""
        -- Silently track
    end
end

--- Handle search_activate events
function on_search_activate(data)
    increment_counter("event_count_search")
    lingxi.store.set("last_event", "search_activate")
end

--- Handle screenshot_captured events
function on_screenshot_captured(data)
    increment_counter("event_count_screenshot")
    lingxi.store.set("last_event", "screenshot_captured")

    local screenshot_type = data.type or "unknown"
    local path = data.path or ""
    -- Silently track
end

--- Generic event fallback handler
function on_event(event_name, data)
    -- Fallback for any events not handled by specific handlers
    -- Currently all known events have specific handlers above
end
