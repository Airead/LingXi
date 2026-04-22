# API Showcase Plugin

A comprehensive demonstration plugin for LingXi that showcases every available plugin API and capability. This plugin serves as a **reference implementation** for developers building LingXi plugins.

## Features

This plugin demonstrates the following APIs:

- **HTTP** — `lingxi.http.get()`, `lingxi.http.post()`
- **Clipboard** — `lingxi.clipboard.read()`, `lingxi.clipboard.write()`
- **Filesystem** — `lingxi.file.read()`, `lingxi.file.write()`, `lingxi.file.list()`, `lingxi.file.exists()`
- **Shell** — `lingxi.shell.exec()`
- **Store** — `lingxi.store.get()`, `lingxi.store.set()`, `lingxi.store.delete()`
- **Notify** — `lingxi.notify.send()`
- **Alert** — `lingxi.alert.show()`
- **Events** — `on_clipboard_change()`, `on_search_activate()`, `on_screenshot_captured()`, `on_event()`

## Usage

Activate the plugin with the search prefix: `api`

### Available Subcommands

Type these in the LingXi search bar after `api `:

| Command | Description |
|---------|-------------|
| `api help` | List all available demonstrations |
| `api http` | HTTP request demonstration |
| `api clip` | Clipboard read/write demonstration |
| `api file` | Filesystem operations demonstration |
| `api shell` | Shell command execution demonstration |
| `api store` | Persistent storage demonstration |
| `api notify` | System notification demonstration |
| `api alert` | Toast alert demonstration |
| `api event` | Event system information |
| `api stats` | Runtime statistics |

### Built-in Commands

These commands are registered directly in the command palette:

| Command | Description |
|---------|-------------|
| `api:stats` | Display detailed runtime statistics (copied to clipboard) |
| `api:clear` | Clear all stored plugin data |
| `api:notify` | Send a test notification |

## Plugin Manifest

The `plugin.toml` file declares all required permissions:

```toml
[permissions]
network = true          # Required for HTTP API
clipboard = true        # Required for clipboard API
filesystem = ["/tmp/lingxi-api-showcase"]  # Sandbox: only this directory
shell = ["date", "sw_vers"]   # Whitelist: only these commands
notify = true           # Required for notification API
```

## File Structure

```
api-showcase/
├── plugin.toml     # Plugin manifest with metadata and permissions
├── init.lua        # Main plugin code
└── README.md       # This documentation
```

## API Reference

### HTTP API

```lua
-- GET request
local response = lingxi.http.get("https://api.example.com/data")
-- response.status: HTTP status code (number)
-- response.body: Response body (string)
-- response.headers: Response headers (table)

-- POST request
local response = lingxi.http.post("https://api.example.com/data", "{\"key\":\"value\"}", "application/json")
```

### Clipboard API

```lua
-- Read clipboard
local text = lingxi.clipboard.read()  -- string | nil

-- Write to clipboard
local ok = lingxi.clipboard.write("Hello, World!")  -- boolean
```

### Filesystem API

```lua
-- All paths are relative to the plugin's sandbox directory

-- Read file
local content = lingxi.file.read("/tmp/lingxi-api-showcase/config.txt")  -- string | nil

-- Write file
local ok = lingxi.file.write("/tmp/lingxi-api-showcase/config.txt", "content")

-- List directory
local entries = lingxi.file.list("/tmp/lingxi-api-showcase")  -- {name, isDir}[] | nil

-- Check if file exists
local exists = lingxi.file.exists("/tmp/lingxi-api-showcase/config.txt")  -- boolean
```

### Shell API

```lua
-- Execute whitelisted command
local result = lingxi.shell.exec("date")
-- result.exitCode: Exit code (number)
-- result.stdout: Standard output (string)
-- result.stderr: Standard error (string)
```

### Store API

```lua
-- Get value
local value = lingxi.store.get("my_key")  -- any | nil

-- Set value (supports strings, numbers, booleans, tables)
local ok = lingxi.store.set("my_key", "value")

-- Delete value
local ok = lingxi.store.delete("my_key")
```

### Notify API

```lua
-- Send system notification
local ok = lingxi.notify.send("Title", "Message body")
```

### Alert API

```lua
-- Show toast message (duration in seconds, optional)
local ok = lingxi.alert.show("Hello!", 3.0)
```

### Event Handlers

```lua
-- Specific event handler (recommended)
function on_clipboard_change(data)
    local text = data.text or ""
    local app = data.source_app or ""
end

function on_search_activate(data)
    local prefix = data.prefix or ""
end

function on_screenshot_captured(data)
    local path = data.path or ""
    local type = data.type or ""
end

-- Generic fallback handler
function on_event(event_name, data)
    -- Handle any event
end
```

## License

MIT License — Part of the LingXi project.
