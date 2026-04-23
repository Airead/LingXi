-- scanner.lua - Session scanner for Claude Code sessions
-- Discovers JSONL session files under ~/.claude/projects/

local reader = require("src.reader")
local cache = require("src.cache")

local M = {}

-- ============================================================================
-- Timing helper
-- ============================================================================

local function _elapsed(start)
    return string.format("%.3f", os.clock() - start)
end

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
    local cleaned = raw:gsub("<[^%>]+", ""):match("^%s*(.-)%s*$")
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
        detail = opts.detail or nil,
    }
end

-- Scan a single JSONL session file
local function _scan_session_jsonl(jsonl_path, project_name)
    local session_id = jsonl_path:match("([^/]+)%.jsonl$")
    if not session_id then
        return nil
    end

    -- Read metadata + detail in a single pass
    local session_data = reader.read_session(jsonl_path)
    if not session_data then
        return nil
    end

    local meta = session_data.metadata
    local detail = session_data.detail

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

    -- Use filesystem mtime as modified time (reflects actual file change)
    local fs_mtime = cache.get_mtime(jsonl_path)
    -- Convert numeric Unix timestamp to ISO string for time formatting functions
    if type(fs_mtime) == "number" then
        fs_mtime = os.date("!%Y-%m-%dT%H:%M:%S", math.floor(fs_mtime))
    end

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
            modified = fs_mtime or meta.last_timestamp or "",
            message_count = 0,
            version = meta.version,
            summary = meta.summary,
            custom_title = custom_title,
            detail = detail,
        }
    )
end

-- Load index supplements (summary/customTitle) from sessions-index.json with mtime caching
local function _load_index_supplements(proj_dir)
    local index_path = proj_dir .. "/sessions-index.json"
    
    -- Check cache first
    local cached = cache.get_index_cache(index_path)
    if cached then
        return cached
    end
    
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

    -- Cache the result with mtime
    local mtime = cache.get_mtime(index_path)
    if mtime then
        cache.set_index_cache(index_path, mtime, lookup)
    end

    return lookup
end

