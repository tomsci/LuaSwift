# LuaSwift

A Swift wrapper for the [Lua 5.4](https://www.lua.org/manual/5.4/) C API. All Swift APIs are added as extensions to `UnsafeMutablePointer<lua_State>`, meaning you can freely mix Lua C calls (and callbacks) with higher-level more Swift-like calls. Any Lua APIs without a dedicated `LuaState` wrapper can be accessed by importing `CLua`.

Because this package mostly uses the raw C Lua paradigms (with a thin layer of Swift type-friendly wrappers on top), familiarity with the [Lua C API](https://www.lua.org/manual/5.4/manual.html#4) is strongly recommended. In particular, misusing the Lua stack will crash your program.

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

It could also be written using the slightly higher-level (but slightly less efficient) `LuaValue`-based API:

```swift
import Lua

let L = LuaState(libaries: .all)
try! L.globals["print"]?.pcall("Hello world!")
L.close()
```

`LuaState` is a `typealias` to `UnsafeMutablePointer<lua_State>`, which is the Swift bridged equivalent of `lua_State *` in C.

All functions callable from Lua have the type signature [`lua_CFunction`](https://www.lua.org/manual/5.4/manual.html#lua_CFunction), otherwise written `int myFunction(lua_State *L) { ... }`. The Swift equivalent signature is `(LuaState!) -> CInt`. For example:

```swift
import Lua

func myLuaCFunction(_ L: LuaState!) -> CInt {
    print("I am a Swift function callable from Lua!")
    return 0
}
``` 

## Type conversions

Swift structs and classes can be bridged into Lua in a type-safe and reference-counted manner, using Lua's `userdata` and metatable mechanisms. When the bridged Lua object is garbage collected by the Lua runtime, the Swift object is deinited.

Each Swift type is assigned a Lua metatable, which defines which members the bridged object has and how to call them.

The example below defines a metatable for `Foo` which exposes the Swift `Foo.bar()` function by defining a `lua_CFunction` compatible "bar" closure which calls `Foo.bar()`:

```swift
import Lua

class Foo {
    let baz: String
    func bar() {
        print("Foo.bar() called, baz=\(baz)")
    }
}

let L = LuaState(libraries: [])
L.registerMetatable(for: Foo.self, functions: [
    "bar": { (L: LuaState!) -> CInt in
        // Recover the `Foo` instance from the first argument to the function
        let foo: Foo = L.tovalue(1)
        // Call the function
        foo.bar()
        // Tell Lua that this function returns zero results
        return 0
    }
])
```

Then pass the `Foo` instance to Lua using `push(userdata:)` or `push(any:)`:

```swift
let foo = Foo(baz: "my foo instance")
L.push(userdata: foo)
// Then pcall into Lua, etc
```

From Lua, the userdata object can be called as if it were a Lua object:

```lua
foo:bar()
-- Prints "Foo.bar() called, baz=my foo instance"
```

## Thread safety

There is no hidden global state used to implement the type conversions, or to implement `setDefaultStringEncoding()`. Each top-level `LuaState` is completely independent, just a normal C `lua_State` is. Meaning you can safely use different `LuaState` instances from different threads at the same time. More technically, all `LuaState` APIs are [_reentrant_ but _not_ thread-safe](https://doc.qt.io/qt-6/threads-reentrancy.html), in the same way that the Lua C API is.
