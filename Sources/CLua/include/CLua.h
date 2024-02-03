// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

#ifndef clua_bridge_h
#define clua_bridge_h

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#ifndef LUASWIFT_MINIMAL_CLUA

// Define this as a concrete type so that lua_State* gets typed on the Swift side
// as UnsafeMutablePointer<lua_State>? instead of OpaquePointer? so that we can have
// better type-safety. This is technically wrong but makes for so much nicer code
// it's worth it.
struct lua_State {};

// Reimplement some things that are macros, so the bridge can see them

#undef lua_isnoneornil
static inline int lua_isnoneornil(lua_State* L, int n) {
    return lua_type(L, n) <= 0;
}

#undef lua_isnil
static inline int lua_isnil(lua_State* L, int n) {
    return lua_type(L, n) == LUA_TNIL;
}

#undef lua_isboolean
static inline int lua_isboolean(lua_State* L, int n) {
    return lua_type(L, n) == LUA_TBOOLEAN;
}

#undef lua_islightuserdata
static inline int lua_islightuserdata(lua_State* L, int n) {
    return lua_type(L, n) == LUA_TLIGHTUSERDATA;
}

#undef lua_istable
static inline int lua_istable(lua_State* L, int n) {
    return lua_type(L, n) == LUA_TTABLE;
}

#undef lua_isfunction
static inline int lua_isfunction(lua_State* L, int n) {
    return lua_type(L, n) == LUA_TFUNCTION;
}

#undef lua_isthread
static inline int lua_isthread(lua_State* L, int n) {
    return lua_type(L, n) == LUA_TTHREAD;
}

#undef lua_pop
static inline void lua_pop(lua_State* L, int n) {
    lua_settop(L, -(n) - 1);
}

#undef lua_call
static inline void lua_call(lua_State* L, int narg, int nret) {
    lua_callk(L, narg, nret, 0, NULL);
}

#undef lua_pcall
static inline int lua_pcall(lua_State* L, int narg, int nret, int errfunc) {
    return lua_pcallk(L, narg, nret, errfunc, 0, NULL);
}

#undef lua_yield
static inline int lua_yield(lua_State* L, int nret) {
    return lua_yieldk(L, nret, 0, NULL);
}

#undef lua_newtable
static inline void lua_newtable(lua_State* L) {
    lua_createtable(L, 0, 0);
}

#undef lua_register
static inline void lua_register(lua_State* L, const char *name, lua_CFunction f) {
    lua_pushcfunction(L, f);
    lua_setglobal(L, name);
}

#undef lua_pushcfunction
static inline void lua_pushcfunction(lua_State* L, lua_CFunction fn) {
    lua_pushcclosure(L, fn, 0);
}

#undef lua_pushliteral
static inline void lua_pushliteral(lua_State* L, const char* s) {
    lua_pushstring(L, s);
}

#undef lua_pushglobaltable
static inline void lua_pushglobaltable(lua_State* L) {
    (void)lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
}

#undef luaL_dofile
static inline int luaL_dofile(lua_State* L, const char *filename) {
    return luaL_loadfile(L, filename) || lua_pcall(L, 0, LUA_MULTRET, 0);
}

#undef lua_tointeger
static inline lua_Integer lua_tointeger(lua_State* L, int index) {
    return lua_tointegerx(L, index, NULL);
}

#undef lua_tonumber
static inline lua_Number lua_tonumber(lua_State* L, int index) {
    return lua_tonumberx(L, index, NULL);
}

#undef lua_tostring
static inline const char* lua_tostring(lua_State* L, int index) {
    return lua_tolstring(L, index, NULL);
}

#ifdef lua_insert
#undef lua_insert
static inline void lua_insert(lua_State* L, int index) {
    lua_rotate(L, index, 1);
}
#endif

#ifdef lua_remove
#undef lua_remove
static inline void lua_remove(lua_State* L, int index) {
    lua_rotate(L, index, -1);
    lua_pop(L, 1);
}
#endif

#ifdef lua_replace
#undef lua_replace
static inline void lua_replace(lua_State* L, int index) {
    lua_copy(L, -1, index);
    lua_pop(L, 1);
}
#endif

#undef luaL_typename
static inline const char* luaL_typename(lua_State* L, int index) {
    return lua_typename(L, lua_type(L, index));
}

