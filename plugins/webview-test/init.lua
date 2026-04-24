-- WebView Test Plugin
-- Manual verification of lingxi.webview.* API

local _current_html_path = nil

-- ============================================================================
-- Search Provider
-- ============================================================================

function search(query)
    query = query or ""
    query = query:gsub("^%s*wv%s*", ""):gsub("^%s*", ""):gsub("%s*$", "")

    return {
        {
            title = "Open WebView Test",
            subtitle = "Open the WebView test page",
            action = function()
                _open_test_page()
            end,
        },
        {
            title = "Send Test Message",
            subtitle = "Send a message from Lua to JS (requires open WebView)",
            action = function()
                _send_test_message()
            end,
        },
        {
            title = "Close WebView",
            subtitle = "Close the active WebView window",
            action = function()
                lingxi.webview.close()
                lingxi.alert.show("WebView closed", 1.5)
            end,
        },
        {
            title = "WebView API Help",
            subtitle = "Show available test commands",
            action = function()
                -- No-op, just shows the result
            end,
        },
    }
end

-- ============================================================================
-- WebView Operations
-- ============================================================================

function _open_test_page()
    -- Register message handler before opening
    lingxi.webview.on_message(function(data)
        _handle_webview_message(data)
    end)

    local ok = lingxi.webview.open("test.html", {
        title = "WebView API Test",
        width = 900,
        height = 700,
    })

    if ok then
        lingxi.alert.show("WebView opened!", 1.5)
        _current_html_path = "test.html"
    else
        lingxi.alert.show("Failed to open WebView", 2.0)
    end
end

function _send_test_message()
    local message = {
        action = "lua_message",
        timestamp = os.time(),
        data = "Hello from Lua! This message was sent via lingxi.webview.send()",
        random = math.random(1000, 9999),
    }

    local json_str = _encode_json(message)
    lingxi.webview.send(json_str)
    lingxi.alert.show("Message sent to WebView", 1.5)
end

-- ============================================================================
-- Message Handler
-- ============================================================================

function _handle_webview_message(data)
    -- data is a JSON string from JS
    local parsed = lingxi.json.parse(data)
    if not parsed then
        lingxi.log.write("[WebViewTest] Failed to parse message: " .. tostring(data))
        return
    end

    local action = parsed.action

    if action == "init" then
        -- WebView loaded, send initial data
        lingxi.log.write("[WebViewTest] Received init from WebView")
        local response = {
            action = "session_data",
            info = {
                title = "WebView Test",
                version = "1.0.0",
                features = {"markdown", "code_highlight", "bidirectional_comm"},
            },
            messages = {
                {
                    role = "assistant",
                    content = "WebView is ready! You can now test the bidirectional communication.",
                },
                {
                    role = "user",
                    content = "How do I test it?",
                },
                {
                    role = "assistant",
                    content = [[
Use the buttons below to test different features:

1. **Send "init"** - Simulates the viewer initialization
2. **Send "copy"** - Tests clipboard integration
3. **Send "close"** - Tests window close from JS
4. **Send "custom"** - Sends a custom message to Lua

You can also use the LingXi search panel to send messages from Lua to JS.
                    ]],
                },
            },
        }
        lingxi.webview.send(_encode_json(response))
        lingxi.alert.show("WebView initialized", 1.5)

    elseif action == "copy" then
        local text = parsed.text or ""
        if text ~= "" then
            lingxi.clipboard.write(text)
            lingxi.alert.show("Copied to clipboard: " .. text:sub(1, 30), 2.0)
        end

    elseif action == "close" then
        lingxi.webview.close()
        lingxi.alert.show("WebView closed by JS", 1.5)

    elseif action == "custom" then
        local payload = parsed.payload or {}
        lingxi.log.write("[WebViewTest] Custom message: " .. tostring(payload.message or "empty"))
        lingxi.alert.show("Custom message received!", 1.5)

        -- Echo back
        local response = {
            action = "lua_message",
            data = "Echo: " .. tostring(payload.message or "empty"),
        }
        lingxi.webview.send(_encode_json(response))

    else
        lingxi.log.write("[WebViewTest] Unknown action: " .. tostring(action))
    end
end

-- ============================================================================
-- Commands
-- ============================================================================

function cmd_send(args)
    _send_test_message()
    return {
        {
            title = "Message sent",
            subtitle = "Check the WebView window for the message",
        }
    }
end

-- ============================================================================
-- Helpers
-- ============================================================================

function _encode_json(obj)
    -- Simple JSON encoder for basic types
    if type(obj) == "table" then
        local items = {}
        local is_array = true
        local max_index = 0
        for k, v in pairs(obj) do
            if type(k) ~= "number" then
                is_array = false
            else
                max_index = math.max(max_index, k)
            end
        end
        
        if is_array and max_index == #obj then
            -- Array
            for _, v in ipairs(obj) do
                table.insert(items, _encode_json(v))
            end
            return "[" .. table.concat(items, ",") .. "]"
        else
            -- Object
            for k, v in pairs(obj) do
                table.insert(items, "\"" .. tostring(k) .. "\":" .. _encode_json(v))
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    elseif type(obj) == "string" then
        return "\"" .. obj:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r") .. "\""
    elseif type(obj) == "number" then
        return tostring(obj)
    elseif type(obj) == "boolean" then
        return obj and "true" or "false"
    elseif obj == nil then
        return "null"
    else
        return "\"" .. tostring(obj) .. "\""
    end
end
