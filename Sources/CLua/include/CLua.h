// Copyright (c) 2023 Tom Sutcliffe
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#ifndef clua_bridge_h
#define clua_bridge_h

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

// Define this as a concrete type so that lua_State* gets typed on the Swift side
// as UnsafeMutablePointer<lua_State>? instead of OpaquePointer? so that we can have
// better type-safety. This is technically wrong but makes for so much nicer code
// it's worth it.
struct lua_State {};

// Reimplement some things that are macros, so the bridge can see them

#undef lua_isnoneornil
static inline _Bool lua_isnoneornil(lua_State* L, int n) {
    return lua_type(L, n) <= 0;
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

#undef lua_tonumber
static inline lua_Number lua_tonumber(lua_State* L, int index) {
    return lua_tonumberx(L, index, NULL);
}

#undef lua_tostring
static inline const char* lua_tostring(lua_State* L, int index) {
    return lua_tolstring(L, index, NULL);
}

#undef lua_insert
static inline void lua_insert(lua_State* L, int index) {
    lua_rotate(L, index, 1);
}

#undef lua_remove
static inline void lua_remove(lua_State* L, int index) {
    lua_rotate(L, index, -1);
    lua_pop(L, 1);
}

#undef lua_replace
static inline void lua_replace(lua_State* L, int index) {
    lua_copy(L, -1, index);
    lua_pop(L, 1);
}

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

#undef lua_getextraspace
static inline void* lua_getextraspace(lua_State* L) {
    return ((void *)((char *)(L) - LUA_EXTRASPACE));
}

int lua_gc0(lua_State* L, int what) {
    return lua_gc(L, what);
}

int lua_gc1(lua_State* L, int what, int arg1) {
    return lua_gc(L, what, arg1);
}

int lua_gc2(lua_State* L, int what, int arg1, int arg2) {
    return lua_gc(L, what, arg1, arg2);
}

int lua_gc3(lua_State* L, int what, int arg1, int arg2, int arg3) {
    return lua_gc(L, what, arg1, arg2, arg3);
}

LUALIB_API int luaL_loadfilexx(lua_State *L, const char *filename,
                                             const char *displayname,
                                             const char *mode);

int luaswift_callclosurewrapper(lua_State *L);
int luaswift_gettable(lua_State *L);
int luaswift_settable(lua_State *L);
int luaswift_tostring(lua_State *L);
int luaswift_requiref(lua_State *L);

#endif /* clua_bridge_h */
