-- kimi_store.lua - Read Kimi Code CLI sessions from ~/.kimi/sessions/.
-- Kimi stores each session at <SESSIONS_BASE>/<md5(cwd)>/<session-uuid>/
-- with two files:
--   context.jsonl — per-message transcript (the source used here)
--   wire.jsonl    — per-event stream with float-second timestamps
--
-- Bridges the Kimi record schema to the CC JSONL structure consumed by
-- scanner/reader/viewer, mirroring opencode_store.lua.

local M = {}

M.SOURCE = "kimi"

local SESSIONS_BASE = "~/.kimi/sessions"
local KIMI_JSON_PATH = "~/.kimi/kimi.json"

-- ============================================================================
-- In-memory TTL cache for list_sessions()
-- ============================================================================

local SESSIONS_TTL = 5 -- seconds
local _sessions_cached_at = 0
local _sessions_cached = {}

-- ============================================================================
-- Tool name mapping (Kimi PascalCase -> CC canonical)
-- ============================================================================

local _TOOL_NAME_MAP = {
    ReadFile = "Read",
    WriteFile = "Write",
    StrReplaceFile = "Edit",
    Shell = "Bash",
    Glob = "Glob",
    Grep = "Grep",
    WebFetch = "WebFetch",
    WebSearch = "WebSearch",
    TodoWrite = "TodoWrite",
    Agent = "Agent",
    Task = "Agent",
}

local function _map_tool_name(raw)
    if not raw or raw == "" then
        return "Tool"
    end
    local mapped = _TOOL_NAME_MAP[raw]
    if mapped then
        return mapped
    end
    return raw
end

-- ============================================================================
-- Misc helpers
-- ============================================================================

local function _unix_to_iso(ts)
    if type(ts) ~= "number" then
        return ""
    end
    return os.date("!%Y-%m-%dT%H:%M:%S", math.floor(ts)) .. "Z"
end

local _call_counter = 0
local function _make_call_id()
    _call_counter = _call_counter + 1
    return string.format("kimi_%d_%d", os.time(), _call_counter)
end

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
-- Hash -> cwd mapping
-- ============================================================================

-- Build {md5(path) -> path} from ~/.kimi/kimi.json's work_dirs. Used as the
-- primary lookup; context.jsonl's _system_prompt is the fallback so sessions
-- for directories no longer in work_dirs still resolve.
local function _load_hash_to_cwd()
    local map = {}
    local exists = lingxi.file.exists(KIMI_JSON_PATH)
    if not exists then
        return map
    end
    local content = lingxi.file.read(KIMI_JSON_PATH)
    if not content then
        return map
    end
    local data = _json_parse(content)
    if not data or type(data.work_dirs) ~= "table" then
        return map
    end
    for _, entry in ipairs(data.work_dirs) do
        local path = entry.path
        if type(path) == "string" and path ~= "" then
            local h = lingxi.crypto.md5(path)
            if h and h ~= "" then
                map[h] = path
            end
        end
    end
    return map
end

-- Parse "The current working directory is `<path>`" out of a Kimi system
-- prompt. Returns "" if not found.
local function _cwd_from_system_prompt(prompt)
    if type(prompt) ~= "string" or prompt == "" then
        return ""
    end
    local cwd = prompt:match("current working directory is `([^`]+)`")
    return cwd or ""
end

-- ============================================================================
-- context.jsonl scanning (metadata + preview turns)
-- ============================================================================

-- Kimi noise markers that mirror CC's system/command tags; strip from first
-- user prompt so the launcher title isn't a synthetic hook envelope.
local _NOISE_PATTERNS = {
    "^<system%-reminder",
    "^<system>",
    "^<command%-name",
    "^<command%-message",
    "^<command%-args",
    "^<local%-command",
}

local function _is_noise(text)
    for _, p in ipairs(_NOISE_PATTERNS) do
        if text:match(p) then
            return true
        end
    end
    return false
end

local function _extract_text(content)
    if type(content) == "string" then
        return content
    end
    if type(content) == "table" then
        local parts = {}
        for _, p in ipairs(content) do
            if type(p) == "table" and (p.type or "text") == "text" then
                table.insert(parts, p.text or "")
            end
        end
        return table.concat(parts, " ")
    end
    return ""
end

