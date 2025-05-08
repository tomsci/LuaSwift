// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

#define LUASWIFT_MINIMAL_CLUA
#include "CLua.h"

#if LUA_VERSION_NUM < 504
#include <string.h> // for strlen
#endif

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

static int continuation(lua_State *L, int status, lua_KContext ctx);

static int handleClosureResult(lua_State *L, int ret) {
    if (ret == LUASWIFT_CALLCLOSURE_ERROR) {
        return lua_error(L);
    } else if (ret == LUASWIFT_CALLCLOSURE_CALLK) {
        int nargs = (int)lua_tointeger(L, -2);
        int nret = (int)lua_tointeger(L, -1);
        lua_pop(L, 2);

        lua_KContext ctx = (lua_KContext)(lua_gettop(L) - nargs - 1);
        lua_callk(L, nargs, nret, ctx, continuation);
        return continuation(L, LUA_OK, ctx);
    } else if (ret == LUASWIFT_CALLCLOSURE_PCALLK) {
        int nargs = (int)lua_tointeger(L, -2);
        int nret = (int)lua_tointeger(L, -1);
        lua_pop(L, 2);
        int continuationIndex = lua_gettop(L) - nargs - 1;
        int msgh = 0;
        if (lua_type(L, continuationIndex - 1) == LUA_TFUNCTION) {
            msgh = continuationIndex - 1;
        }

        lua_KContext ctx = (lua_KContext)continuationIndex;
        return continuation(L, lua_pcallk(L, nargs, nret, msgh, ctx, continuation), ctx);
    } else if (ret == LUASWIFT_CALLCLOSURE_YIELD) {
        int nresults = (int)lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (lua_type(L, -1) == LUA_TUSERDATA) {
            // Reusing the pcall continuation logic means we need to massage stack to correct layout
            lua_pushnil(L);
            lua_insert(L, -2);
            // Stack is now [results...], nilmsgh, cont
            int continuationIndex = lua_gettop(L) - nresults;
            lua_rotate(L, continuationIndex - 1, 2);
            // Stack is now nilmsgh, cont, [results...]
            return lua_yieldk(L, nresults, (lua_KContext)continuationIndex, continuation);
        } else {
            lua_pop(L, 1);
            return lua_yield(L, nresults);
        }
    } else {
        return ret;
    }
}

int luaswift_callclosurewrapper(lua_State *L) {
    // The function pointer for LuaClosureWrapper.callClosure is in the registry keyed by the
    // luaswift_callclosurewrapper function pointer.
    lua_pushcfunction(L, luaswift_callclosurewrapper);
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_CFunction LuaClosureWrapper_callClosure = lua_tocfunction(L, -1);
    lua_pop(L, 1);

    int ret = LuaClosureWrapper_callClosure(L);
    return handleClosureResult(L, ret);
}

int luaswift_continuation_regkey(lua_State *L) {
    // Never actually called, just used as registry key
    return 0;
}

static int continuation(lua_State *L, int status, lua_KContext ctx) {
    lua_pushcfunction(L, luaswift_continuation_regkey);
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_CFunction LuaClosureWrapper_callContinuation = lua_tocfunction(L, -1);
    lua_pop(L, 1);

    int continuationIndex = (int)ctx;
    lua_pushinteger(L, continuationIndex);
    lua_pushinteger(L, status);
    int ret = LuaClosureWrapper_callContinuation(L);
    return handleClosureResult(L, ret);
}

