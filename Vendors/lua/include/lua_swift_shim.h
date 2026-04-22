#ifndef lua_swift_shim_h
#define lua_swift_shim_h

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

// Macros that Swift cannot import directly — expose as inline functions.

static inline int lua_swift_pcall(lua_State *L, int nargs, int nresults, int errfunc) {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, NULL);
}

static inline void lua_swift_openlibs(lua_State *L) {
    luaL_openselectedlibs(L, ~(unsigned)0, 0);
}

static inline void lua_swift_pop(lua_State *L, int n) {
    lua_settop(L, -(n) - 1);
}

static inline int lua_swift_isfunction(lua_State *L, int n) {
    return lua_type(L, n) == LUA_TFUNCTION;
}

static inline int lua_swift_istable(lua_State *L, int n) {
    return lua_type(L, n) == LUA_TTABLE;
}

static inline int lua_swift_isnil(lua_State *L, int n) {
    return lua_type(L, n) == LUA_TNIL;
}

static inline int lua_swift_isnoneornil(lua_State *L, int n) {
    return lua_type(L, n) <= 0;
}

static inline const char *lua_swift_tostring(lua_State *L, int i) {
    return lua_tolstring(L, i, NULL);
}

static inline lua_Number lua_swift_tonumber(lua_State *L, int i) {
    return lua_tonumberx(L, i, NULL);
}

static inline lua_Integer lua_swift_tointeger(lua_State *L, int i) {
    return lua_tointegerx(L, i, NULL);
}

static inline void lua_swift_pushcfunction(lua_State *L, lua_CFunction f) {
    lua_pushcclosure(L, f, 0);
}

static inline int luaL_swift_dofile(lua_State *L, const char *fn) {
    return luaL_loadfile(L, fn) || lua_pcallk(L, 0, LUA_MULTRET, 0, 0, NULL);
}

static inline int luaL_swift_dostring(lua_State *L, const char *s) {
    return luaL_loadstring(L, s) || lua_pcallk(L, 0, LUA_MULTRET, 0, 0, NULL);
}

static inline void lua_swift_pushglobaltable(lua_State *L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
}

static inline void lua_swift_newtable(lua_State *L) {
    lua_createtable(L, 0, 0);
}

// Type constants as inline functions (macros not visible to Swift)
static inline int lua_swift_type_nil(void)           { return LUA_TNIL; }
static inline int lua_swift_type_boolean(void)       { return LUA_TBOOLEAN; }
static inline int lua_swift_type_number(void)        { return LUA_TNUMBER; }
static inline int lua_swift_type_string(void)        { return LUA_TSTRING; }
static inline int lua_swift_type_table(void)         { return LUA_TTABLE; }
static inline int lua_swift_type_function(void)      { return LUA_TFUNCTION; }

// Registry index constant (macro not visible to Swift)
static inline int lua_swift_registry_index(void)     { return LUA_REGISTRYINDEX; }

#endif /* lua_swift_shim_h */
