import CLua
import Foundation

/// Fuzzy matching API exposed to Lua plugins via `lingxi.fuzzy.*`.
nonisolated enum LuaFuzzyAPI {
    
    /// Register the `lingxi.fuzzy` module with the given Lua state.
    static func register(state: LuaState) {
        state.createTable(nrec: 1)
        state.pushFunction(fuzzySearch)
        state.setField("search", at: -2)
        state.setField("fuzzy", at: -2)
    }
    
    /// `lingxi.fuzzy.search(query, items, fields) -> {{item = ..., score = number}, ...}`
    ///
    /// - Parameters:
    ///   - query: Search query string
    ///   - items: Array of items to search (each item is a table with string fields)
    ///   - fields: Array of field names to match against
    /// - Returns: Array of results, each containing `item` (original item) and `score` (number)
    private static let fuzzySearch: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        
        // Parse arguments
        guard let query = lua_swift_tostring(L, 1).map({ String(cString: $0) }) else {
            lua_pushnil(L)
            return 1
        }
        
        guard lua_swift_istable(L, 2) != 0 else {
            lua_createtable(L, 0, 0)
            return 1
        }
        
        guard lua_swift_istable(L, 3) != 0 else {
            lua_createtable(L, 0, 0)
            return 1
        }
        
        // Extract fields array from Lua
        var fields: [String] = []
        let fieldsLen = lua_rawlen(L, 3)
        if fieldsLen > 0 {
            for i in 1...fieldsLen {
                lua_rawgeti(L, 3, lua_Integer(i))
                if let fieldCStr = lua_swift_tostring(L, -1) {
                    fields.append(String(cString: fieldCStr))
                }
                lua_swift_pop(L, 1)
            }
        }
        
        guard !fields.isEmpty else {
            lua_createtable(L, 0, 0)
            return 1
        }
        
        // Process items and collect results
        struct MatchResult {
            let itemIndex: Int
            let score: Double
        }
        var results: [MatchResult] = []
        
        let itemsLen = lua_rawlen(L, 2)
        guard itemsLen > 0 else {
            lua_createtable(L, 0, 0)
            return 1
        }
        
        for i in 1...itemsLen {
            lua_rawgeti(L, 2, lua_Integer(i))
            
            guard lua_swift_istable(L, -1) != 0 else {
                lua_swift_pop(L, 1)
                continue
            }
            
            // Collect field values for this item
            var fieldValues: [String] = []
            for field in fields {
                lua_getfield(L, -1, field)
                if let valueCStr = lua_swift_tostring(L, -1) {
                    fieldValues.append(String(cString: valueCStr))
                } else {
                    fieldValues.append("")
                }
                lua_swift_pop(L, 1)
            }
            
            // Perform fuzzy match
            if let score = FuzzyMatch.matchFields(query: query, fields: fieldValues) {
                results.append(MatchResult(itemIndex: Int(i), score: score))
            }
            
            lua_swift_pop(L, 1)
        }
        
        // Sort by score descending
        results.sort { $0.score > $1.score }
        
        // Build result table
        lua_createtable(L, Int32(results.count), 0)
        for (idx, match) in results.enumerated() {
            lua_createtable(L, 0, 2)
            
            // Add item reference
            lua_rawgeti(L, 2, lua_Integer(match.itemIndex))
            lua_setfield(L, -2, "item")
            
            // Add score
            lua_pushnumber(L, match.score)
            lua_setfield(L, -2, "score")
            
            lua_rawseti(L, -2, lua_Integer(idx + 1))
        }
        
        return 1
    }
}
