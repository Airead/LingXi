-- opencode_store.lua - Read OpenCode sessions from SQLite storage.
-- Bridges the opencode.db schema (session/message/part) to the CC JSONL
-- structure consumed by scanner/reader/viewer.

local M = {}

M.SOURCE = "opencode"
M.SOURCE_CC = "cc"

local DB_PATH = "~/.local/share/opencode/opencode.db"

-- ============================================================================
-- In-memory TTL cache for list_sessions()
-- ============================================================================

local SESSIONS_TTL = 5 -- seconds
local _sessions_cached_at = 0
local _sessions_cached = {}

-- ============================================================================
-- Tool name mapping (opencode lowercase -> CC proper case)
-- ============================================================================

local _TOOL_NAME_MAP = {
    bash = "Bash",
    read = "Read",
    glob = "Glob",
    grep = "Grep",
    edit = "Edit",
    write = "Write",
    webfetch = "WebFetch",
    websearch = "WebSearch",
    question = "Question",
    todowrite = "TodoWrite",
    codesearch = "CodeSearch",
    skill = "Skill",
    task = "Agent",
}

local function _map_tool_name(raw)
    if not raw or raw == "" then
        return "Tool"
    end
    local mapped = _TOOL_NAME_MAP[raw]
    if mapped then
        return mapped
    end
    return raw:sub(1, 1):upper() .. raw:sub(2)
end

-- Build the CC-compatible input table for a tool_use block.
-- Mirrors WenZi's _build_tool_input: preserves original keys, ensures
-- Agent has subagent_type, and copies state.title into description.
local function _build_tool_input(tool_name, raw_input, title)
    local inp = {}
    if type(raw_input) == "table" then
        for k, v in pairs(raw_input) do
            inp[k] = v
        end
    end
    if tool_name == "Agent" and inp.subagent_type == nil then
        inp.subagent_type = "general-purpose"
    end
    if title and title ~= "" and inp.description == nil then
        inp.description = title
    end
    return inp
end

-- ============================================================================
-- Misc helpers
-- ============================================================================

local function _ms_to_iso(ms)
    if not ms or type(ms) ~= "number" then
        return ""
    end
    local ts = math.floor(ms / 1000)
    return os.date("!%Y-%m-%dT%H:%M:%S", ts) .. "Z"
end

-- Pseudo-unique call ID for tool_use blocks that lack one. Counter keeps ids
-- distinct within a single export pass; time prefix keeps them distinct
-- across passes.
local _call_counter = 0
local function _make_call_id()
    _call_counter = _call_counter + 1
    return string.format("oc_%d_%d", os.time(), _call_counter)
end

-- Parse "<description> (@<agent_type> subagent)" -> description, agent_type.
local function _parse_subagent_title(title)
    if not title or title == "" then
        return "", ""
    end
    local desc, agent_type = title:match("^(.-)%s+%(@(%w+)%s+subagent%)%s*$")
    if desc then
        return desc, agent_type
    end
    return title, ""
end

-- Derive a readable project name from a working directory path. Uses the
-- last path component; falls back to `fallback` when cwd is empty.
local function _project_from_cwd(cwd, fallback)
    if not cwd or cwd == "" then
        return fallback or ""
    end
    local name = cwd:match("([^/]+)/*$")
    if name and name ~= "" then
        return name
    end
    return fallback or ""
end

-- Build a placeholder string "?,?,...,?" for IN clauses.
local function _placeholders(n)
    if n <= 0 then
        return ""
    end
    return string.rep("?,", n - 1) .. "?"
end

