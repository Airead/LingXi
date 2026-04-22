-- Emoji Search Plugin for LingXi
-- Search and paste emoji via the launcher (prefix: e)

local _MAX_RESULTS = 30
local _MAX_GROUP_RESULTS = 200
local _DATA_FILE = "emoji-tree.json"

-- Global data structures (loaded once)
local _records = {}
local _group_map = {}
local _groups = {}
local _data_loaded = false

-- ============================================================================
-- Data Loading
-- ============================================================================

local function _load_emoji_data()
    if _data_loaded then
        return
    end

    local content = lingxi.file.read(_DATA_FILE)
    if not content then
        lingxi.log.write("Emoji data file not found: " .. _DATA_FILE)
        return
    end

    local tree = lingxi.json.parse(content)
    if not tree then
        lingxi.log.write("Failed to parse emoji data file")
        return
    end

    local group_seen = {}

    for _, group in ipairs(tree) do
        local group_en = group.name or ""
        local group_zh = ""
        if group.name_i18n and group.name_i18n.zh_CN then
            group_zh = group.name_i18n.zh_CN
        end

        local group_emojis = {}
        local group_chars = {}

        for _, subgroup in ipairs(group.list or {}) do
            for _, entry in ipairs(subgroup.list or {}) do
                local char = entry.char or ""
                if char ~= "" then
                    local found = false
                    for _, c in ipairs(group_chars) do
                        if c == char then
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(group_chars, char)
                    end
                end
            end
        end

        local first_char = group_chars[1] or ""

        if group_en ~= "" then
            local key = string.lower(group_en)
            if not group_seen[key] then
                group_seen[key] = true
                table.insert(_groups, {
                    name_en = group_en,
                    name_zh = group_zh,
                    char = first_char,
                    chars = group_chars,
                })
            end
        end

        for _, subgroup in ipairs(group.list or {}) do
            local subgroup_en = subgroup.name or ""
            local subgroup_zh = ""
            if subgroup.name_i18n and subgroup.name_i18n.zh_CN then
                subgroup_zh = subgroup.name_i18n.zh_CN
            end

            local subgroup_emojis = {}

            for _, entry in ipairs(subgroup.list or {}) do
                local name_i18n = entry.name_i18n or {}
                local rec = {
                    char = entry.char or "",
                    name_en = entry.name or "",
                    name_zh = name_i18n.zh_CN or "",
                    group_en = group_en,
                    group_zh = group_zh,
                    subgroup_en = subgroup_en,
                    subgroup_zh = subgroup_zh,
                }
                table.insert(_records, rec)
                table.insert(group_emojis, rec)
                table.insert(subgroup_emojis, rec)
            end

            if subgroup_en ~= "" then
                local key = string.lower(subgroup_en)
                if not _group_map[key] then
                    _group_map[key] = {}
                end
                for _, rec in ipairs(subgroup_emojis) do
                    table.insert(_group_map[key], rec)
                end
            end

            if subgroup_zh ~= "" then
                local key = string.lower(subgroup_zh)
                if not _group_map[key] then
                    _group_map[key] = {}
                end
                for _, rec in ipairs(subgroup_emojis) do
                    table.insert(_group_map[key], rec)
                end
            end
        end

        if group_en ~= "" then
            local key = string.lower(group_en)
            if not _group_map[key] then
                _group_map[key] = {}
            end
            for _, rec in ipairs(group_emojis) do
                table.insert(_group_map[key], rec)
            end
        end

        if group_zh ~= "" then
            local key = string.lower(group_zh)
            if not _group_map[key] then
                _group_map[key] = {}
            end
            for _, rec in ipairs(group_emojis) do
                table.insert(_group_map[key], rec)
            end
        end
    end

    _data_loaded = true
end

-- ============================================================================
-- Query Parsing
-- ============================================================================

local function _parse_query(query)
    local text = query:match("^%s*(.-)%s*$")
    if not text:find("@") then
        return text, nil
    end

    local at_index = text:find("@")
    local before = text:sub(1, at_index - 1):match("^%s*(.-)%s*$")
    local after = text:sub(at_index + 1):match("^%s*(.-)%s*$"):lower()

    if after == "" then
        return before, ""
    end

    -- Try exact match with progressively longer prefixes
    local parts = {}
    for part in after:gmatch("%S+") do
        table.insert(parts, part)
    end

    for i = #parts, 1, -1 do
        local candidate = table.concat(parts, " ", 1, i)
        if _group_map[candidate] then
            local remaining = {}
            if before ~= "" then
                table.insert(remaining, before)
            end
            for j = i + 1, #parts do
                table.insert(remaining, parts[j])
            end
            return table.concat(remaining, " "):match("^%s*(.-)%s*$"), candidate
        end
    end

    -- Fallback: fuzzy match using lingxi.fuzzy.search
    local group_keys = {}
    for key, _ in pairs(_group_map) do
        table.insert(group_keys, { name = key })
    end

    local fuzzy_results = lingxi.fuzzy.search(after, group_keys, { "name" })
    if #fuzzy_results > 0 then
        local best = fuzzy_results[1]
        local matched_name = best.item.name
        local matched_parts = {}
        for part in after:gmatch("%S+") do
            table.insert(matched_parts, part)
        end

        -- Find how many parts matched
        local candidate = table.concat(matched_parts, " ")
        local best_i = #matched_parts
        for i = #matched_parts, 1, -1 do
            local test = table.concat(matched_parts, " ", 1, i)
            if test == matched_name or matched_name:find(test, 1, true) == 1 then
                best_i = i
                break
            end
        end

        local remaining = {}
        if before ~= "" then
            table.insert(remaining, before)
        end
        for j = best_i + 1, #matched_parts do
            table.insert(remaining, matched_parts[j])
        end
        return table.concat(remaining, " "):match("^%s*(.-)%s*$"), matched_name
    end

    -- Final fallback: treat whole after-@ text as group filter
    return before, after
