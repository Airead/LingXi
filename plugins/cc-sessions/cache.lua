-- cache.lua - Incremental persistent cache for session scanning
-- Uses lingxi.store as backend (lingxi.store accepts Lua tables directly).

local M = {}

-- ============================================================================
-- Constants
-- ============================================================================

local DISK_CACHE_KEY = "cc_sessions:scan_cache_v1"

-- ============================================================================
-- Memory Cache
-- ============================================================================

local _sessions = nil

function M.get_memory_cache()
    return _sessions
end

function M.set_memory_cache(sessions)
    _sessions = sessions
end

-- ============================================================================
-- Disk Cache
-- ============================================================================

function M.load_disk_cache()
    local data = lingxi.store.get(DISK_CACHE_KEY)
    if not data then
        return {}
    end
    -- lingxi.store returns the value as-is (Swift converts it back)
    if type(data) == "table" and data.version == 1 then
        return data.sessions or {}
    end
    return {}
end

function M.save_disk_cache(sessions_map)
    local data = {
        version = 1,
        sessions = sessions_map or {}
    }
    lingxi.store.set(DISK_CACHE_KEY, data)
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
-- File Metadata (fallback until lingxi.file.stat() in Phase 4)
-- ============================================================================

function M.get_mtime(path)
    local result = lingxi.shell.exec("stat -f %m " .. path .. " 2>/dev/null")
    if result.exitCode == 0 then
        local mtime = tonumber(result.stdout:match("^%s*(%d+)%s*$"))
        return mtime
    end
    return nil
end

-- ============================================================================
-- Scanning Lock
-- ============================================================================

local _scanning = false

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
    lingxi.store.delete(DISK_CACHE_KEY)
end

return M