local function _json_parse(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local ok, obj = pcall(function()
        return lingxi.json.parse(raw)
    end)
    if ok and type(obj) == "table" then
        return obj
    end
    return nil
end

-- ============================================================================
-- DB access
-- ============================================================================

local function _open_db()
    local db, err = lingxi.db.openExternal(DB_PATH)
    if not db then
        return nil, err or "openExternal failed"
    end
    return db, nil
end

-- Returns {counts = {sid->n}, prompts = {sid->text}} for the given session ids.
-- Uses three batched queries to avoid N+1 round trips.
local function _batch_counts_and_prompts(db, ids)
    local counts, prompts = {}, {}
    if not ids or #ids == 0 then
        return counts, prompts
    end

    local ph = _placeholders(#ids)

    -- user message count per session
    local sql_counts = "SELECT session_id, COUNT(*) AS cnt FROM message "
        .. "WHERE session_id IN (" .. ph .. ") "
        .. "AND json_extract(data, '$.role') = 'user' "
        .. "GROUP BY session_id"
    local crows = db:query(sql_counts, ids)
    if crows then
        for _, r in ipairs(crows) do
            counts[r.session_id] = r.cnt or 0
        end
    end

    -- first user message id per session
    local sql_first_msg = "SELECT m.session_id, m.id FROM message m "
        .. "WHERE m.session_id IN (" .. ph .. ") "
        .. "AND json_extract(m.data, '$.role') = 'user' "
        .. "AND m.time_created = ("
        ..   "SELECT MIN(time_created) FROM message m2 "
        ..   "WHERE m2.session_id = m.session_id "
        ..   "AND json_extract(m2.data, '$.role') = 'user'"
        .. ")"
    local frows = db:query(sql_first_msg, ids)
    local first_msg_map = {}
    if frows then
        for _, r in ipairs(frows) do
            first_msg_map[r.session_id] = r.id
        end
    end

    -- first text part per first-message
    local msg_ids = {}
    for _, mid in pairs(first_msg_map) do
        table.insert(msg_ids, mid)
    end
    if #msg_ids == 0 then
        return counts, prompts
    end

    local mph = _placeholders(#msg_ids)
    local sql_parts = "SELECT p.message_id, p.data FROM part p "
        .. "WHERE p.message_id IN (" .. mph .. ") "
        .. "AND json_extract(p.data, '$.type') = 'text' "
        .. "AND p.time_created = ("
        ..   "SELECT MIN(time_created) FROM part p2 "
        ..   "WHERE p2.message_id = p.message_id "
        ..   "AND json_extract(p2.data, '$.type') = 'text'"
        .. ")"
    local prows = db:query(sql_parts, msg_ids)
    local part_map = {}
    if prows then
        for _, r in ipairs(prows) do
            if not part_map[r.message_id] then
                local pdata = _json_parse(r.data)
                local text = (pdata and pdata.text) or ""
                part_map[r.message_id] = text:sub(1, 200)
            end
        end
    end

    for sid, mid in pairs(first_msg_map) do
        prompts[sid] = part_map[mid] or ""
    end

    return counts, prompts
end

-- ============================================================================
-- Part -> CC message conversion
-- ============================================================================

local function _convert_message(msg_data, ts_ms, parts)
    local role = msg_data.role
    if role ~= "user" and role ~= "assistant" then
        return nil
    end

    local timestamp = _ms_to_iso(ts_ms)
    local path_info = msg_data.path
    local cwd = ""
    if type(path_info) == "table" then
        cwd = path_info.cwd or ""
    end

    local content_parts = {}
    for _, p in ipairs(parts or {}) do
        local pt = p.type
        if pt == "text" then
            local text = p.text or ""
            if text ~= "" and not p.synthetic then
                table.insert(content_parts, { type = "text", text = text })
            end
        elseif pt == "reasoning" then
            local text = p.text or ""
            if text ~= "" then
                table.insert(content_parts, { type = "thinking", thinking = text })
            end
        elseif pt == "tool" then
            local tool_name = _map_tool_name(p.tool or "tool")
            local call_id = p.callID or _make_call_id()
            local state = p.state or {}
            local inp = _build_tool_input(tool_name, state.input, state.title or "")
            local out = state.output
            if type(out) ~= "string" then
                out = out == nil and "" or tostring(out)
            end
            table.insert(content_parts, {
                type = "tool_use",
                id = call_id,
                name = tool_name,
                input = inp,
            })
            table.insert(content_parts, {
                type = "tool_result",
                tool_use_id = call_id,
                content = out,
            })
        elseif pt == "file" then
            local filename = p.filename or ""
            if filename ~= "" then
                table.insert(content_parts, { type = "text", text = "@" .. filename })
            end
        elseif pt == "patch" then
            local files = p.files
            if type(files) == "table" and #files > 0 then
                table.insert(content_parts, { type = "text", text = "[Patch] " .. table.concat(files, ", ") })
            end
        elseif pt == "step-start" or pt == "step-finish" or pt == "subtask" or pt == "compaction" then
            -- intentionally dropped
        else
            local text = p.text
            if type(text) == "string" and text ~= "" then
                table.insert(content_parts, { type = "text", text = text })
            end
        end
    end

    if role == "user" then
        local texts = {}
        for _, cp in ipairs(content_parts) do
            if cp.text and cp.text ~= "" then
                table.insert(texts, cp.text)
            end
        end
        local user_text = table.concat(texts, " ")
        if user_text == "" then
            return nil
        end
        return {
            type = "user",
            timestamp = timestamp,
            cwd = cwd,
            message = { content = user_text },
        }
    end

    local usage = msg_data.tokens or {}
    local model = msg_data.modelID or ""
    if #content_parts == 0 then
        content_parts = { { type = "text", text = "" } }
    end
    return {
        type = "assistant",
        timestamp = timestamp,
        cwd = cwd,
        version = msg_data.version or "",
        message = {
            content = content_parts,
            usage = {
                input_tokens = (type(usage) == "table" and usage.input) or 0,
                output_tokens = (type(usage) == "table" and usage.output) or 0,
            },
            model = model,
        },
    }
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Return true if the OpenCode database is present and openable.
function M.has_database()
    local db = lingxi.db.openExternal(DB_PATH)
    if not db then
        return false
    end
    db:close()
    return true
end

-- Return parent-level OpenCode sessions formatted like cc sessions. `file_path`
-- uses the pseudo-scheme `opencode://<session_id>` so callers can distinguish
-- the source without colliding with real filesystem paths.
function M.list_sessions()
    local now = os.time()
    if _sessions_cached and (now - _sessions_cached_at) < SESSIONS_TTL then
        return _sessions_cached
    end

    local db, err = _open_db()
    if not db then
        lingxi.log.write("[opencode_store] list_sessions: db unavailable (" .. tostring(err) .. ")")
        _sessions_cached_at = now
        _sessions_cached = {}
        return {}
    end

    local rows, qerr = db:query([[
        SELECT id, project_id, parent_id, slug, directory, title, version,
               time_created, time_updated
        FROM session
        WHERE parent_id IS NULL
        ORDER BY time_updated DESC
    ]])
    if not rows then
        lingxi.log.write("[opencode_store] list_sessions query error: " .. tostring(qerr))
        db:close()
        _sessions_cached_at = now
        _sessions_cached = {}
        return {}
    end

    local ids = {}
    for _, r in ipairs(rows) do
        table.insert(ids, r.id)
    end
    local counts, prompts = _batch_counts_and_prompts(db, ids)

    local sessions = {}
    for _, r in ipairs(rows) do
        local sid = r.id
        local cwd = r.directory or ""
        local project = _project_from_cwd(cwd, r.slug or "")
        local title = r.title
        if not title or title == "" then
            title = r.slug or "Untitled"
        end
        table.insert(sessions, {
            session_id = sid,
            file_path = "opencode://" .. sid,
            project = project,
            cwd = cwd,
            title = title,
            first_prompt = prompts[sid] or "",
            git_branch = "",
            created = _ms_to_iso(r.time_created),
            modified = _ms_to_iso(r.time_updated),
            message_count = counts[sid] or 0,
            version = r.version or "",
            summary = "",
            custom_title = "",
            source = M.SOURCE,
        })
    end

    db:close()
    _sessions_cached_at = now
    _sessions_cached = sessions
    return sessions
end

-- Return lightweight metadata for a single session (parent or subagent).
-- Used when opening a session via a pseudo path and only the session id is
-- known. Returns nil when the session doesn't exist or the db is unavailable.
function M.get_session_meta(sid)
    if not sid or sid == "" then
        return nil
    end
    local db, err = _open_db()
    if not db then
        lingxi.log.write("[opencode_store] get_session_meta: db unavailable (" .. tostring(err) .. ")")
        return nil
    end
    local row = db:queryOne([[
        SELECT id, parent_id, slug, directory, title, version,
               time_created, time_updated
        FROM session
        WHERE id = ?
    ]], { sid })
    db:close()
    if not row then
        return nil
    end

    local cwd = row.directory or ""
    local project = _project_from_cwd(cwd, row.slug or "")
    local title = row.title
    if not title or title == "" then
        title = row.slug or "Untitled"
    end

    return {
        session_id = row.id,
        parent_id = row.parent_id,
        project = project,
        cwd = cwd,
        title = title,
        git_branch = "",
        version = row.version or "",
        created = _ms_to_iso(row.time_created),
        modified = _ms_to_iso(row.time_updated),
        summary = "",
        custom_title = "",
        source = M.SOURCE,
    }
end

-- Return the modelID of the first assistant message in a session.
-- `db` must be an open handle owned by the caller (not closed here).
local function _first_assistant_model(db, sid)
    local row = db:queryOne([[
        SELECT json_extract(data, '$.modelID') AS model
        FROM message
        WHERE session_id = ? AND json_extract(data, '$.role') = 'assistant'
        ORDER BY time_created
        LIMIT 1
    ]], { sid })
    if row and row.model and row.model ~= "" then
        return row.model
    end
    return ""
end

-- Return subagent sessions spawned by `parent_id`, each with agent_id /
-- description / agent_type / model / version.
function M.list_subagents(parent_id)
    if not parent_id or parent_id == "" then
        return {}
    end
    local db, err = _open_db()
    if not db then
        lingxi.log.write("[opencode_store] list_subagents: db unavailable (" .. tostring(err) .. ")")
        return {}
    end

    local rows, qerr = db:query(
        "SELECT id, title, version FROM session WHERE parent_id = ?",
        { parent_id }
    )
    if not rows then
        lingxi.log.write("[opencode_store] list_subagents query error: " .. tostring(qerr))
        db:close()
        return {}
    end

    local results = {}
    for _, r in ipairs(rows) do
        local description, agent_type = _parse_subagent_title(r.title or "")
        local model = _first_assistant_model(db, r.id)
        table.insert(results, {
            agent_id = r.id,
            description = description,
            agent_type = agent_type,
            model = model,
            version = r.version or "",
        })
    end
    db:close()
    return results
end

-- Return {agent_id -> {exists=bool, model=string}} for each requested id.
function M.check_subagent_exists(parent_id, agent_ids)
    local result = {}
    if not agent_ids or #agent_ids == 0 then
        return result
    end

    local db, err = _open_db()
    if not db then
        lingxi.log.write("[opencode_store] check_subagent_exists: db unavailable (" .. tostring(err) .. ")")
        for _, aid in ipairs(agent_ids) do
            result[aid] = { exists = false, model = "" }
        end
        return result
    end

    local ph = _placeholders(#agent_ids)
    local params = { parent_id }
    for _, aid in ipairs(agent_ids) do
        table.insert(params, aid)
    end
    local rows = db:query(
        "SELECT id FROM session WHERE parent_id = ? AND id IN (" .. ph .. ")",
        params
    )
    local existing = {}
    if rows then
        for _, r in ipairs(rows) do
            existing[r.id] = true
        end
    end

    for _, aid in ipairs(agent_ids) do
        local model = ""
        if existing[aid] then
            model = _first_assistant_model(db, aid)
        end
        result[aid] = { exists = existing[aid] == true, model = model }
    end
    db:close()
    return result
end

-- Export a single session (parent or subagent) to a CC-compatible JSONL file.
-- `out_path` must be writable by the plugin (typically under the plugin
-- cache dir). Creates parent directories as needed. Returns true on success,
-- or false + error string on failure.
function M.export_to_jsonl(sid, out_path)
    if not sid or sid == "" then
        return false, "sid is empty"
    end
    if not out_path or out_path == "" then
        return false, "out_path is empty"
    end

    local db, err = _open_db()
    if not db then
        return false, err or "db unavailable"
    end

    local messages, merr = db:query(
        "SELECT id, data, time_created FROM message WHERE session_id = ? ORDER BY time_created",
        { sid }
    )
    if not messages then
        db:close()
        return false, merr or "message query failed"
    end

    local parts_rows, perr = db:query(
        "SELECT message_id, data FROM part WHERE session_id = ? ORDER BY time_created",
        { sid }
    )
    if not parts_rows then
        db:close()
        return false, perr or "part query failed"
    end

    -- Group parts by message_id
    local parts_by_msg = {}
    for _, pr in ipairs(parts_rows) do
        local pdata = _json_parse(pr.data)
        if pdata then
            if not parts_by_msg[pr.message_id] then
                parts_by_msg[pr.message_id] = {}
            end
            table.insert(parts_by_msg[pr.message_id], pdata)
        end
    end

    -- Convert each message to a JSONL line. lingxi.json.encode is compact by
    -- default, which is exactly what JSONL framing needs.
    local lines = {}
    for _, m in ipairs(messages) do
        local mdata = _json_parse(m.data)
        if mdata then
            local converted = _convert_message(mdata, m.time_created, parts_by_msg[m.id] or {})
            if converted then
                local ok, encoded = pcall(function()
                    return lingxi.json.encode(converted)
                end)
                if ok and type(encoded) == "string" and encoded ~= "" then
                    table.insert(lines, encoded)
                end
            end
        end
    end

    db:close()

    -- Ensure parent directory exists
    local parent_dir = out_path:match("^(.*)/[^/]+$")
    if parent_dir and parent_dir ~= "" then
        lingxi.file.mkdir(parent_dir)
    end

    local content = table.concat(lines, "\n")
    if #lines > 0 then
        content = content .. "\n"
    end
    local ok = lingxi.file.write(out_path, content)
    if not ok then
        return false, "write failed: " .. tostring(out_path)
    end
    return true
end

function M.clear_cache()
    _sessions_cached_at = 0
    _sessions_cached = {}
end

return M
