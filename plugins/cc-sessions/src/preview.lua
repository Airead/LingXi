-- preview.lua - HTML preview generation for search results
-- Generates rich HTML preview with metadata pills, timestamps, and conversation turns.

local reader = require("src.reader")
local opencode_store = require("src.opencode_store")

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
        return minutes .. "m"
    elseif seconds < 86400 then
        local hours = math.floor(seconds / 3600)
        return hours .. "h"
    elseif seconds < 2592000 then
        local days = math.floor(seconds / 86400)
        return days .. "d"
    else
        local months = math.floor(seconds / 2592000)
        return months .. "mo"
    end
end

-- Format timestamp to readable date (compact)
local function _format_timestamp_compact(iso_timestamp)
    if not iso_timestamp or iso_timestamp == "" then
        return ""
    end
    local month, day, hour, min = iso_timestamp:match("^%d%d%d%d%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
    if not month then
        return ""
    end
    return string.format("%s-%s %s:%s", month, day, hour, min)
end

-- Calculate duration between two timestamps (compact)
local function _calculate_duration_compact(created, modified)
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
            return hours .. "h" .. mins .. "m"
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
    -- cc sessions cache `detail` on the session record during scan; opencode
    -- does not (lazy to keep scan snappy), so resolve it here per source.
    local detail
    if session.detail then
        detail = session.detail
    elseif session.source == opencode_store.SOURCE then
        detail = opencode_store.get_session_detail(session.session_id, 10)
    else
        detail = reader.read_detail(session.file_path, 10)
    end

    -- Build metadata pills (compact)
    local pills = {}
    -- Lead with source pill so users can tell CC vs OpenCode at a glance.
    if session.source == "opencode" then
        table.insert(pills, '<span class="pill source-oc">OC</span>')
    else
        table.insert(pills, '<span class="pill source-cc">CC</span>')
    end
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

    -- Build compact time info (single line)
    local time_info = {}
    if session.created and session.created ~= "" then
        table.insert(time_info, 'Created: ' .. _format_timestamp_compact(session.created))
    end
    if session.modified and session.modified ~= "" then
        table.insert(time_info, 'Modified: ' .. _format_timestamp_compact(session.modified) .. ' (' .. _time_ago(session.modified) .. ')')
    end
    local duration = _calculate_duration_compact(session.created, session.modified)
    if duration ~= "" then
        table.insert(time_info, 'Duration: ' .. duration)
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

    -- Build full HTML (high density layout)
    local html_parts = {
        '<!DOCTYPE html>',
        '<html>',
        '<head>',
        '<meta charset="UTF-8">',
        '<style>',
        'body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 0; background: white; color: #333; font-size: 13px; line-height: 1.4; }',
        '.container { background: white; padding: 4px; }',
        '.title { font-size: 15px; font-weight: 600; margin-bottom: 8px; color: #1a1a1a; line-height: 1.3; }',
        '.pills { display: flex; flex-wrap: wrap; gap: 4px; margin-bottom: 6px; }',
        '.pill { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 500; }',
        '.pill.source-cc { background: #ede7f6; color: #4527a0; font-weight: 700; }',
        '.pill.source-oc { background: #e0f2f1; color: #00695c; font-weight: 700; }',
        '.pill.project { background: #e3f2fd; color: #1565c0; }',
        '.pill.branch { background: #f3e5f5; color: #6a1b9a; }',
        '.pill.version { background: #e8f5e9; color: #2e7d32; }',
        '.pill.messages { background: #fff3e0; color: #ef6c00; }',
        '.pill.tokens { background: #fce4ec; color: #c2185b; }',
        '.time-line { font-size: 11px; color: #888; margin-bottom: 10px; }',
        '.turns-header { font-size: 12px; font-weight: 600; color: #666; margin-bottom: 8px; padding-bottom: 6px; border-bottom: 1px solid #eee; }',
        '.turn { margin-bottom: 8px; padding: 8px 10px; border-radius: 4px; font-size: 12px; }',
        '.turn.user { background: #f0f7ff; border-left: 2px solid #2196f3; }',
        '.turn.assistant { background: #f8f8f8; border-left: 2px solid #9e9e9e; }',
        '.turn-role { font-size: 10px; font-weight: 600; text-transform: uppercase; margin-bottom: 2px; color: #888; }',
        '.turn.user .turn-role { color: #1976d2; }',
        '.turn.assistant .turn-role { color: #666; }',
        '.turn-text { line-height: 1.4; color: #333; }',
        '.no-preview { color: #999; font-style: italic; padding: 16px; text-align: center; font-size: 12px; }',
        '</style>',
        '</head>',
        '<body>',
        '<div class="container">',
        '<div class="title">' .. _escape_html(session.title) .. '</div>',
        '<div class="pills">' .. table.concat(pills, " ") .. '</div>',
    }

    -- Add time line if we have time info
    if #time_info > 0 then
        table.insert(html_parts, '<div class="time-line">' .. table.concat(time_info, " · ") .. '</div>')
    end

    table.insert(html_parts, table.concat(turns_html, ""))
    table.insert(html_parts, '</div>')
    table.insert(html_parts, '</body>')
    table.insert(html_parts, '</html>')

    return table.concat(html_parts, "\n")
end

return M
