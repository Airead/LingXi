-- identicon.lua - Generate two-letter SVG avatar icons for project names

local M = {}

local COLORS = {
    "#E05252", "#E07B39", "#D4A843", "#5AAE5A", "#43A5A5", "#4A90D9",
    "#6B7FD9", "#8B6FC0", "#C06BAA", "#7C8A6E", "#9E7B5B", "#5B8A9E",
}

-- Simple base64 encoder
local BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
    local result = {}
    local padding = 0
    local i = 1

    while i <= #data do
        local b1 = string.byte(data, i) or 0
        local b2 = string.byte(data, i + 1) or 0
        local b3 = string.byte(data, i + 2) or 0

        local n = b1 * 65536 + b2 * 256 + b3

        table.insert(result, string.sub(BASE64_CHARS, math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
        table.insert(result, string.sub(BASE64_CHARS, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))

        if i + 1 <= #data then
            table.insert(result, string.sub(BASE64_CHARS, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
        else
            table.insert(result, "=")
            padding = padding + 1
        end

        if i + 2 <= #data then
            table.insert(result, string.sub(BASE64_CHARS, n % 64 + 1, n % 64 + 1))
        else
            table.insert(result, "=")
            padding = padding + 1
        end

        i = i + 3
    end

    return table.concat(result)
end

-- djb2 hash
local function djb2(s)
    local h = 5381
    for i = 1, #s do
        h = ((h << 5) + h + string.byte(s, i)) & 0xFFFFFFFF
    end
    return h
end

-- Extract two-letter initials from a project name
local function get_initials(name)
    if not name or name == "" then
        return "?"
    end

    -- Try separator-based splitting
    local parts = {}
    for part in name:gmatch("[^%-_%.%s]+") do
        table.insert(parts, part)
    end
    if #parts >= 2 and parts[1] ~= "" and parts[2] ~= "" then
        return parts[1]:sub(1, 1):upper() .. parts[2]:sub(1, 1):lower()
    end

    -- Try camelCase detection
    local first_lower = name:match("^([a-zA-Z])")
    local first_upper = name:match("[a-z]([A-Z])")
    if first_lower and first_upper then
        return first_lower:upper() .. first_upper:lower()
    end

    -- Fallback: first two letters (strip non-alpha)
    local letters = name:gsub("[^a-zA-Z]", "")
    if #letters >= 2 then
        return letters:sub(1, 1):upper() .. letters:sub(2, 2):lower()
    end
    if #letters >= 1 then
        return letters:sub(1, 1):upper()
    end

    return name:sub(1, 1):upper()
end

-- Generate a data URI for a two-letter avatar SVG
function M.generate(name, size)
    size = size or 32

    local h = djb2(name)
    local color = COLORS[(h % #COLORS) + 1]
    local initials = get_initials(name)

    local rx = size * 0.1875
    local font_size = size * 0.42
    local y_pos = size * 0.62

    local svg = string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d">' ..
        '<rect width="%d" height="%d" rx="%.2f" fill="%s"/>' ..
        '<text x="%.2f" y="%.2f" text-anchor="middle" fill="white" ' ..
        'font-family="-apple-system,BlinkMacSystemFont,sans-serif" ' ..
        'font-weight="600" font-size="%.2f">%s</text>' ..
        '</svg>',
        size, size, size, size,
        size, size, rx, color,
        size / 2, y_pos, font_size, initials
    )

    local b64 = base64_encode(svg)
    return "data:image/svg+xml;base64," .. b64
end

return M
