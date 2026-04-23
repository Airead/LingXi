-- preview.lua - Text preview generation for search results

local reader = require("src.reader")

local M = {}

-- Format a relative time string
local function _time_ago(iso_timestamp)
    if not iso_timestamp or iso_timestamp == "" then
        return ""
    end

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

-- Build a text preview for a session
function M.build(session)
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

    local time_str = _time_ago(session.modified)
    if time_str ~= "" then
        table.insert(lines, "Modified: " .. time_str)
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
            -- Escape newlines for single-line preview
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

return M
