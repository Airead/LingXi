-- init.lua - Claude Code Sessions plugin entry point
-- Browse and search Claude Code session history.

local scanner = require("src.scanner")
local reader = require("src.reader")
local preview = require("src.preview")
local identicon = require("src.identicon")

-- ============================================================================
-- Query Parsing
-- ============================================================================

local function _parse_query(query)
    query = query:match("^%s*(.-)%s*$")
    if query:find("^@") then
        local after_at = query:sub(2)
        local space_idx = after_at:find("%s")
        if space_idx then
            local project = after_at:sub(1, space_idx - 1):match("^%s*(.-)%s*$")
            local rest = after_at:sub(space_idx + 1):match("^%s*(.-)%s*$")
            return project, rest
        else
            return after_at:match("^%s*(.-)%s*$"), ""
        end
    end
    return nil, query
end

-- ============================================================================
-- Time Formatting
-- ============================================================================

local function _time_ago(iso_timestamp)
    if not iso_timestamp or iso_timestamp == "" then
        return ""
    end

    -- Parse ISO timestamp (handle both with and without timezone)
    local year, month, day, hour, min, sec = iso_timestamp:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not year then
        return ""
    end

    local timestamp = os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    })

    local now = os.time()
    local seconds = now - timestamp
    if seconds < 60 then
        return "just now"
    elseif seconds < 3600 then
        local minutes = math.floor(seconds / 60)
        return minutes .. " min ago"
    elseif seconds < 86400 then
        local hours = math.floor(seconds / 3600)
        return hours .. " hour" .. (hours ~= 1 and "s" or "") .. " ago"
    elseif seconds < 2592000 then
        local days = math.floor(seconds / 86400)
        return days .. " day" .. (days ~= 1 and "s" or "") .. " ago"
    else
        local months = math.floor(seconds / 2592000)
        return months .. " month" .. (months ~= 1 and "s" or "") .. " ago"
    end
end

-- ============================================================================
-- Session Filtering
-- ============================================================================

local function _filter_sessions(sessions, project_filter, query)
    local result = sessions

    -- Filter by project
    if project_filter and project_filter ~= "" then
        local filtered = {}
        for _, s in ipairs(result) do
            if s.project:lower():find(project_filter:lower(), 1, true) then
                table.insert(filtered, s)
            end
        end
        result = filtered
    end

    -- Fuzzy match by query
    query = query:match("^%s*(.-)%s*$")
    if query and query ~= "" then
        local search_items = {}
        for _, s in ipairs(result) do
            local search_text = s.title .. " " .. s.project .. " " .. (s.git_branch or "") .. " " .. (s.summary or "") .. " " .. (s.first_prompt or ""):sub(1, 200)
            table.insert(search_items, {
                session = s,
                text = search_text,
            })
        end

        local fuzzy_input = {}
        for i, item in ipairs(search_items) do
            fuzzy_input[i] = { text = item.text }
        end

        local scored = lingxi.fuzzy.search(query, fuzzy_input, { "text" })
        local filtered = {}
        for _, match in ipairs(scored) do
            table.insert(filtered, search_items[match.index].session)
        end
        result = filtered
    end

    return result
end

-- ============================================================================
-- Subagent Helpers
-- ============================================================================

-- Extract model from subagent session JSONL (first assistant message)
local function _extract_subagent_model(jsonl_path)
    local content = lingxi.file.read(jsonl_path)
    if not content then
        return ""
    end

    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local ok, obj = pcall(function()
                return lingxi.json.parse(trimmed)
            end)
            if ok and type(obj) == "table" then
                if obj.type == "assistant" then
                    local model = obj.message and obj.message.model
                    if model and model ~= "" then
                        return model
                    end
                end
            end
        end
    end

    return ""
end

local function _list_subagents(file_path)
    if not file_path or file_path == "" then
        return {}
    end

    local session_dir = file_path:match("^(.*)%.jsonl$")
    if not session_dir then
        return {}
    end

    local subagents_dir = session_dir .. "/subagents"
    local exists = lingxi.file.exists(subagents_dir)
    if not exists then
        return {}
    end

    local entries = lingxi.file.list(subagents_dir)
    if not entries then
        return {}
    end

    local subagents = {}
    for _, entry in ipairs(entries) do
        if entry.name:match("^agent%-.+%.jsonl$") then
            local agent_id = entry.name:match("^agent%-(.+)%.jsonl$")
            local meta_path = subagents_dir .. "/agent-" .. agent_id .. ".meta.json"
            local meta = { agentType = "", description = "" }

            local meta_exists = lingxi.file.exists(meta_path)
            if meta_exists then
                local meta_content = lingxi.file.read(meta_path)
                if meta_content then
                    local ok, meta_obj = pcall(function()
                        return lingxi.json.parse(meta_content)
                    end)
                    if ok and type(meta_obj) == "table" then
                        meta.agentType = meta_obj.agentType or ""
                        meta.description = meta_obj.description or ""
                    end
                end
            end

            -- Extract model from subagent session
            local subagent_path = subagents_dir .. "/" .. entry.name
            local model = _extract_subagent_model(subagent_path)

            table.insert(subagents, {
                agent_id = agent_id,
                agent_type = meta.agentType,
                description = meta.description,
                file_path = subagent_path,
                model = model,
            })
        end
    end

    return subagents