-- Read a context.jsonl prefix and pull out:
--   cwd, first_user_message, preview turns, cumulative token_count
-- Stops after max_lines to keep the scan cheap even on long sessions.
local function _scan_context(context_path, max_turns)
    local result = {
        cwd = "",
        first_user_message = "",
        turns = {},
        token_count = 0,
    }

    local content = lingxi.file.read_lines(context_path, 120)
    if not content then
        return result
    end

    max_turns = max_turns or 10
    local ASSISTANT_TRUNCATE = 200
    local turns_collected = 0

    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local obj = _json_parse(trimmed)
            if obj then
                local role = obj.role
                if role == "_system_prompt" and result.cwd == "" then
                    result.cwd = _cwd_from_system_prompt(obj.content or "")
                elseif role == "_usage" then
                    -- _usage is cumulative — last one wins.
                    if type(obj.token_count) == "number" then
                        result.token_count = obj.token_count
                    end
                elseif role == "user" then
                    local text = _extract_text(obj.content)
                    if text ~= "" and not _is_noise(text) then
                        if result.first_user_message == "" then
                            result.first_user_message = text
                        end
                        if turns_collected < max_turns then
                            table.insert(result.turns, { role = "user", text = text })
                            turns_collected = turns_collected + 1
                        end
                    end
                elseif role == "assistant" then
                    -- Collect plain text only (skip think/tool_calls for preview).
                    local texts = {}
                    if type(obj.content) == "table" then
                        for _, p in ipairs(obj.content) do
                            if type(p) == "table" and p.type == "text" and type(p.text) == "string" then
                                table.insert(texts, p.text)
                            end
                        end
                    elseif type(obj.content) == "string" then
                        table.insert(texts, obj.content)
                    end
                    local text = table.concat(texts, " ")
                    if text ~= "" and turns_collected < max_turns then
                        if #text > ASSISTANT_TRUNCATE then
                            text = text:sub(1, ASSISTANT_TRUNCATE) .. "..."
                        end
                        table.insert(result.turns, { role = "assistant", text = text })
                        turns_collected = turns_collected + 1
                    end
                end
            end
        end
    end

    return result
end

-- First TurnBegin timestamp in wire.jsonl, converted to ISO-8601. Returns ""
-- when unavailable — the scanner falls back to the context.jsonl mtime.
local function _first_wire_timestamp(wire_path)
    local content = lingxi.file.read_lines(wire_path, 10)
    if not content then
        return ""
    end
    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local obj = _json_parse(trimmed)
            if obj and type(obj.timestamp) == "number" then
                return _unix_to_iso(obj.timestamp)
            end
        end
    end
    return ""
end

-- Ordered TurnBegin timestamps in wire.jsonl. Each entry is one turn's ISO
-- string; used to align user messages to their wall-clock moment.
local function _turn_begin_timestamps(wire_path)
    local out = {}
    local content = lingxi.file.read(wire_path)
    if not content then
        return out
    end
    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local obj = _json_parse(trimmed)
            if obj and type(obj.timestamp) == "number" then
                local msg = obj.message
                if type(msg) == "table" and msg.type == "TurnBegin" then
                    table.insert(out, _unix_to_iso(obj.timestamp))
                end
            end
        end
    end
    return out
end

-- ============================================================================
-- Session directory lookup
-- ============================================================================

-- Return (hash, session_dir, context_path) for a given session id, or nil.
local function _find_session(sid)
    if not sid or sid == "" then
        return nil
    end
    local hashes = lingxi.file.list(SESSIONS_BASE)
    if not hashes then
        return nil
    end
    for _, h in ipairs(hashes) do
        if h.isDir then
            local candidate_dir = SESSIONS_BASE .. "/" .. h.name .. "/" .. sid
            local ctx_path = candidate_dir .. "/context.jsonl"
            if lingxi.file.exists(ctx_path) then
                return h.name, candidate_dir, ctx_path
            end
        end
    end
    return nil
end

-- ============================================================================
-- Public API
-- ============================================================================

