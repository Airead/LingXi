-- cache.lua - Incremental persistent cache for session scanning
-- Uses file system cache in plugin-specific cache directory.

local M = {}

-- ============================================================================
-- Constants
-- ============================================================================

local CACHE_FILE_NAME = "sessions.json"

-- ============================================================================
-- Memory Cache
-- ============================================================================

local _sessions = nil
local _scanning = false

function M.get_memory_cache()
    return _sessions
end

function M.set_memory_cache(sessions)
    _sessions = sessions
end

-- ============================================================================
-- Disk Cache Helpers
-- ============================================================================

local function _cache_file_path()
    local cache_dir = lingxi.cache.getPath()
    if not cache_dir then
        return nil
    end
    return cache_dir .. "/" .. CACHE_FILE_NAME
end

function M.load_disk_cache()
    local path = _cache_file_path()
    if not path then
        return {}
    end
    
    local content = lingxi.file.read(path)
    if not content then
        return {}
    end
    
    local ok, data = pcall(function()
        return lingxi.json.parse(content)
    end)
    
    if ok and type(data) == "table" and data.version == 1 then
        return data.sessions or {}
    end
    return {}
end

function M.save_disk_cache(sessions_map)
    local path = _cache_file_path()
    if not path then
        return
    end
    
    local data = {
        version = 1,
        sessions = sessions_map or {}
    }
    
    local ok, encoded = pcall(function()
        return lingxi.json.encode(data)
    end)
    
    if ok and encoded then
        lingxi.file.write(path, encoded)
    end
end

-- ============================================================================
-- Cache Entry Operations
-- ============================================================================

function M.get(cache_map, file_path, mtime)
    local entry = cache_map[file_path]
    if entry and entry.mtime == mtime then
        return entry.data
    end
    return nil
end

function M.put(cache_map, file_path, mtime, data)
    cache_map[file_path] = {
        mtime = mtime,
        data = data
    }
end

function M.prune(cache_map, live_paths_set)
    for path, _ in pairs(cache_map) do
        if not live_paths_set[path] then
            cache_map[path] = nil
        end
    end
end

-- ============================================================================
-- File Metadata using lingxi.file.stat()
-- ============================================================================

function M.get_mtime(path)
    local stat = lingxi.file.stat(path)
    if stat and stat.mtime then
        return stat.mtime
    end
    return nil
end

-- ============================================================================
-- Scanning Lock
-- ============================================================================

function M.is_scanning()
    return _scanning
end

function M.set_scanning(flag)
    _scanning = flag
end

-- ============================================================================
-- Cache Management
-- ============================================================================

function M.clear()
    _sessions = nil
    _scanning = false
    local path = _cache_file_path()
    if path then
        -- Write empty cache
        lingxi.file.write(path, lingxi.json.encode({ version = 1, sessions = {} }))
    end
end

return M