end

-- ============================================================================
-- Search Logic
-- ============================================================================

local function _search_emojis(query)
    local q, group_filter = _parse_query(query)
    q = q:lower()

    if not q and not group_filter then
        return {}
    end

    -- Determine search pool
    local pool = _records
    if group_filter then
        local matched_groups = {}
        local group_keys = {}
        for key, _ in pairs(_group_map) do
            table.insert(group_keys, { name = key })
        end

        local fuzzy_results = lingxi.fuzzy.search(group_filter, group_keys, { "name" })
        local seen_chars = {}
        pool = {}

        for _, match in ipairs(fuzzy_results) do
            local group_name = match.item.name
            local emojis = _group_map[group_name] or {}
            for _, rec in ipairs(emojis) do
                if rec.char ~= "" and not seen_chars[rec.char] then
                    seen_chars[rec.char] = true
                    table.insert(pool, rec)
                end
            end
        end
    end

    -- Group-only query: return pooled emojis
    if q == "" or q == nil then
        local results = {}
        for i = 1, math.min(#pool, _MAX_GROUP_RESULTS) do
            table.insert(results, pool[i])
        end
        return results
    end

    -- Fuzzy match within pool
    local fields
    if group_filter then
        fields = { "name_en", "name_zh" }
    else
        fields = { "name_en", "name_zh", "group_en", "group_zh", "subgroup_en", "subgroup_zh" }
    end

    local scored = lingxi.fuzzy.search(q, pool, fields)
    local max_results = group_filter and _MAX_GROUP_RESULTS or _MAX_RESULTS

    local results = {}
    for i = 1, math.min(#scored, max_results) do
        table.insert(results, scored[i].item)
    end
    return results
end

-- ============================================================================
-- Result Building
-- ============================================================================

local function _build_preview(rec)
    local char = rec.char
    local lines = {
        char,
        "",
        rec.name_zh,
        rec.name_en,
        "",
        rec.group_zh .. " / " .. rec.subgroup_zh,
    }
    return table.concat(lines, "\n")
end

local function _emoji_item(rec)
    local char = rec.char
    local subtitle = rec.name_zh .. " | " .. rec.name_en .. " · " .. rec.group_zh
    return {
        title = char,
        subtitle = subtitle,
        icon = char,
        action = function()
            lingxi.paste(char)
        end,
        cmd_action = function()
            lingxi.clipboard.write(char)
            lingxi.alert.show("已复制", 1.2)
        end,
        cmd_subtitle = "Copy to clipboard",
        preview_type = "text",
        preview = _build_preview(rec),
    }
end

local _EMOJIS_PER_ROW = 12
local _EMOJI_SPACING = "  "

local function _group_preview(g)
    local lines = {}
    local chars = g.chars or {}
    local row = {}
    for i = 1, #chars do
        table.insert(row, chars[i])
        if #row >= _EMOJIS_PER_ROW then
            table.insert(lines, table.concat(row, _EMOJI_SPACING))
            row = {}
        end
    end
    if #row > 0 then
        table.insert(lines, table.concat(row, _EMOJI_SPACING))
    end
    return table.concat(lines, "\n")
end

local function _group_item(g)
    local title = g.name_zh ~= "" and g.name_zh or g.name_en
    local subtitle = g.name_en or ""
    local first_char = g.char or ""
    return {
        title = title,
        subtitle = subtitle,
        icon = first_char,
        action = function()
            if first_char ~= "" then
                lingxi.paste(first_char)
            end
        end,
        cmd_action = function()
            if first_char ~= "" then
                lingxi.clipboard.write(first_char)
                lingxi.alert.show("已复制", 1.2)
            end
        end,
        cmd_subtitle = "Copy to clipboard",
        preview_type = "text",
        preview = _group_preview(g),
    }
end

-- ============================================================================
-- Public API
-- ============================================================================

function search(query)
    _load_emoji_data()

    query = query or ""
    query = query:gsub("^%s*e%s*", ""):gsub("^%s*", "")

    if query == "@" then
        local items = {}
        for _, g in ipairs(_groups) do
            if g.char and g.char ~= "" then
                table.insert(items, _group_item(g))
            end
        end
        return items
    end

    local results = _search_emojis(query)
    local items = {}
    for _, rec in ipairs(results) do
        table.insert(items, _emoji_item(rec))
    end
    return items
end
