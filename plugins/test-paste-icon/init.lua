-- Paste & Icon Test Plugin
-- 用于人工验证阶段 1 实现：lingxi.paste() API 和 icon 字段支持

function search(query)
    query = query or ""
    query = query:gsub("^%s*test%s*", ""):gsub("^%s*", "")
    
    if query == "" then
        return {
            {
                title = "Paste Emoji Test",
                subtitle = "Select to paste 😀 into previous app",
                icon = "😀",
                action = function()
                    lingxi.paste("😀")
                end
            },
            {
                title = "Paste Text Test",
                subtitle = "Select to paste 'Hello from Lua!' into previous app",
                icon = "📝",
                action = function()
                    lingxi.paste("Hello from Lua!")
                end
            },
            {
                title = "Copy to Clipboard",
                subtitle = "Select to copy '📋 Copied!' to clipboard (not paste)",
                icon = "📋",
                action = function()
                    lingxi.clipboard.write("📋 Copied!")
                    lingxi.alert.show("Copied to clipboard!", 1.5)
                end
            },
            {
                title = "Multi-line Paste Test",
                subtitle = "Select to paste multi-line text",
                icon = "📄",
                action = function()
                    lingxi.paste("Line 1\nLine 2\nLine 3\nFrom LingXi!")
                end
            },
            {
                title = "Special Characters",
                subtitle = "Test: Hello 世界 🌍 € £ ¥",
                icon = "🌍",
                action = function()
                    lingxi.paste("Hello 世界 🌍 € £ ¥")
                end
            },
        }
    end
    
    -- 如果用户输入了内容，显示自定义粘贴选项
    return {
        {
            title = "Paste: " .. query,
            subtitle = "Paste your input directly",
            icon = "✏️",
            action = function()
                lingxi.paste(query)
            end
        },
        {
            title = "Copy: " .. query,
            subtitle = "Copy to clipboard without pasting",
            icon = "📎",
            action = function()
                lingxi.clipboard.write(query)
                lingxi.alert.show("Copied: " .. query, 1.5)
            end
        },
    }
end
