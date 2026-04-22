# Swift-Lua Bridge: NSNumber Type Dispatch Bug

## Summary
`lingxi.store.get()` returned `boolean` instead of `number` for integer values (e.g. `1`, `0`), causing `demo_stats` to always show `0` in the api-showcase plugin.

## Root Cause
In `LuaAPI.swift:pushSwiftValue()`, the `switch` statement had the `Bool` case before the `NSNumber` case:

```swift
switch value {
case let b as Bool:       // <-- matched first
case let num as NSNumber: // <-- never reached for NSNumber(1)
}
```

Foundation allows `NSNumber` to bridge to `Bool`:
- `NSNumber(value: 1) as? Bool` → `true`
- `NSNumber(value: 0) as? Bool` → `false`

So `NSNumber(1)` (from `JSONSerialization`) matched the `Bool` case and was pushed to Lua as `boolean`, not `number`.

## Fix
Move `NSNumber` case **before** `Bool` in the switch, and use `CFBoolean` singleton identity to distinguish real booleans:

```swift
case let num as NSNumber:
    if num === (kCFBooleanTrue as NSNumber) || num === (kCFBooleanFalse as NSNumber) {
        lua_pushboolean(L, num.boolValue ? 1 : 0)
    } else if num.doubleValue == Double(num.int64Value) {
        lua_pushinteger(L, lua_Integer(num.int64Value))
    } else {
        lua_pushnumber(L, num.doubleValue)
    }
case let b as Bool:
    lua_pushboolean(L, b ? 1 : 0)
```

## Why CFBoolean Singleton Comparison
- `CFBooleanGetTypeID()` alone is unreliable (small integers may accidentally match on some platforms)
- `kCFBooleanTrue`/`kCFBooleanFalse` are singleton objects; `===` identity check is the only reliable way to distinguish `CFBoolean` from `CFNumber`

## Files Changed
- `LingXi/Plugin/LuaAPI.swift` — fixed type dispatch order and boolean detection
- `plugins/api-showcase/plugin.lua` — added legacy boolean cleanup in counter functions
- `LingXiTests/LuaAPITests.swift` — added 4 unit tests for JSON round-trip type preservation

## Lesson
When bridging Foundation types to another runtime, **always place `NSNumber` before `Bool`/`Int`/`Double` in Swift `switch` statements**, because Foundation's toll-free bridging can cause `NSNumber` to match narrower numeric types unexpectedly.

## Test Coverage
- `pushSwiftValueJSONNumberOneIsLuaNumber` — verifies `{"count": 1}` → Lua number
- `pushSwiftValueJSONBooleanTrueIsLuaBoolean` — verifies `{"enabled": true}` → Lua boolean
- `pushSwiftValueCFBooleanFalseIsLuaBoolean` — verifies `{"enabled": false}` → Lua boolean
- `pushSwiftValueNSNumberZeroIsLuaNumber` — verifies `NSNumber(0)` → Lua number (not boolean)
