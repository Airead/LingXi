-- Paste & Icon Test Plugin
-- 用于人工验证阶段 1-3 和 5 实现：
--   - lingxi.paste() API
--   - icon 字段支持
--   - modifier actions (cmd_action, alt_action)
--   - preview data (preview_type, preview)
--   - lingxi.fuzzy.search API (阶段 3)
--   - lingxi.json.parse API (阶段 3)
--   - Tab Complete API (阶段 5)

-- 复用的 modifier action 回调函数
local function cmdModifierAction(item)
    lingxi.alert.show("Cmd+Enter: " .. item.title .. " (pasted)", 1.5)
    return true
end

local function altModifierAction(item)
    lingxi.alert.show("Opt+Enter: " .. item.title .. " (pasted)", 1.5)
    return true
end

-- 创建搜索结果项的辅助函数
local function createPasteItem(title, subtitle, icon, pasteText, previewText)
    return {
        title = title,
        subtitle = subtitle,
        icon = icon,
        preview_type = "text",
        preview = previewText,
        action = function()
            lingxi.paste(pasteText)
        end,
        cmd_action = function() cmdModifierAction({title = title}) end,
        cmd_subtitle = "Paste with Cmd modifier hint",
        alt_action = function() altModifierAction({title = title}) end,
        alt_subtitle = "Paste with Opt modifier hint",
    }
end

-- 阶段 3：Fuzzy Search 测试数据
local fuzzyTestData = {
    { name = "cat", category = "animal", icon = "🐱" },
    { name = "dog", category = "animal", icon = "🐶" },
    { name = "apple", category = "fruit", icon = "🍎" },
    { name = "banana", category = "fruit", icon = "🍌" },
    { name = "car", category = "vehicle", icon = "🚗" },
    { name = "bicycle", category = "vehicle", icon = "🚲" },
    { name = "rocket", category = "space", icon = "🚀" },
    { name = "star", category = "space", icon = "⭐" },
}

-- 阶段 5：Tab Complete 测试 - 可用分类
local categories = {
    { name = "animal", display = "🐾 Animal" },
    { name = "fruit", display = "🍎 Fruit" },
    { name = "vehicle", display = "🚗 Vehicle" },
    { name = "space", display = "🚀 Space" },
}

-- 阶段 3：JSON 测试数据
local jsonTestString = '[{"name":"rocket","icon":"🚀","category":"space"},{"name":"star","icon":"⭐","category":"space"},{"name":"moon","icon":"🌙","category":"space"}]'

