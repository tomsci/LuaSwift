// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

#define LUASWIFT_MINIMAL_CLUA
#include "CLua.h"

int luaswift_searcher_preload(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
#if LUA_VERSION_NUM >= 504
    if (lua_getfield(L, -1, name) == LUA_TNIL) {  /* not found? */
        lua_pushfstring(L, "no field package.preload['%s']", name);
        return 1;
    } else {
        lua_pushliteral(L, ":preload:");
        return 2;
    }
#else
    if (lua_getfield(L, -1, name) == LUA_TNIL) {
        lua_pushfstring(L, "\n\tno field package.preload['%s']", name);
    }
    return 1;
#endif
}

int luaswift_callclosurewrapper(lua_State *L) {
    // The function pointer for LuaClosureWrapper.callClosure is in the registry keyed by the
    // luaswift_callclosurewrapper function pointer.
    lua_pushcfunction(L, luaswift_callclosurewrapper);
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_CFunction LuaClosureWrapper_callClosure = lua_tocfunction(L, -1);
    lua_pop(L, 1);

    int ret = LuaClosureWrapper_callClosure(L);
    if (ret == LUASWIFT_CALLCLOSURE_ERROR) {
        return lua_error(L);
    } else {
        return ret;
    }
}

_Bool luaswift_iscallclosurewrapper(lua_CFunction fn) {
    return fn == luaswift_callclosurewrapper;
}

int luaswift_gettable(lua_State *L) {
    lua_gettable(L, 1);
    return 1;
}

int luaswift_settable(lua_State *L) {
    lua_settable(L, 1);
    return 0;
}

int luaswift_tostring(lua_State *L) {
    luaL_tolstring(L, 1, NULL);
    return 1;
}

int luaswift_requiref(lua_State *L) {
    const char *name = lua_tostring(L, 1);
    lua_CFunction fn = lua_tocfunction(L, 2);
    int global = lua_toboolean(L, 3);
    luaL_requiref(L, name, fn, global);
    return 0;
}

int luaswift_compare(lua_State *L) {
    int result = lua_compare(L, 1, 2, (int)lua_tointeger(L, 3));
    lua_pushinteger(L, result);
    return 1;
}

// Create userdata with as few user values as possible on this version of Lua
void* luaswift_newuserdata(lua_State* L, size_t sz) {
#if LUA_VERSION_NUM >= 504
    return lua_newuserdatauv(L, sz, 0);
#else
    return lua_newuserdata(L, sz);
#endif
}

size_t luaswift_lua_Debug_srclen(const lua_Debug* d) {
#if LUA_VERSION_NUM >= 504
    return d->srclen;
#else
    return strlen(d->source);
#endif
}

void luaswift_lua_Debug_gettransfers(const lua_Debug* d, unsigned short *ftransfer, unsigned short *ntransfer) {
#if LUA_VERSION_NUM >= 504
    *ftransfer = d->ftransfer;
    *ntransfer = d->ntransfer;
#else
    *ftransfer = 0;
    *ntransfer = 0;
#endif
}

int luaswift_setgen(lua_State* L, int minormul, int majormul) {
#if LUA_VERSION_NUM >= 504
    return lua_gc(L, LUA_GCGEN, minormul, majormul);
#else
    return 0; // Anything other than LUASWIFT_GCGEN, LUASWIFT_GCINC works
#endif
}

int luaswift_setinc(lua_State* L, int pause, int stepmul, int stepsize) {
#if LUA_VERSION_NUM >= 504
    return lua_gc(L, LUA_GCINC, pause, stepmul, stepsize);
#else
    if (pause) {
        lua_gc(L, LUA_GCSETPAUSE, pause);
    }
    if (stepmul) {
        lua_gc(L, LUA_GCSETSTEPMUL, stepmul);
    }
    // 5.3 doesn't have a way to set stepsize, hm.
    (void)stepsize;

    return LUASWIFT_GCINC; // Since incremental is the only option
#endif
}
