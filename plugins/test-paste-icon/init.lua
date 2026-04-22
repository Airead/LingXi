-- Paste & Icon Test Plugin
-- 用于人工验证阶段 1-2 实现：
--   - lingxi.paste() API
--   - icon 字段支持
--   - modifier actions (cmd_action, alt_action)
--   - preview data (preview_type, preview)

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

function search(query)
    query = query or ""
    query = query:gsub("^%s*test%s*", ""):gsub("^%s*", "")
    
    if query == "" then
        return {
            createPasteItem(
                "Paste Emoji Test",
                "Select to paste 😀 into previous app",
                "😀",
                "😀",
                "😀\nEmoji Paste Test\n\nThis emoji will be pasted into the previous application when selected."
            ),
            createPasteItem(
                "Paste Text Test",
                "Select to paste 'Hello from Lua!' into previous app",
                "📝",
                "Hello from Lua!",
                "📝\nText Paste Test\n\nContent: Hello from Lua!\n\nSelect to paste this text into the previous app."
            ),
            createPasteItem(
                "Multi-line Paste Test",
                "Select to paste multi-line text",
                "📄",
                "Line 1\nLine 2\nLine 3\nFrom LingXi!",
                "📄\nMulti-line Paste Test\n\nLine 1\nLine 2\nLine 3\nFrom LingXi!\n\nSelect to paste all lines into the previous app."
            ),
            createPasteItem(
                "Special Characters",
                "Test: Hello 世界 🌍 € £ ¥",
                "🌍",
                "Hello 世界 🌍 € £ ¥",
                "🌍\nSpecial Characters Test\n\nContent: Hello 世界 🌍 € £ ¥\n\nTests Unicode support including CJK, emoji, and currency symbols."
            ),
            {
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
            },
        }
    end
    
    -- 如果用户输入了内容，显示自定义粘贴选项
    return {
        createPasteItem(
            "Paste: " .. query,
            "Paste your input directly",
            "✏️",
            query,
            "✏️\nCustom Paste\n\nContent: " .. query .. "\n\nSelect to paste your input into the previous app."
        ),
        {
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
        },
    }
end
