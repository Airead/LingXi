-- cache.lua - Incremental persistent cache for session scanning
-- Uses file system cache in plugin-specific cache directory with atomic writes.

local M = {}

-- ============================================================================
-- Constants
-- ============================================================================

local CACHE_FILE_NAME = "sessions.json"
local CACHE_VERSION = 2

-- ============================================================================
-- Memory Cache with TTL
-- ============================================================================

local _sessions = nil
local _scanning = false
local _scan_all_cached_at = 0
local _SCAN_ALL_TTL = 30.0 -- 30 seconds

function M.get_memory_cache()
    local now = os.time()
    if _sessions and (now - _scan_all_cached_at < _SCAN_ALL_TTL) then
        return _sessions
    end
    return nil
end

function M.set_memory_cache(sessions)
    _sessions = sessions
    _scan_all_cached_at = os.time()
end

function M.invalidate_memory_cache()
    _sessions = nil
    _scan_all_cached_at = 0
end

-- ============================================================================
-- Index Supplements Cache (for sessions-index.json)
-- ============================================================================

local _index_supplements = {}

function M.get_index_cache(index_path)
    local cached = _index_supplements[index_path]
    if cached then
        local mtime = M.get_mtime(index_path)
        if mtime and cached.mtime == mtime then
            return cached.data
        end
    end
    return nil
end

function M.set_index_cache(index_path, mtime, data)
    _index_supplements[index_path] = {
        mtime = mtime,
        data = data
    }
end

function M.clear_index_cache()
    _index_supplements = {}
end

-- ============================================================================
-- Disk Cache with Dirty Flag and Atomic Write
-- ============================================================================

local _disk_cache = {}
local _disk_cache_loaded = false
local _dirty = false

local function _cache_file_path()
    local cache_dir = lingxi.cache.getPath()
    if not cache_dir then
        return nil
    end
    return cache_dir .. "/" .. CACHE_FILE_NAME
end

local function _ensure_cache_loaded()
    if _disk_cache_loaded then
        return
    end
    
    local path = _cache_file_path()
    if not path then
        _disk_cache = {}
        _disk_cache_loaded = true
        return
    end
    
    local content = lingxi.file.read(path)
    if not content then
        _disk_cache = {}
        _disk_cache_loaded = true
        return
    end
    
    local ok, data = pcall(function()
        return lingxi.json.parse(content)
    end)
    
    if ok and type(data) == "table" and data.version == CACHE_VERSION then
        _disk_cache = data.sessions or {}
    else
        _disk_cache = {}
    end
    _disk_cache_loaded = true
end

function M.load_disk_cache()
    _ensure_cache_loaded()
    return _disk_cache
end

function M.save_disk_cache(sessions_map)
    local path = _cache_file_path()
    if not path then
        return
    end
    
    if not _dirty then
        return
    end
    
    local data = {
        version = CACHE_VERSION,
        sessions = sessions_map or {}
    }
    
    local ok, encoded = pcall(function()
        return lingxi.json.encode(data)
    end)
    
    if ok and encoded then
        -- Atomic write: write to tmp file then rename
        local tmp_path = path .. ".tmp"
        local write_ok = lingxi.file.write(tmp_path, encoded)
        if write_ok then
            lingxi.file.move(tmp_path, path)
            _dirty = false
        end
    end
end

function M.mark_dirty()
    _dirty = true
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
    _dirty = true
end

function M.prune(cache_map, live_paths_set)
    local pruned = false
    for path, _ in pairs(cache_map) do
        if not live_paths_set[path] then
            cache_map[path] = nil
            pruned = true
        end
    end
    if pruned then
        _dirty = true
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
    _scan_all_cached_at = 0
    _scanning = false
    _disk_cache = {}
    _disk_cache_loaded = false
    _dirty = false
    _index_supplements = {}
    
    local path = _cache_file_path()
    if path then
        lingxi.file.write(path, lingxi.json.encode({ version = CACHE_VERSION, sessions = {} }))
    end
end

return M