#undef lua_upvalueindex
static inline int lua_upvalueindex(int i) {
    return LUA_REGISTRYINDEX - i;
}

#undef LUA_REGISTRYINDEX
static const int LUA_REGISTRYINDEX = -LUAI_MAXSTACK - 1000;

#undef luaL_getmetatable
static inline int luaL_getmetatable(lua_State* L, const char* name) {
    return lua_getfield(L, LUA_REGISTRYINDEX, name);
}

#ifdef lua_getextraspace
#undef lua_getextraspace
static inline void* lua_getextraspace(lua_State* L) {
    return ((void *)((char *)(L) - LUA_EXTRASPACE));
}
#endif

#ifdef lua_newuserdata
#undef lua_newuserdata
static inline void* lua_newuserdata(lua_State* L, size_t sz) {
    return lua_newuserdatauv(L, sz, 1);
}
#endif

static inline int luaswift_gc0(lua_State* L, int what) {
    return lua_gc(L, what, 0);
}

static inline int luaswift_gc1(lua_State* L, int what, int arg1) {
    return lua_gc(L, what, arg1);
}

#endif // LUASWIFT_MINIMAL_CLUA

int luaswift_loadfile(lua_State *L, const char *filename,
                      const char *displayname,
                      const char *mode);

#define LUASWIFT_CALLCLOSURE_ERROR (-2)
#define LUASWIFT_CALLCLOSURE_PCALLK (-3)
#define LUASWIFT_CALLCLOSURE_CALLK (-4)
#define LUASWIFT_CALLCLOSURE_YIELD (-5)

int luaswift_callclosurewrapper(lua_State *L);
_Bool luaswift_iscallclosurewrapper(lua_CFunction fn);
int luaswift_continuation_regkey(lua_State *L);

int luaswift_gettable(lua_State *L);
int luaswift_settable(lua_State *L);
int luaswift_tostring(lua_State *L);
int luaswift_requiref(lua_State *L);
int luaswift_compare(lua_State *L);
void* luaswift_newuserdata(lua_State* L, size_t sz);
int luaswift_searcher_preload(lua_State *L);
int luaswift_do_for_pairs(lua_State *L);
int luaswift_do_for_ipairs(lua_State *L);

int luaswift_resume(lua_State *L, lua_State *from, int nargs, int *nresults);
int luaswift_closethread(lua_State *L, lua_State* from);

size_t luaswift_lua_Debug_srclen(const lua_Debug* d);
void luaswift_lua_Debug_gettransfers(const lua_Debug* d, unsigned short *ftransfer, unsigned short *ntransfer);

#if LUA_VERSION_NUM <= 504
#define LUASWIFT_GCGEN 10
#define LUASWIFT_GCINC 11
#else
#define LUASWIFT_GCGEN LUA_GCGEN
#define LUASWIFT_GCINC LUA_GCINC
#endif

int luaswift_setgen(lua_State* L, int minormul, int majormul);
int luaswift_setinc(lua_State* L, int pause, int stepmul, int stepsize);

#ifdef LUA_VERSION_MAJOR_N
#define LUASWIFT_LUA_VERSION_MAJOR LUA_VERSION_MAJOR_N
#define LUASWIFT_LUA_VERSION_MINOR LUA_VERSION_MINOR_N
#define LUASWIFT_LUA_VERSION_RELEASE LUA_VERSION_RELEASE_N
#else
// Fall back to using the string definitions and let the LuaVersion constructor parse them
#define LUASWIFT_LUA_VERSION_MAJOR LUA_VERSION_MAJOR
#define LUASWIFT_LUA_VERSION_MINOR LUA_VERSION_MINOR
#define LUASWIFT_LUA_VERSION_RELEASE LUA_VERSION_RELEASE
#endif

// Early Lua 5.3 versions didn't define this, even though it is used in the same way.
#ifndef LUA_PRELOAD_TABLE
#define LUA_PRELOAD_TABLE "_PRELOAD"
#endif

// Ditto
#ifndef LUA_LOADED_TABLE
#define LUA_LOADED_TABLE "_LOADED"
#endif

// Only in 5.4
#ifndef LUA_GNAME
#define LUA_GNAME "_G"
#endif

#endif /* clua_bridge_h */
