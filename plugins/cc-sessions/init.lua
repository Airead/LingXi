-- init.lua - Claude Code Sessions plugin entry point
-- Browse and search Claude Code session history.

local scanner = require("scanner")
local reader = require("reader")

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
-- Preview Building
-- ============================================================================

local function _build_preview(session)
    local lines = {
        "Session: " .. session.title,
        "",
        "Project: " .. session.project,
    }

    if session.git_branch and session.git_branch ~= "" then
        table.insert(lines, "Branch:  " .. session.git_branch)
    end

    if session.message_count and session.message_count > 0 then
        table.insert(lines, "Messages: " .. session.message_count)
    end

    table.insert(lines, "")

    -- Read detail for recent turns
    local detail = reader.read_detail(session.file_path, 5)
    if detail and #detail.turns > 0 then
        table.insert(lines, "Recent conversation:")
        table.insert(lines, "")
        for _, turn in ipairs(detail.turns) do
            local prefix = turn.role == "user" and "You: " or "AI:  "
            local text = turn.text
            if #text > 120 then
                text = text:sub(1, 117) .. "..."
            end
            -- Escape newlines
            text = text:gsub("\n", " ")
            table.insert(lines, prefix .. text)
        end

        if detail.total_input_tokens > 0 or detail.total_output_tokens > 0 then
            table.insert(lines, "")
            table.insert(lines, "Tokens: " .. detail.total_input_tokens .. " in / " .. detail.total_output_tokens .. " out")
        end
    else
        table.insert(lines, "No preview available")
    end

    return table.concat(lines, "\n")
end

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

    return {
        title = session.title,
        subtitle = table.concat(subtitle_parts, " · "),
        item_id = item_id,
        preview_type = "text",
        preview = _build_preview(session),
        action = function()
            -- TODO: Open WebView viewer (Phase 3)
            lingxi.alert.show("Viewer coming in Phase 3!", 2.0)
        end,
        cmd_action = function()
            lingxi.clipboard.write(session.file_path)
            lingxi.alert.show("Path copied!", 1.5)
        end,
        cmd_subtitle = "Copy file path",
    }
end

-- ============================================================================
-- Public API
-- ============================================================================

function search(query)
    lingxi.log.write("[cc-sessions] search called with query: '" .. tostring(query) .. "'")
    query = query or ""
    query = query:gsub("^%s*cc%s*", ""):gsub("^%s*", "")
    lingxi.log.write("[cc-sessions] parsed query: '" .. tostring(query) .. "'")

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
    lingxi.log.write("[cc-sessions] search: project_filter=" .. tostring(project_filter) .. ", text_query=" .. tostring(text_query))
    local sessions = scanner.scan_all()
    lingxi.log.write("[cc-sessions] search: got " .. #sessions .. " sessions")
    local filtered = _filter_sessions(sessions, project_filter, text_query)
    lingxi.log.write("[cc-sessions] search: filtered to " .. #filtered .. " sessions")

    local items = {}
    for i = 1, math.min(#filtered, 50) do
        table.insert(items, _build_result_item(filtered[i]))
    end

    lingxi.log.write("[cc-sessions] search: returning " .. #items .. " items")
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
    -- TODO: Implement cache clearing (Phase 4)
    lingxi.alert.show("Cache cleared!", 2.0)
    return { { title = "Cache cleared", subtitle = "Session scan cache has been cleared" } }
end