-- Scan all sessions with incremental caching
function M.scan_all()
    local total_start = os.clock()

    -- 1. Memory cache hit with TTL (60 seconds)
    local mem = cache.get_memory_cache()
    if mem then
        lingxi.log.write("[cc-sessions] scan_all: returning " .. #mem .. " sessions from TTL memory cache")
        return mem
    end

    -- 2. Concurrency guard: if scanning in progress, return empty
    if cache.is_scanning() then
        lingxi.log.write("[cc-sessions] scan_all: scan in progress, returning empty")
        return {}
    end

    cache.set_scanning(true)
    lingxi.log.write("[cc-sessions] scan_all: starting incremental scan")

    -- 3. Load disk cache (incremental: modify in-place)
    local disk_start = os.clock()
    local disk_cache = cache.load_disk_cache()
    lingxi.log.write("[cc-sessions]   load_disk_cache: " .. _elapsed(disk_start) .. "s")

    local sessions = {}
    local seen_ids = {}
    local live_paths = {}

    local base_dir = "~/.claude/projects"
    local exists = lingxi.file.exists(base_dir)
    if not exists then
        cache.set_scanning(false)
        return sessions
    end

    local entries = lingxi.file.list(base_dir)
    if not entries then
        cache.set_scanning(false)
        return sessions
    end

    local file_count = 0
    local cache_hit = 0
    local cache_miss = 0
    local parse_time = 0
    local stat_time = 0

    for _, entry in ipairs(entries) do
        if not entry.isDir then
            goto continue
        end

        local proj_dir = base_dir .. "/" .. entry.name
        local dir_fallback = _project_name_from_dir(entry.name)

        -- Load index supplements with mtime caching
        local idx_start = os.clock()
        local index_lookup = _load_index_supplements(proj_dir)
        local idx_elapsed = _elapsed(idx_start)
        if idx_elapsed ~= "0.000" then
            lingxi.log.write("[cc-sessions]   index_load (miss): " .. idx_elapsed .. "s")
        end

        -- Scan all JSONL files
        local files = lingxi.file.list(proj_dir)
        if not files then
            goto continue
        end

        for _, file in ipairs(files) do
            if not file.name:match("%.jsonl$") then
                goto next_file
            end

            local jsonl_path = proj_dir .. "/" .. file.name
            live_paths[jsonl_path] = true
            file_count = file_count + 1

            local stat_start = os.clock()
            local mtime = cache.get_mtime(jsonl_path)
            stat_time = stat_time + (os.clock() - stat_start)
            local session = nil

            -- Try disk cache first (incremental: modify disk_cache in-place)
            if mtime then
                session = cache.get(disk_cache, jsonl_path, mtime)
            end

            -- Cache miss or no mtime: parse fresh and update disk_cache
            if not session then
                cache_miss = cache_miss + 1
                
                -- Log detailed mtime comparison for debugging (first 5 misses)
                if cache_miss <= 5 then
                    local entry_info = disk_cache[jsonl_path]
                    if entry_info then
                        lingxi.log.write("[cc-sessions]   CACHE_MISS #" .. cache_miss .. " " .. jsonl_path)
                        lingxi.log.write("[cc-sessions]     cached_mtime=" .. tostring(entry_info.mtime) .. " current_mtime=" .. tostring(mtime))
                        lingxi.log.write("[cc-sessions]     cached_type=" .. type(entry_info.mtime) .. " current_type=" .. type(mtime))
                    else
                        lingxi.log.write("[cc-sessions]   CACHE_MISS #" .. cache_miss .. " (not in cache) mtime=" .. tostring(mtime) .. " " .. jsonl_path)
                    end
                end
                
                local parse_start = os.clock()
                session = _scan_session_jsonl(jsonl_path, dir_fallback)
                parse_time = parse_time + (os.clock() - parse_start)
                if session and mtime then
                    cache.put(disk_cache, jsonl_path, mtime, session)
                end
            else
                cache_hit = cache_hit + 1
                -- Ensure session.modified reflects filesystem mtime (migrates old caches)
                if session and mtime then
                    if type(mtime) == "number" then
                        session.modified = os.date("!%Y-%m-%dT%H:%M:%S", math.floor(mtime))
                    else
                        session.modified = mtime
                    end
                end
                -- Log first 3 hits for comparison
                if cache_hit <= 3 then
                    local entry_info = disk_cache[jsonl_path]
                    lingxi.log.write("[cc-sessions]   CACHE_HIT #" .. cache_hit .. " " .. jsonl_path)
                    lingxi.log.write("[cc-sessions]     cached_mtime=" .. tostring(entry_info and entry_info.mtime))
                end
            end

            if not session then
                goto next_file
            end

            -- Apply index supplements (always fresh, even on cache hit)
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

    lingxi.log.write("[cc-sessions]   files=" .. file_count .. " hit=" .. cache_hit .. " miss=" .. cache_miss)
    lingxi.log.write("[cc-sessions]   stat_time: " .. string.format("%.3f", stat_time) .. "s")
    lingxi.log.write("[cc-sessions]   parse_time: " .. string.format("%.3f", parse_time) .. "s")

    -- 4. Prune deleted files from disk_cache (incremental)
    local prune_start = os.clock()
    cache.prune(disk_cache, live_paths)
    lingxi.log.write("[cc-sessions]   prune: " .. _elapsed(prune_start) .. "s")

    -- 5. Save disk cache (only if dirty)
    local save_start = os.clock()
    cache.save_disk_cache()
    lingxi.log.write("[cc-sessions]   save_disk: " .. _elapsed(save_start) .. "s")

    -- 6. Set memory cache with TTL
    cache.set_memory_cache(sessions)

    -- 7. Release lock
    cache.set_scanning(false)

    -- Sort by modified descending
    local sort_start = os.clock()
    table.sort(sessions, function(a, b)
        return (a.modified or "") > (b.modified or "")
    end)
    lingxi.log.write("[cc-sessions]   sort: " .. _elapsed(sort_start) .. "s")

    lingxi.log.write("[cc-sessions] scan_all: returning " .. #sessions .. " sessions (total=" .. _elapsed(total_start) .. "s)")
    return sessions
end

return M
