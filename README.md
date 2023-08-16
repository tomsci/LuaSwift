# Lua

A Swift wrapper for [Lua 5.4](https://www.lua.org/manual/5.4/). All Swift APIs are added as extensions to `UnsafeMutablePointer<lua_State>`, meaning you can freely mix Lua C calls (and callbacks) with higher-level more Swift-like calls. Import `CLua` as well as `Lua` to access the C API directly.

## Usage

```swift
import Lua

let L = LuaState(libaries: .all)
L.getglobal("print")
try! L.pcall("Hello world!")
L.close()
``` 

Note the above could equally be written using the low-level API, or any mix of the two, for example:

```swift
import Lua
import CLua

let L = luaL_newstate()
luaL_openlibs(L)
// The above two lines are exactly equivalent to `let L = LuaState(libaries: .all)`
lua_getglobal(L, "print") // same as L.getglobal("print")
lua_pushstring(L, "Hello world!")
lua_pcall(L, 1, 0) // Ignoring some error checking here...
lua_close(L)
```
