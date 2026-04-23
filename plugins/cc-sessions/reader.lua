-- reader.lua - JSONL 读取与解析
-- Reads Claude Code session JSONL files and extracts structured data.

local M = {}

-- Extract text from user message content (string or parts list)
function M.extract_user_text(content)
    if type(content) == "string" then
        return content
    end
    if type(content) == "table" then
        local parts = {}
        for _, p in ipairs(content) do
            if type(p) == "table" then
                if (p.type or "text") == "text" then
                    table.insert(parts, p.text or "")
                end
            elseif type(p) == "string" then
                table.insert(parts, p)
            end
        end
        return table.concat(parts, " ")
    end
    return ""
end

-- Extract text from assistant message content, skipping thinking/tool_use
function M.extract_assistant_text(content)
    if type(content) == "string" then
        return content
    end
    if type(content) == "table" then
        local parts = {}
        for _, p in ipairs(content) do
            if type(p) == "table" and p.type == "text" then
                table.insert(parts, p.text or "")
            end
        end
        return table.concat(parts, " ")
    end
    return ""
end

-- Read a session JSONL and extract metadata from early lines
-- Returns: {
--   session_id = string,
--   cwd = string,
--   version = string,
--   git_branch = string,
--   first_timestamp = string,
--   last_timestamp = string,
--   custom_title = string,
--   summary = string,
--   first_user_message = string,
--   user_msg_count = number,
-- }
function M.read_metadata(file_path)
    local content = lingxi.file.read(file_path)
    if not content then
        lingxi.log.write("[reader] read_metadata: failed to read file " .. file_path)
        return nil
    end
    lingxi.log.write("[reader] read_metadata: read " .. #content .. " bytes from " .. file_path)

    local result = {
        session_id = "",
        cwd = "",
        version = "",
        git_branch = "",
        first_timestamp = nil,
        last_timestamp = nil,
        custom_title = "",
        summary = "",
        first_user_message = nil,
        user_msg_count = 0,
    }

    local metadata_lines = 30
    local line_count = 0

    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed == "" then
            goto continue
        end

        line_count = line_count + 1

        -- Count real user messages via string matching (entire file)
        if trimmed:find('"type":"user"', 1, true) then
            if not trimmed:find("tool_result", 1, true)
               and not trimmed:find("toolUseResult", 1, true)
               and not trimmed:find("<local-command-caveat>", 1, true)
               and not trimmed:find("<command-name>", 1, true) then
                result.user_msg_count = result.user_msg_count + 1
            end
        end

        -- Detect custom-title entries
        if trimmed:find('"type":"custom-title"', 1, true) then
            local ok, ct_obj = pcall(function()
                return lingxi.json.parse(trimmed)
            end)
            if ok and type(ct_obj) == "table" then
                result.custom_title = ct_obj.customTitle or ""
            end
        end

        -- Extract plan title as summary via string matching
        if result.summary == "" and trimmed:find('"planContent"', 1, true) and trimmed:find('"# ', 1, true) then
            local pc_idx = trimmed:find('"planContent"', 1, true)
            local heading_idx = trimmed:find('"# ', pc_idx, true)
            if heading_idx then
                local start = heading_idx + 3
                local heading_text = trimmed:sub(start)
                local end_pos = #heading_text + 1
                for _, stop in ipairs({"\\n", '"'}) do
                    local pos = heading_text:find(stop, 1, true)
                    if pos and pos < end_pos then
                        end_pos = pos
                    end
                end
                result.summary = heading_text:sub(1, end_pos - 1):match("^%s*(.-)%s*$")
            end
        end

        -- Extract metadata from early lines only
        if line_count > metadata_lines then
            goto continue
        end

        local ok, obj = pcall(function()
            return lingxi.json.parse(trimmed)
        end)
        if not ok or type(obj) ~= "table" then
            goto continue
        end

        local ts = obj.timestamp
        if ts then
            if not result.first_timestamp then
                result.first_timestamp = ts
            end
            result.last_timestamp = ts
        end

        if result.cwd == "" and obj.cwd then
            result.cwd = obj.cwd
        end
        if result.version == "" and obj.version then
            result.version = obj.version
        end
        if result.git_branch == "" and obj.gitBranch then
            result.git_branch = obj.gitBranch
        end

        if result.first_user_message == nil and obj.type == "user" then
            local msg = obj.message or {}
            if type(msg) == "table" then
                local text = M.extract_user_text(msg.content or "")
                if text and text ~= "" then
                    -- Check if it's a noise message
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
                        if text:match(pattern) then
                            is_noise = true
                            break
                        end
                    end
                    if not is_noise then
                        result.first_user_message = text
                    end
                end
            end
        end

        ::continue::
    end

    lingxi.log.write("[reader] read_metadata: line_count=" .. line_count .. ", first_timestamp=" .. tostring(result.first_timestamp) .. ", first_user_message=" .. tostring(result.first_user_message and result.first_user_message:sub(1, 50) or "nil"))
    if result.first_timestamp == nil and result.first_user_message == nil then
        lingxi.log.write("[reader] read_metadata: returning nil - no timestamp or user message found")
        return nil
    end

    lingxi.log.write("[reader] read_metadata: returning result")
    return result
end

-- Read session detail for preview (up to max_turns)
-- Returns: {
--   turns = { {role="user"|"assistant", text=string}, ... },
--   total_input_tokens = number,
--   total_output_tokens = number,
-- }
function M.read_detail(file_path, max_turns)
    max_turns = max_turns or 10
    local content = lingxi.file.read(file_path)
    if not content then
        return { turns = {}, total_input_tokens = 0, total_output_tokens = 0 }
    end

    local result = {
        turns = {},
        total_input_tokens = 0,
        total_output_tokens = 0,
    }

    local turns_collected = 0
    local ASSISTANT_TRUNCATE = 200

    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed == "" then
            goto continue
        end

        local ok, obj = pcall(function()
            return lingxi.json.parse(trimmed)
        end)
        if not ok or type(obj) ~= "table" then
            goto continue
        end

        local msg_type = obj.type
        local message = obj.message or {}
        if type(message) ~= "table" then
            goto continue
        end

        -- Sum token usage from all assistant messages
        if msg_type == "assistant" then
            local usage = message.usage or {}
            if type(usage) == "table" then
                result.total_input_tokens = result.total_input_tokens + (usage.input_tokens or 0)
                result.total_output_tokens = result.total_output_tokens + (usage.output_tokens or 0)
            end
        end

        -- Collect conversation turns (up to max_turns)
        if turns_collected >= max_turns then
            goto continue
        end

        if msg_type == "user" then
            local text = M.extract_user_text(message.content or "")
            if text and text ~= "" then
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
                    if text:match(pattern) then
                        is_noise = true
                        break
                    end
                end
                if not is_noise then
                    table.insert(result.turns, { role = "user", text = text })
                    turns_collected = turns_collected + 1
                end
            end
        elseif msg_type == "assistant" then
            local text = M.extract_assistant_text(message.content or "")
            if text and text ~= "" then
                if #text > ASSISTANT_TRUNCATE then
                    text = text:sub(1, ASSISTANT_TRUNCATE) .. "..."
                end
                table.insert(result.turns, { role = "assistant", text = text })
                turns_collected = turns_collected + 1
            end
        end

        ::continue::
    end

    return result
end

return M