bool luaswift_iscallclosurewrapper(lua_CFunction fn) {
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

int luaswift_arith(lua_State *L) {
    int op = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_arith(L, op);
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

int luaswift_setgen(lua_State* L, int minormul, int majormul, int minorMajorMul, int majorMinorMul) {
#if LUA_VERSION_NUM > 504
    if (majormul) {
        return LUASWIFT_GCUNSUPPORTED;
    }

    int prev = lua_gc(L, LUA_GCGEN);
    if (minormul) {
        lua_gc(L, LUA_GCPARAM, LUA_GCPMINORMUL, minormul);
    }
    if (minorMajorMul) {
        lua_gc(L, LUA_GCPARAM, LUA_GCPMINORMAJOR, minorMajorMul);
    }
    if (majorMinorMul) {
        lua_gc(L, LUA_GCPARAM, LUA_GCPMAJORMINOR, majorMinorMul);
    }
    return prev;
#elif LUA_VERSION_NUM == 504
    if (minorMajorMul || majorMinorMul) {
        return LUASWIFT_GCUNSUPPORTED;
    }
    return lua_gc(L, LUA_GCGEN, minormul, majormul);
#else // LUA_VERSION < 504
    (void)minormul;
    (void)majormul;
    (void)minorMajorMul;
    (void)majorMinorMul;
    return LUASWIFT_GCUNSUPPORTED;
#endif
}

int luaswift_setinc(lua_State* L, int pause, int stepmul, int stepsize) {
#if LUA_VERSION_NUM > 504
    int prev = lua_gc(L, LUA_GCINC);
    if (pause) {
        lua_gc(L, LUA_GCPARAM, LUA_GCPPAUSE, pause);
    }
    if (stepmul) {
        lua_gc(L, LUA_GCPARAM, LUA_GCPSTEPMUL, stepmul);
    }
    if (stepsize) {
        lua_gc(L, LUA_GCPARAM, LUA_GCPSTEPSIZE, stepsize);
    }
    return prev;
#elif LUA_VERSION_NUM == 504
    return lua_gc(L, LUA_GCINC, pause, stepmul, stepsize);
#else // LUA_VERSION < 504
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

// This function exists in C because of the pesky call to lua_call() to call the iterator function, which means this
// loop cannot be written in Swift (because that call could error).
int luaswift_do_for_pairs(lua_State *L) {
    // Preamble, look up callUnmanagedClosure
    lua_pushcfunction(L, luaswift_do_for_pairs);
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_CFunction callUnmanagedClosure = lua_tocfunction(L, -1);
    lua_pop(L, 1);

    // Stack: 1 = iterfn, 2 = state, 3 = block (as lightuserdata), 4 = initval (k)
    while (1) {
        lua_settop(L, 4);
        lua_pushvalue(L, 1); // iterfn
        lua_insert(L, 4); // put iterfn before k
        lua_pushvalue(L, 2); // state
        lua_insert(L, 5); // put state before k (and after iterfn)
        // 4, 5, 6 is now iterfn copy, state copy, k
        lua_call(L, 2, 2); // k, v = iterfn(state, k)
        // Stack is now 1 = iterfn, 2 = state, 3 = block, 4 = k, 5 = v
        if (lua_isnil(L, 4)) {
            break;
        }

        lua_pushvalue(L, 3); // 6 = block
        int ret = callUnmanagedClosure(L);
        // ret is not a conventional result code, only the following 3 values are valid with these specific meanings:
        if (ret == 1) {
            // new k is in position 4 ready to go round loop again
        } else if (ret == 0) {
            break;
        } else if (ret == LUASWIFT_CALLCLOSURE_ERROR) {
            return lua_error(L);
        }
    }
    return 0;
}

int luaswift_do_for_ipairs(lua_State *L) {
    // Preamble, look up callUnmanagedClosure
    lua_pushcfunction(L, luaswift_do_for_pairs);
    lua_rawget(L, LUA_REGISTRYINDEX);
    lua_CFunction callUnmanagedClosure = lua_tocfunction(L, -1);
    lua_pop(L, 1);

    // Stack: 1 = value, 2 = startidx, 3 = block (as lightuserdata)
    for (lua_Integer i = lua_tointeger(L, 2); ; i++) {
        lua_settop(L, 3);
        lua_pushinteger(L, i); // 4
        int t = lua_geti(L, 1, i); // 5, can error
        if (t == LUA_TNIL) {
            break;
        }
        lua_pushvalue(L, 3); // block
        int ret = callUnmanagedClosure(L);
        if (ret == 1) {
            // Keep going
        } else if (ret == 0) {
            break;
        } else if (ret == LUASWIFT_CALLCLOSURE_ERROR) {
            return lua_error(L);
        }            
    }
    return 0;
}

int luaswift_resume(lua_State *L, lua_State *from, int nargs, int *nresults) {
#if LUA_VERSION_NUM >= 504
    return lua_resume(L, from, nargs, nresults);
#else
    int ret = lua_resume(L, from, nargs);
    // Lua 5.3 lua_resume does not preserve anything previously on the stack
    *nresults = lua_gettop(L);
    return ret;
#endif
}

int luaswift_closethread(lua_State *L, lua_State* from) {
#if LUA_VERSION_NUM >= 504
// LUA_VERSION_RELEASE_NUM is defined in all 5.4 and later versions
#if LUA_VERSION_RELEASE_NUM >= 50406
    return lua_closethread(L, from);
#elif LUA_VERSION_RELEASE_NUM == 50405
    return lua_resetthread(L, from);
#else
    return lua_resetthread(L);
#endif
#else
    // Nothing needed prior to 5.4 since there are no to-be-closed variables
    return LUA_OK;
#endif
}
