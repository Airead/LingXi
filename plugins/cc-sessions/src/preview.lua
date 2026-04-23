-- preview.lua - HTML preview generation for search results
-- Generates rich HTML preview with metadata pills, timestamps, and conversation turns.

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

-- Format timestamp to readable date
local function _format_timestamp(iso_timestamp)
    if not iso_timestamp or iso_timestamp == "" then
        return ""
    end
    local year, month, day, hour, min = iso_timestamp:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")
    if not year then
        return ""
    end
    return string.format("%s-%s-%s %s:%s", year, month, day, hour, min)
end

-- Calculate duration between two timestamps
local function _calculate_duration(created, modified)
    if not created or not modified or created == "" or modified == "" then
        return ""
    end

    local y1, mo1, d1, h1, mi1, s1 = created:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
    local y2, mo2, d2, h2, mi2, s2 = modified:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")

    if not y1 or not y2 then
        return ""
    end

    local t1 = os.time({ year = tonumber(y1), month = tonumber(mo1), day = tonumber(d1),
                         hour = tonumber(h1), min = tonumber(mi1), sec = tonumber(s1) })
    local t2 = os.time({ year = tonumber(y2), month = tonumber(mo2), day = tonumber(d2),
                         hour = tonumber(h2), min = tonumber(mi2), sec = tonumber(s2) })

    local seconds = t2 - t1
    if seconds < 60 then
        return seconds .. "s"
    elseif seconds < 3600 then
        local mins = math.floor(seconds / 60)
        return mins .. "m"
    else
        local hours = math.floor(seconds / 3600)
        local mins = math.floor((seconds % 3600) / 60)
        if mins > 0 then
            return hours .. "h " .. mins .. "m"
        else
            return hours .. "h"
        end
    end
end

-- Escape HTML special characters
local function _escape_html(text)
    if not text then
        return ""
    end
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    text = text:gsub('"', "&quot;")
    return text
end

-- Build an HTML preview for a session
function M.build(session)
    local detail = reader.read_detail(session.file_path, 10)

    -- Build metadata pills
    local pills = {}
    table.insert(pills, '<span class="pill project">' .. _escape_html(session.project) .. '</span>')
    if session.git_branch and session.git_branch ~= "" then
        table.insert(pills, '<span class="pill branch">' .. _escape_html(session.git_branch) .. '</span>')
    end
    if session.version and session.version ~= "" then
        table.insert(pills, '<span class="pill version">' .. _escape_html(session.version) .. '</span>')
    end
    if session.message_count and session.message_count > 0 then
        table.insert(pills, '<span class="pill messages">' .. session.message_count .. ' msgs</span>')
    end
    if detail and (detail.total_input_tokens > 0 or detail.total_output_tokens > 0) then
        table.insert(pills, '<span class="pill tokens">' .. detail.total_input_tokens .. ' in / ' .. detail.total_output_tokens .. ' out</span>')
    end

    -- Build time info
    local time_items = {}
    if session.created and session.created ~= "" then
        table.insert(time_items, '<div class="time-item"><span class="time-label">Created:</span> <span class="time-value">' .. _format_timestamp(session.created) .. '</span></div>')
    end
    if session.modified and session.modified ~= "" then
        table.insert(time_items, '<div class="time-item"><span class="time-label">Modified:</span> <span class="time-value">' .. _format_timestamp(session.modified) .. ' (' .. _time_ago(session.modified) .. ')</span></div>')
    end
    local duration = _calculate_duration(session.created, session.modified)
    if duration ~= "" then
        table.insert(time_items, '<div class="time-item"><span class="time-label">Duration:</span> <span class="time-value">' .. duration .. '</span></div>')
    end

    -- Build conversation turns
    local turns_html = {}
    if detail and #detail.turns > 0 then
        table.insert(turns_html, '<div class="turns-header">Recent conversation</div>')
        for _, turn in ipairs(detail.turns) do
            local role_class = turn.role == "user" and "user" or "assistant"
            local role_label = turn.role == "user" and "You" or "AI"
            local text = turn.text
            -- Escape and truncate
            if #text > 200 then
                text = text:sub(1, 197) .. "..."
            end
            text = _escape_html(text)
            -- Preserve line breaks
            text = text:gsub("\n", "<br>")
            table.insert(turns_html, '<div class="turn ' .. role_class .. '"><div class="turn-role">' .. role_label .. '</div><div class="turn-text">' .. text .. '</div></div>')
        end
    else
        table.insert(turns_html, '<div class="no-preview">No preview available</div>')
    end

    -- Build full HTML
    local html_parts = {
        '<!DOCTYPE html>',
        '<html>',
        '<head>',
        '<meta charset="UTF-8">',
        '<style>',
        'body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 16px; background: #f5f5f5; color: #333; }',
        '.container { background: white; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }',
        '.title { font-size: 18px; font-weight: 600; margin-bottom: 12px; color: #1a1a1a; }',
        '.pills { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 16px; }',
        '.pill { display: inline-block; padding: 4px 10px; border-radius: 12px; font-size: 12px; font-weight: 500; }',
        '.pill.project { background: #e3f2fd; color: #1565c0; }',
        '.pill.branch { background: #f3e5f5; color: #6a1b9a; }',
        '.pill.version { background: #e8f5e9; color: #2e7d32; }',
        '.pill.messages { background: #fff3e0; color: #ef6c00; }',
        '.pill.tokens { background: #fce4ec; color: #c2185b; }',
        '.time-section { margin-bottom: 16px; padding: 12px; background: #fafafa; border-radius: 6px; }',
        '.time-item { font-size: 13px; color: #666; margin-bottom: 4px; }',
        '.time-label { color: #999; }',
        '.time-value { color: #555; }',
        '.turns-header { font-size: 14px; font-weight: 600; color: #555; margin-bottom: 12px; padding-bottom: 8px; border-bottom: 1px solid #eee; }',
        '.turn { margin-bottom: 12px; padding: 10px 12px; border-radius: 6px; font-size: 13px; }',
        '.turn.user { background: #e3f2fd; border-left: 3px solid #2196f3; }',
        '.turn.assistant { background: #f5f5f5; border-left: 3px solid #9e9e9e; }',
        '.turn-role { font-size: 11px; font-weight: 600; text-transform: uppercase; margin-bottom: 4px; color: #666; }',
        '.turn.user .turn-role { color: #1976d2; }',
        '.turn.assistant .turn-role { color: #616161; }',
        '.turn-text { line-height: 1.5; color: #333; }',
        '.no-preview { color: #999; font-style: italic; padding: 20px; text-align: center; }',
        '</style>',
        '</head>',
        '<body>',
        '<div class="container">',
        '<div class="title">' .. _escape_html(session.title) .. '</div>',
        '<div class="pills">' .. table.concat(pills, " ") .. '</div>',
        '<div class="time-section">' .. table.concat(time_items, "") .. '</div>',
        table.concat(turns_html, ""),
        '</div>',
        '</body>',
        '</html>',
    }

    return table.concat(html_parts, "\n")
end

return M