function M.list_sessions()
    local now = os.time()
    if _sessions_cached and (now - _sessions_cached_at) < SESSIONS_TTL then
        return _sessions_cached
    end

    local sessions = {}
    local exists = lingxi.file.exists(SESSIONS_BASE)
    if not exists then
        _sessions_cached_at = now
        _sessions_cached = sessions
        return sessions
    end

    local hash_to_cwd = _load_hash_to_cwd()

    local hashes = lingxi.file.list(SESSIONS_BASE)
    if not hashes then
        _sessions_cached_at = now
        _sessions_cached = sessions
        return sessions
    end

    for _, h in ipairs(hashes) do
        if h.isDir then
            local hash_cwd = hash_to_cwd[h.name] or ""
            local hash_dir = SESSIONS_BASE .. "/" .. h.name
            local sids = lingxi.file.list(hash_dir)
            if sids then
                for _, s in ipairs(sids) do
                    if s.isDir then
                        local session_dir = hash_dir .. "/" .. s.name
                        local ctx_path = session_dir .. "/context.jsonl"
                        local wire_path = session_dir .. "/wire.jsonl"

                        if lingxi.file.exists(ctx_path) then
                            local meta = _scan_context(ctx_path, 10)
                            local cwd = meta.cwd
                            if cwd == "" then
                                cwd = hash_cwd
                            end
                            local project = _project_from_cwd(cwd, "")

                            -- modified: context.jsonl mtime (last activity).
                            local modified_iso = ""
                            local stat = lingxi.file.stat(ctx_path)
                            if stat and type(stat.mtime) == "number" then
                                modified_iso = _unix_to_iso(stat.mtime)
                            end

                            -- created: first wire.jsonl TurnBegin timestamp
                            -- when available, else context.jsonl mtime.
                            local created_iso = _first_wire_timestamp(wire_path)
                            if created_iso == "" then
                                created_iso = modified_iso
                            end

                            local title = meta.first_user_message
                            if title == "" then
                                title = "Kimi Session"
                            elseif #title > 80 then
                                title = title:sub(1, 77) .. "..."
                            end

                            table.insert(sessions, {
                                session_id = s.name,
                                file_path = ctx_path,
                                project = project,
                                cwd = cwd,
                                title = title,
                                first_prompt = meta.first_user_message,
                                git_branch = "",
                                created = created_iso,
                                modified = modified_iso,
                                message_count = 0,
                                version = "",
                                summary = "",
                                custom_title = "",
                                source = M.SOURCE,
                                detail = {
                                    turns = meta.turns,
                                    total_input_tokens = meta.token_count,
                                    total_output_tokens = 0,
                                },
                            })
                        end
                    end
                end
            end
        end
    end

    _sessions_cached_at = now
    _sessions_cached = sessions
    return sessions
end

function M.get_session_detail(sid, max_turns)
    local result = { turns = {}, total_input_tokens = 0, total_output_tokens = 0 }
    local _, _, ctx_path = _find_session(sid)
    if not ctx_path then
        return result
    end
    local meta = _scan_context(ctx_path, max_turns or 10)
    result.turns = meta.turns
    result.total_input_tokens = meta.token_count
    return result
end

function M.get_session_meta(sid)
    local _, session_dir, ctx_path = _find_session(sid)
    if not ctx_path then
        return nil
    end
    local meta = _scan_context(ctx_path, 0)
    local cwd = meta.cwd
    if cwd == "" then
        local hash_to_cwd = _load_hash_to_cwd()
        -- session_dir is "<base>/<hash>/<sid>"; extract hash segment.
        local hash = session_dir:match("/([^/]+)/[^/]+$")
        if hash then
            cwd = hash_to_cwd[hash] or ""
        end
    end
    local project = _project_from_cwd(cwd, "")
    local title = meta.first_user_message
    if title == "" then
        title = "Kimi Session"
    elseif #title > 80 then
        title = title:sub(1, 77) .. "..."
    end

    local modified_iso = ""
    local stat = lingxi.file.stat(ctx_path)
    if stat and type(stat.mtime) == "number" then
        modified_iso = _unix_to_iso(stat.mtime)
    end

    return {
        session_id = sid,
        file_path = ctx_path,
        project = project,
        cwd = cwd,
        title = title,
        git_branch = "",
        version = "",
        created = modified_iso,
        modified = modified_iso,
        summary = "",
        custom_title = "",
        source = M.SOURCE,
    }
end

-- Kimi doesn't persist subagents as separate sessions — SubagentEvent entries
-- are inlined into the parent's wire.jsonl. Return empty so the viewer won't
-- show phantom links.
function M.list_subagents(_parent_id)
    return {}
end

-- ============================================================================
-- Export context.jsonl -> CC-format JSONL for the viewer
-- ============================================================================

