-- scanner.lua - Session scanner for Claude Code sessions
-- Discovers JSONL session files under ~/.claude/projects/

local reader = require("reader")

local M = {}

-- Derive project name from directory name (fallback)
-- e.g. "-Users-fanrenhao-work-VoiceText" -> "VoiceText"
local function _project_name_from_dir(dirname)
    local stripped = dirname:match("^%-*(.-)%-*$")
    if not stripped or stripped == "" then
        return dirname
    end
    local parts = {}
    for part in stripped:gmatch("[^-]+") do
        table.insert(parts, part)
    end
    return parts[#parts] or dirname
end

-- Try to resolve project name from git remote
local function _resolve_project_name(cwd, dir_fallback)
    if not cwd or cwd == "" then
        return dir_fallback
    end

    -- Check if cwd exists and is a git repo
    local git_result = lingxi.shell.exec("git -C " .. cwd .. " remote -v 2>/dev/null")
    if git_result.exitCode == 0 and git_result.stdout ~= "" then
        -- Parse remote URL to get project name
        for line in git_result.stdout:gmatch("[^\r\n]+") do
            local url = line:match("%S+@%S+:(%S+)%.git")
            if not url then
                url = line:match("https?://%S+/(%S+)%.git")
            end
            if not url then
                url = line:match("https?://%S+/(%S+)")
            end
            if url then
                local parts = {}
                for part in url:gmatch("[^/]+") do
                    table.insert(parts, part)
                end
                if #parts > 0 then
                    return parts[#parts]
                end
            end
        end
    end

    return dir_fallback
end

-- Clean a custom title: extract plan title if it starts with plan prefix
local function _clean_custom_title(raw)
    local PLAN_PREFIX = "Implement the following plan:"
    if raw:sub(1, #PLAN_PREFIX) == PLAN_PREFIX then
        local remainder = raw:sub(#PLAN_PREFIX + 1):match("^%s*(.-)%s*$")
        -- Extract first markdown heading
        for line in remainder:gmatch("[^\n]+") do
            local heading = line:match("^#%s+(.+)$")
            if heading then
                -- Truncate at next ## or #
                for _, sep in ipairs({" ## ", " # "}) do
                    local idx = heading:find(sep, 1, true)
                    if idx then
                        heading = heading:sub(1, idx - 1)
                    end
                end
                return heading:match("^%s*(.-)%s*$")
            end
        end
    end
    return raw
end

-- Clean a firstPrompt value
local function _clean_first_prompt(raw)
    if not raw or raw == "" then
        return ""
    end
    local is_noise = false
    local noise_patterns = {
        "^<local-command-caveat",
        "^<command-name",
        "^<command-message",
        "^<command-args",
        "^<system-reminder",
        "^<user-prompt-submit-hook",
    }
    for _, pattern in ipairs(noise_patterns) do
        if raw:match(pattern) then
            is_noise = true
            break
        end
    end
    if not is_noise then
        return raw
    end
    -- Strip XML-like tags
    local cleaned = raw:gsub("<[^%u003e]+>", ""):match("^%s*(.-)%s*$")
    return cleaned or ""
end

-- Choose the best available title
local function _choose_title(custom_title, summary, first_prompt)
    local raw = custom_title or summary or _clean_first_prompt(first_prompt or "") or ""
    if #raw > 80 then
        return raw:sub(1, 77) .. "..."
    end
    return raw
end

-- Build a session metadata table
local function _make_session(session_id, file_path, project, opts)
    opts = opts or {}
    local title = opts.title or ""
    local first_prompt = opts.first_prompt or ""

    return {
        session_id = session_id,
        file_path = file_path,
        project = project,
        cwd = opts.cwd or "",
        title = title ~= "" and title or _choose_title(nil, nil, first_prompt),
        first_prompt = first_prompt,
        git_branch = opts.git_branch or "",
        created = opts.created or "",
        modified = opts.modified or "",
        message_count = opts.message_count or 0,
        version = opts.version or "",
        summary = opts.summary or "",
        custom_title = opts.custom_title or "",
    }
end

-- Scan a single JSONL session file
local function _scan_session_jsonl(jsonl_path, project_name)
    local session_id = jsonl_path:match("([^/]+)%.jsonl$")
    if not session_id then
        return nil
    end

    lingxi.log.write("[cc-sessions] _scan_session_jsonl: reading " .. jsonl_path)
    local meta = reader.read_metadata(jsonl_path)
    if not meta then
        lingxi.log.write("[cc-sessions] _scan_session_jsonl: read_metadata returned nil for " .. jsonl_path)
        return nil
    end
    lingxi.log.write("[cc-sessions] _scan_session_jsonl: got meta, first_timestamp=" .. tostring(meta.first_timestamp) .. ", first_user_message=" .. tostring(meta.first_user_message and meta.first_user_message:sub(1, 50) or "nil"))

    local project = _resolve_project_name(meta.cwd, project_name)
    local custom_title = meta.custom_title
    if custom_title and custom_title ~= "" then
        custom_title = _clean_custom_title(custom_title)
    end

    local title = _choose_title(
        custom_title ~= "" and custom_title or nil,
        meta.summary ~= "" and meta.summary or nil,
        meta.first_user_message
    )

    return _make_session(
        session_id,
        jsonl_path,
        project,
        {
            cwd = meta.cwd,
            title = title,
            first_prompt = meta.first_user_message or "",
            git_branch = meta.git_branch,
            created = meta.first_timestamp or "",
            modified = meta.last_timestamp or "",
            message_count = meta.user_msg_count,
            version = meta.version,
            summary = meta.summary,
            custom_title = custom_title,
        }
    )
end

-- Load index supplements (summary/customTitle) from sessions-index.json
local function _load_index_supplements(proj_dir)
    local index_path = proj_dir .. "/sessions-index.json"
    local exists = lingxi.file.exists(index_path)
    if not exists then
        return {}
    end

    local content = lingxi.file.read(index_path)
    if not content then
        return {}
    end

    local ok, data = pcall(function()
        return lingxi.json.parse(content)
    end)
    if not ok or type(data) ~= "table" then
        return {}
    end

    local entries = data.entries or data
    if type(entries) ~= "table" then
        return {}
    end

    local lookup = {}
    for _, entry in ipairs(entries) do
        if type(entry) == "table" then
            local sid = entry.sessionId or ""
            if sid ~= "" then
                lookup[sid] = {
                    summary = entry.summary or "",
                    customTitle = entry.customTitle or "",
                }
            end
        end
    end

    return lookup
end

-- Scan all sessions
function M.scan_all()
    local sessions = {}
    local seen_ids = {}

    local base_dir = "~/.claude/projects"
    lingxi.log.write("[cc-sessions] scan_all: checking base_dir=" .. base_dir)
    local exists = lingxi.file.exists(base_dir)
    lingxi.log.write("[cc-sessions] scan_all: exists=" .. tostring(exists))
    if not exists then
        return sessions
    end

    local entries = lingxi.file.list(base_dir)
    lingxi.log.write("[cc-sessions] scan_all: entries count=" .. tostring(entries and #entries or 0))
    if not entries then
        return sessions
    end

    for _, entry in ipairs(entries) do
        if not entry.isDir then
            goto continue
        end

        local proj_dir = base_dir .. "/" .. entry.name
        local dir_fallback = _project_name_from_dir(entry.name)

        -- Load index supplements
        local index_lookup = _load_index_supplements(proj_dir)

        -- Scan all JSONL files
        local files = lingxi.file.list(proj_dir)
        if not files then
            goto continue
        end
        lingxi.log.write("[cc-sessions] scan_all: proj_dir=" .. proj_dir .. ", files count=" .. #files)

        for _, file in ipairs(files) do
            if not file.name:match("%.jsonl$") then
                goto next_file
            end

            local jsonl_path = proj_dir .. "/" .. file.name
            local session = _scan_session_jsonl(jsonl_path, dir_fallback)
            if not session then
                goto next_file
            end

            -- Merge index supplements
            if index_lookup and index_lookup[session.session_id] then
                local supplement = index_lookup[session.session_id]
                local new_summary = supplement.summary or ""
                local new_custom_title = supplement.customTitle or ""
                if new_summary ~= session.summary or new_custom_title ~= session.custom_title then
                    session.summary = new_summary
                    session.custom_title = new_custom_title
                    session.title = _choose_title(
                        new_custom_title ~= "" and new_custom_title or nil,
                        new_summary ~= "" and new_summary or nil,
                        session.first_prompt
                    )
                end
            end

            if not seen_ids[session.session_id] then
                seen_ids[session.session_id] = true
                table.insert(sessions, session)
            end

            ::next_file::
        end

        ::continue::
    end

    -- Sort by modified descending
    table.sort(sessions, function(a, b)
        return (a.modified or "") > (b.modified or "")
    end)

    lingxi.log.write("[cc-sessions] scan_all: returning " .. #sessions .. " sessions")
    return sessions
end

return M