function search(query)
    query = query or ""
    query = query:gsub("^%s*test%s*", ""):gsub("^%s*", "")
    
    local results = {}
    
    -- 始终显示基础测试项
    table.insert(results, createPasteItem(
        "Paste Emoji Test",
        "Select to paste 😀 into previous app",
        "😀",
        "😀",
        "😀\nEmoji Paste Test\n\nThis emoji will be pasted into the previous application when selected."
    ))
    
    table.insert(results, createPasteItem(
        "Paste Text Test",
        "Select to paste 'Hello from Lua!' into previous app",
        "📝",
        "Hello from Lua!",
        "📝\nText Paste Test\n\nContent: Hello from Lua!\n\nSelect to paste this text into the previous app."
    ))
    
    table.insert(results, createPasteItem(
        "Multi-line Paste Test",
        "Select to paste multi-line text",
        "📄",
        "Line 1\nLine 2\nLine 3\nFrom LingXi!",
        "📄\nMulti-line Paste Test\n\nLine 1\nLine 2\nLine 3\nFrom LingXi!\n\nSelect to paste all lines into the previous app."
    ))
    
    table.insert(results, createPasteItem(
        "Special Characters",
        "Test: Hello 世界 🌍 € £ ¥",
        "🌍",
        "Hello 世界 🌍 € £ ¥",
        "🌍\nSpecial Characters Test\n\nContent: Hello 世界 🌍 € £ ¥\n\nTests Unicode support including CJK, emoji, and currency symbols."
    ))
    
    table.insert(results, {
        title = "Modifier Actions Demo",
        subtitle = "Cmd+Enter, Opt+Enter show hints but still paste",
        icon = "⌨️",
        preview_type = "text",
        preview = "⌨️\nModifier Actions Demo\n\nThis item demonstrates modifier actions:\n\n• Enter        → Paste directly\n• Cmd+Enter  → Paste + show 'Cmd' hint\n• Opt+Enter   → Paste + show 'Opt' hint\n\nHold the modifier key and press Enter to test.",
        action = function()
            lingxi.paste("⌨️ Modifier Actions Demo")
        end,
        cmd_action = function() 
            lingxi.paste("⌨️ Modifier Actions Demo")
            lingxi.alert.show("Cmd+Enter: Pasted with modifier hint", 1.5)
        end,
        cmd_subtitle = "Paste with Cmd modifier hint",
        alt_action = function()
            lingxi.paste("⌨️ Modifier Actions Demo")
            lingxi.alert.show("Opt+Enter: Pasted with modifier hint", 1.5)
        end,
        alt_subtitle = "Paste with Opt modifier hint",
    })
    
    -- 阶段 5：Tab Complete Demo
    table.insert(results, {
        title = "Tab Complete Demo",
        subtitle = "Type '@' then Tab to complete category names",
        icon = "🔤",
        preview_type = "text",
        preview = "🔤 Tab Complete Demo\n\nTry these steps:\n1. Type: test @an\n2. Select '🐾 Animal' from results\n3. Press Tab to auto-complete to: test @animal \n4. Results will filter to animal items only\n\nAvailable categories:\n• @animal  (🐱 cat, 🐶 dog)\n• @fruit   (🍎 apple, 🍌 banana)\n• @vehicle (🚗 car, 🚲 bicycle)\n• @space   (🚀 rocket, ⭐ star)",
        action = function()
            lingxi.alert.show("Type 'test @' then Tab to complete category names!", 3.0)
        end,
    })
    
    -- 阶段 5：Category filter items (visible when using @ syntax)
    if query:match("@(%w+)") then
        local catFilter = query:match("@(%w+)"):lower()
        for _, cat in ipairs(categories) do
            if cat.name:lower():find(catFilter, 1, true) then
                table.insert(results, {
                    title = cat.display,
                    subtitle = "Press Tab to auto-complete this category",
                    icon = "🏷️",
                    preview_type = "text",
                    preview = "Category: " .. cat.name .. "\n\nPress Tab to auto-complete to:\ntest @" .. cat.name .. " ",
                    action = function()
                        lingxi.alert.show("Press Tab to complete: @" .. cat.name, 2.0)
                    end,
                })
            end
        end
    end
    
    -- 阶段 3：JSON Parse Demo
    table.insert(results, {
        title = "JSON Parse Demo",
        subtitle = "Click to parse JSON and show results",
        icon = "📋",
        preview_type = "text",
        preview = "📋 JSON Parse Demo\n\nWill parse this JSON string:\n" .. jsonTestString .. "\n\nExpected: 3 space items (🚀 rocket, ⭐ star, 🌙 moon)",
        action = function()
            local parsed = lingxi.json.parse(jsonTestString)
            if parsed then
                local msg = "✅ Parsed " .. #parsed .. " items:\n"
                for i, item in ipairs(parsed) do
                    msg = msg .. item.icon .. " " .. item.name .. " (" .. item.category .. ")\n"
                end
                lingxi.alert.show(msg, 4.0)
            else
                lingxi.alert.show("❌ JSON parse failed!", 2.0)
            end
        end,
        cmd_action = function()
            local parsed = lingxi.json.parse('{"invalid json')
            if not parsed then
                lingxi.alert.show("✅ Correctly returned nil for invalid JSON", 2.0)
            else
                lingxi.alert.show("❌ Should have returned nil", 2.0)
            end
        end,
        cmd_subtitle = "Test invalid JSON handling",
    })
    
    -- 阶段 3：Fuzzy Search Demo
    -- 如果用户输入了查询，使用 fuzzy search 过滤测试数据
    if query ~= "" then
        local fuzzyResults = lingxi.fuzzy.search(query, fuzzyTestData, {"name", "category"})
        
        if #fuzzyResults > 0 then
            -- 添加一个标题项显示 fuzzy search 结果数
            table.insert(results, {
                title = "🔍 Fuzzy Results (" .. #fuzzyResults .. ")",
                subtitle = "Query: \"" .. query .. "\"",
                icon = "🔍",
                preview_type = "text",
                preview = "🔍 Fuzzy Search Results\n\nQuery: \"" .. query .. "\"\nMatches: " .. #fuzzyResults .. " items\n\nSorted by relevance score.",
                action = function()
                    lingxi.alert.show("Found " .. #fuzzyResults .. " matches for \"" .. query .. "\"", 2.0)
                end,
            })
            
            -- 添加每个匹配项
            for _, match in ipairs(fuzzyResults) do
                local item = match.item
                table.insert(results, {
                    title = item.icon .. " " .. item.name,
                    subtitle = "Score: " .. math.floor(match.score) .. " | Category: " .. item.category,
                    icon = item.icon,
                    preview_type = "text",
                    preview = "Fuzzy Match Result\n\nName: " .. item.name .. 
                          "\nCategory: " .. item.category ..
                          "\nScore: " .. match.score ..
                          "\n\nSelect to paste.",
                    action = function()
                        lingxi.paste(item.icon .. " " .. item.name)
                    end,
                    cmd_action = function()
                        lingxi.clipboard.write(item.icon .. " " .. item.name)
                        lingxi.alert.show("Copied: " .. item.icon .. " " .. item.name, 1.5)
                    end,
                    cmd_subtitle = "Copy to clipboard",
                })
            end
        else
            table.insert(results, {
                title = "🔍 No Fuzzy Matches",
                subtitle = "Query: \"" .. query .. "\"",
                icon = "❌",
                preview_type = "text",
                preview = "No matches found for \"" .. query .. "\"\n\nTry searching for:\n• animal names: cat, dog\n• fruits: apple, banana\n• vehicles: car, bicycle\n• space: rocket, star",
                action = function()
                    lingxi.alert.show("No matches for \"" .. query .. "\"", 1.5)
                end,
            })
        end
        
        -- 同时保留自定义粘贴选项
        table.insert(results, createPasteItem(
            "Paste: " .. query,
            "Paste your input directly",
            "✏️",
            query,
            "✏️\nCustom Paste\n\nContent: " .. query .. "\n\nSelect to paste your input into the previous app."
        ))
        
        table.insert(results, {
            title = "Copy: " .. query,
            subtitle = "Copy to clipboard without pasting",
            icon = "📎",
            preview_type = "text",
            preview = "📎\nCustom Copy\n\nContent: " .. query .. "\n\nSelect to copy your input to the clipboard.",
            action = function()
                lingxi.clipboard.write(query)
                lingxi.alert.show("Copied: " .. query, 1.5)
            end,
            cmd_action = function() cmdModifierAction({title = "Copy: " .. query}) end,
            cmd_subtitle = "Copy with Cmd modifier hint",
            alt_action = function() altModifierAction({title = "Copy: " .. query}) end,
            alt_subtitle = "Copy with Opt modifier hint",
        })
    end
    
    return results
end

-- 阶段 5：Tab Complete 测试
-- 当用户在查询中输入 "@" 后按 Tab 键，自动补全分类名
function complete(query, item_title)
    -- 检查是否正在输入 @ 分类名（支持 @ 后跟单词字符，以及尾部空格）
    if query:match("@%w[%w]*%s*$") then
        -- 尝试从 item_title 中提取分类名
        for _, cat in ipairs(categories) do
            local itemLower = item_title:lower()
            local catLower = cat.name:lower()
            if itemLower:find(catLower, 1, true) then
                -- 替换 @ 及其后的内容为完整的分类名
                local newQuery = query:gsub("@%w[%w]*%s*$", "@" .. cat.name .. " ")
                return newQuery
            end
        end
    end
    return nil
end