function M.export_to_jsonl(sid, out_path)
    if not sid or sid == "" then
        return false, "sid is empty"
    end
    if not out_path or out_path == "" then
        return false, "out_path is empty"
    end

    local _, session_dir, ctx_path = _find_session(sid)
    if not ctx_path then
        return false, "session not found: " .. sid
    end
    local wire_path = session_dir .. "/wire.jsonl"

    local content = lingxi.file.read(ctx_path)
    if not content then
        return false, "read failed: " .. ctx_path
    end

    -- Parse all records up front so we can walk them with one-message lookahead
    -- (pending tool results need to be flushed on the next non-tool record).
    local records = {}
    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local obj = _json_parse(trimmed)
            if obj then
                table.insert(records, obj)
            end
        end
    end

    -- Pull cwd / version-ish / first wire timestamp for message meta.
    local cwd = ""
    for _, rec in ipairs(records) do
        if rec.role == "_system_prompt" then
            cwd = _cwd_from_system_prompt(rec.content or "")
            break
        end
    end
    if cwd == "" then
        local hash_to_cwd = _load_hash_to_cwd()
        local hash = session_dir:match("/([^/]+)/[^/]+$")
        if hash then
            cwd = hash_to_cwd[hash] or ""
        end
    end

    local turn_timestamps = _turn_begin_timestamps(wire_path)
    local user_turn_idx = 0

    local lines = {}
    local pending_tool_ids = {}
    local pending_results = {}

    local function flush_results()
        if #pending_results == 0 then
            return
        end
        local msg = {
            type = "user",
            cwd = cwd,
            message = { content = pending_results },
        }
        local ok, encoded = pcall(function()
            return lingxi.json.encode(msg)
        end)
        if ok and type(encoded) == "string" and encoded ~= "" then
            table.insert(lines, encoded)
        end
        pending_results = {}
    end

    for _, rec in ipairs(records) do
        local role = rec.role

        if role == "user" then
            flush_results()
            pending_tool_ids = {}
            user_turn_idx = user_turn_idx + 1
            local ts = turn_timestamps[user_turn_idx] or ""
            local msg = {
                type = "user",
                timestamp = ts,
                cwd = cwd,
                message = { content = rec.content or "" },
            }
            local ok, encoded = pcall(function()
                return lingxi.json.encode(msg)
            end)
            if ok and type(encoded) == "string" and encoded ~= "" then
                table.insert(lines, encoded)
            end

        elseif role == "assistant" then
            flush_results()
            pending_tool_ids = {}

            local cc_content = {}
            if type(rec.content) == "table" then
                for _, p in ipairs(rec.content) do
                    if type(p) == "table" then
                        if p.type == "think" then
                            local txt = p.think or ""
                            if txt ~= "" then
                                table.insert(cc_content, { type = "thinking", thinking = txt })
                            end
                        elseif p.type == "text" then
                            local txt = p.text or ""
                            if txt ~= "" then
                                table.insert(cc_content, { type = "text", text = txt })
                            end
                        end
                    end
                end
            elseif type(rec.content) == "string" and rec.content ~= "" then
                table.insert(cc_content, { type = "text", text = rec.content })
            end

            if type(rec.tool_calls) == "table" then
                for _, tc in ipairs(rec.tool_calls) do
                    local fn = tc["function"] or {}
                    local name = _map_tool_name(fn.name or "")
                    local input = _json_parse(fn.arguments) or {}
                    local call_id = tc.id or _make_call_id()
                    table.insert(cc_content, {
                        type = "tool_use",
                        id = call_id,
                        name = name,
                        input = input,
                    })
                    table.insert(pending_tool_ids, call_id)
                end
            end

            if #cc_content == 0 then
                cc_content = { { type = "text", text = "" } }
            end

            local msg = {
                type = "assistant",
                cwd = cwd,
                message = {
                    content = cc_content,
                    model = "",
                    usage = { input_tokens = 0, output_tokens = 0 },
                },
            }
            local ok, encoded = pcall(function()
                return lingxi.json.encode(msg)
            end)
            if ok and type(encoded) == "string" and encoded ~= "" then
                table.insert(lines, encoded)
            end

        elseif role == "tool" then
            -- Kimi tool records carry no tool_call_id — match positionally
            -- against the preceding assistant's tool_calls.
            local call_id = table.remove(pending_tool_ids, 1) or _make_call_id()
            local raw = rec.content
            local text
            if type(raw) == "string" then
                text = raw
            elseif type(raw) == "table" then
                -- OpenAI-style list of parts; flatten text parts.
                local parts = {}
                for _, p in ipairs(raw) do
                    if type(p) == "table" and type(p.text) == "string" then
                        table.insert(parts, p.text)
                    end
                end
                text = table.concat(parts, "\n")
            else
                text = ""
            end
            table.insert(pending_results, {
                type = "tool_result",
                tool_use_id = call_id,
                content = text,
            })
        end
        -- Skip _system_prompt, _checkpoint, _usage — they have no CC equivalent.
    end
    flush_results()

    local parent_dir = out_path:match("^(.*)/[^/]+$")
    if parent_dir and parent_dir ~= "" then
        lingxi.file.mkdir(parent_dir)
    end

    local out = table.concat(lines, "\n")
    if #lines > 0 then
        out = out .. "\n"
    end
    local ok = lingxi.file.write(out_path, out)
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
