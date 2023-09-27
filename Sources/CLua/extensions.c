// Heavily based on Lua's lauxlib.c, otherwise Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information and README.md for Lua copyright and license.

#include <lua.h>
#include <lauxlib.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Unavoidably this ends up duplicating a chunk of lauxlib.c just to add a small extra ability to luaL_loadfilex.

typedef struct LoadF {
  int n;  /* number of pre-read characters */
  FILE *f;  /* file being read */
  char buff[BUFSIZ];  /* area for reading file */
} LoadF;

static const char *getF (lua_State *L, void *ud, size_t *size) {
  LoadF *lf = (LoadF *)ud;
  (void)L;  /* not used */
  if (lf->n > 0) {  /* are there pre-read characters to be read? */
    *size = lf->n;  /* return them (chars already in buffer) */
    lf->n = 0;  /* no more pre-read characters */
  }
  else {  /* read a block from file */
    /* 'fread' can return > 0 *and* set the EOF flag. If next call to
       'getF' called 'fread', it might still wait for user input.
       The next check avoids this problem. */
    if (feof(lf->f)) return NULL;
    *size = fread(lf->buff, 1, sizeof(lf->buff), lf->f);  /* read block */
  }
  return lf->buff;
}

static int errfile (lua_State *L, const char *what, int fnameindex) {
  const char *serr = strerror(errno);
  const char *filename = lua_tostring(L, fnameindex) + 1;
  lua_pushfstring(L, "cannot %s %s: %s", what, filename, serr);
  lua_remove(L, fnameindex);
  return LUA_ERRFILE;
}

static int skipBOM (FILE *f) {
  int c = getc(f);  /* read first character */
  if (c == 0xEF && getc(f) == 0xBB && getc(f) == 0xBF)  /* correct BOM? */
    return getc(f);  /* ignore BOM and return next char */
  else  /* no (valid) BOM */
    return c;  /* return first character */
}

static int skipcomment (FILE *f, int *cp) {
  int c = *cp = skipBOM(f);
  if (c == '#') {  /* first line is a comment (Unix exec. file)? */
    do {  /* skip first line */
      c = getc(f);
    } while (c != EOF && c != '\n');
    *cp = getc(f);  /* next character after comment, if present */
    return 1;  /* there was a comment */
  }
  else return 0;  /* no comment */
}

// Adds displayname argument
int luaswift_loadfile(lua_State *L, const char *filename,
                      const char *displayname,
                      const char *mode) {
  LoadF lf;
  int status, readstatus;
  int c;
  int fnameindex = lua_gettop(L) + 1;  /* index of filename on the stack */
  if (filename == NULL) {
    lua_pushliteral(L, "=stdin");
    lf.f = stdin;
  }
  else {
    lua_pushfstring(L, "@%s", displayname);
    lf.f = fopen(filename, "r");
    if (lf.f == NULL) return errfile(L, "open", fnameindex);
  }
  lf.n = 0;
  if (skipcomment(lf.f, &c))  /* read initial portion */
    lf.buff[lf.n++] = '\n';  /* add newline to correct line numbers */
  if (c == LUA_SIGNATURE[0]) {  /* binary file? */
    lf.n = 0;  /* remove possible newline */
    if (filename) {  /* "real" file? */
      lf.f = freopen(filename, "rb", lf.f);  /* reopen in binary mode */
      if (lf.f == NULL) return errfile(L, "reopen", fnameindex);
      skipcomment(lf.f, &c);  /* re-read initial portion */
    }
  }
  if (c != EOF)
    lf.buff[lf.n++] = c;  /* 'c' is the first character of the stream */
  status = lua_load(L, getF, &lf, lua_tostring(L, -1), mode);
  readstatus = ferror(lf.f);
  if (filename) fclose(lf.f);  /* close file (even in case of errors) */
  if (readstatus) {
    lua_settop(L, fnameindex);  /* ignore results from 'lua_load' */
    return errfile(L, "read", fnameindex);
  }
  lua_remove(L, fnameindex);
  return status;
}

// The next few functions exist because it is not safe to call lua_error() from a Swift function

int luaswift_callclosurewrapper(lua_State *L) {
    lua_CFunction f = lua_tocfunction(L, lua_upvalueindex(1));
    int ret = f(L);
    if (ret == -2) {
        return lua_error(L);
    } else {
        return ret;
    }
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
    size_t len = 0;
    const char *ptr = luaL_tolstring(L, 1, &len);
    lua_pushlstring(L, ptr, len);
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