end

local function _is_subagent(file_path)
    if not file_path then
        return false
    end
    return file_path:find("/subagents/agent%-") ~= nil
end

local function _find_parent_session(file_path)
    if not _is_subagent(file_path) then
        return nil
    end

    local parent_dir = file_path:match("^(.*)/subagents/")
    if not parent_dir then
        return nil
    end

    return parent_dir .. ".jsonl"
end

-- ============================================================================
-- WebView State
-- ============================================================================

local _current_session = nil

-- Register WebView message handler
lingxi.webview.on_message(function(raw)
    local ok, data = pcall(function()
        return lingxi.json.parse(raw)
    end)
    if not ok or type(data) ~= "table" then
        return
    end

    if data.action == "init" then
        if not _current_session then
            return
        end

        local content = lingxi.file.read(_current_session.file_path)
        if not content then
            return
        end

        -- Parse JSONL into structured messages
        local messages = {}
        for line in content:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                local parse_ok, obj = pcall(function()
                    return lingxi.json.parse(trimmed)
                end)
                if parse_ok and type(obj) == "table" then
                    table.insert(messages, obj)
                end
            end
        end

        -- Check if this is a subagent and find parent
        local is_subagent = _is_subagent(_current_session.file_path)
        local parent_file_path = nil
        if is_subagent then
            parent_file_path = _find_parent_session(_current_session.file_path)
        end

        -- List subagents
        local subagents = _list_subagents(_current_session.file_path)

        -- Send structured data to JS
        local payload = {
            action = "session_data",
            info = {
                title = _current_session.title,
                project = _current_session.project,
                git_branch = _current_session.git_branch or "",
                version = _current_session.version or "",
                cwd = _current_session.cwd or "",
                session_id = _current_session.session_id or "",
                is_subagent = is_subagent,
                parent_file_path = parent_file_path,
            },
            messages = messages,
            subagents = subagents,
        }

        lingxi.webview.send(lingxi.json.encode(payload))

    elseif data.action == "copy" then
        if data.text and data.text ~= "" then
            lingxi.clipboard.write(data.text)
        end

    elseif data.action == "close" then
        lingxi.webview.close()

    elseif data.action == "open_subagent" then
        if data.file_path and data.file_path ~= "" then
            local meta = reader.read_metadata(data.file_path)
            if meta then
                local session_id = data.file_path:match("([^/]+)%.jsonl$") or ""
                local project = ""
                if _current_session then
                    project = _current_session.project
                end

                local session = {
                    file_path = data.file_path,
                    title = meta.summary ~= "" and meta.summary or meta.custom_title ~= "" and meta.custom_title or "Subagent Session",
                    project = project,
                    git_branch = meta.git_branch or "",
                    version = meta.version or "",
                    cwd = meta.cwd or "",
                    session_id = session_id,
                }
                _current_session = session
                lingxi.webview.open("viewer.html", {
                    title = session.title,
                    width = 900,
                    height = 700
                })
            end
        end

    elseif data.action == "open_parent" then
        if data.file_path and data.file_path ~= "" then
            local meta = reader.read_metadata(data.file_path)
            if meta then
                local session_id = data.file_path:match("([^/]+)%.jsonl$") or ""
                local project = ""
                if _current_session then
                    project = _current_session.project
                end

                local session = {
                    file_path = data.file_path,
                    title = meta.summary ~= "" and meta.summary or meta.custom_title ~= "" and meta.custom_title or "Parent Session",
                    project = project,
                    git_branch = meta.git_branch or "",
                    version = meta.version or "",
                    cwd = meta.cwd or "",
                    session_id = session_id,
                }
                _current_session = session
                lingxi.webview.open("viewer.html", {
                    title = session.title,
                    width = 900,
                    height = 700
                })
            end
        end
    end
end)

-- ============================================================================
-- Result Building
-- ============================================================================

local function _build_result_item(session)
    local time_str = _time_ago(session.modified)
    local subtitle_parts = { session.project }
    if time_str ~= "" then
        table.insert(subtitle_parts, time_str)
    end
    if session.git_branch and session.git_branch ~= "" then
        table.insert(subtitle_parts, session.git_branch)
    end

    local msg_count = session.message_count or 0
    local item_id = "cc-" .. session.session_id

    local icon = identicon.generate(session.project)

    return {
        title = session.title,
        subtitle = table.concat(subtitle_parts, " · "),
        icon = icon,
        item_id = item_id,
        preview_type = "html",
        preview = preview.build(session),
        action = function()
            _current_session = session
            local ok = lingxi.webview.open("viewer.html", {
                title = session.title,
                width = 900,
                height = 700
            })
            if not ok then
                -- Fallback: open with default application
                lingxi.alert.show("Opening with default app...", 1.5)
                lingxi.shell.exec("open " .. session.file_path)
            end
        end,
        cmd_action = function()
            lingxi.clipboard.write(session.file_path)
            lingxi.alert.show("Path copied!", 1.5)
        end,
        cmd_subtitle = "Copy file path",
        delete_action = function()
            -- Show confirmation dialog using osascript
            local confirm_script = 'osascript -e \'display dialog "Move session to Trash?" & return & return & "' .. session.title:gsub('"', '\\"') .. '" buttons {"Cancel", "Move to Trash"} default button "Cancel" with icon caution\''
            local confirm_result = lingxi.shell.exec(confirm_script)

            -- Check if user confirmed (button returned is "Move to Trash")
            if not confirm_result.stdout or not confirm_result.stdout:find("Move to Trash") then
                return
            end

            -- Move file to trash using shell command
            local result = lingxi.shell.exec("mv " .. session.file_path .. " ~/.Trash/")
            if result.exitCode == 0 then
                lingxi.alert.show("Session moved to Trash", 2.0)
                -- Clear cache to reflect deletion
                local cache = require("src.cache")
                cache.clear()
            else
                lingxi.alert.show("Failed to move to Trash: " .. (result.stderr or "Unknown error"), 3.0)
            end
        end,
        delete_subtitle = "Move to Trash",
    }
end

-- ============================================================================
-- Public API
-- ============================================================================

function search(query)
    query = query or ""
    query = query:gsub("^%s*cc%s*", ""):gsub("^%s*", "")

    -- Group selection mode: query starts with @ and no space after @ content
    if query:find("^@") then
        local after_at = query:sub(2)
        if not after_at:find("%s") then
            local search_term = after_at:lower():match("^%s*(.-)%s*$")
            local sessions = scanner.scan_all()

            -- Get unique projects
            local projects = {}
            local seen = {}
            for _, s in ipairs(sessions) do
                local proj_lower = s.project:lower()
                if not seen[proj_lower] then
                    seen[proj_lower] = true
                    table.insert(projects, s.project)
                end
            end

            if search_term == "" or search_term == nil then
                -- Return all projects as filterable items
                local items = {}
                for _, project in ipairs(projects) do
                    table.insert(items, {
                        title = project,
                        subtitle = "Filter sessions by project",
                        action = function()
                            -- This will be handled by the panel's tab completion
                        end,
                    })
                end
                return items
            else
                -- Fuzzy search project names
                local project_items = {}
                for i, project in ipairs(projects) do
                    project_items[i] = { name = project:lower(), original = project }
                end

                local scored = lingxi.fuzzy.search(search_term, project_items, { "name" })
                local items = {}
                for _, match in ipairs(scored) do
                    local project = project_items[match.index].original
                    table.insert(items, {
                        title = project,
                        subtitle = "Filter sessions by project",
                    })
                end
                return items
            end
        end
    end

    local project_filter, text_query = _parse_query(query)
    local sessions = scanner.scan_all()
    local filtered = _filter_sessions(sessions, project_filter, text_query)

    local items = {}
    for i = 1, math.min(#filtered, 50) do
        table.insert(items, _build_result_item(filtered[i]))
    end

    return items
end

-- ============================================================================
-- Tab Complete
-- ============================================================================

function complete(query, item_title)
    if query:find("@") then
        return query:gsub("@.*$", "@" .. item_title .. " ")
    else
        return query:gsub("%s*$", "") .. " @" .. item_title .. " "
    end
end

-- ============================================================================
-- Commands
-- ============================================================================

function cmd_clear_cache(args)
    local cache = require("src.cache")
    cache.clear()
    lingxi.alert.show("Cache cleared!", 2.0)
    return { { title = "Cache cleared", subtitle = "Session scan cache has been cleared" } }
end
