# LuaState

## Overview

`LuaState` is the primary way of accessing the Lua APIs. It is technically a typealias to `UnsafeMutablePointer<lua_State>`, which is then extended to provide the Swift-friendly type-safe APIs described below.

It can therefore be constructed either using the explicit constructor provided, or any C `lua_State` obtained from anywhere can be treated as a `LuaState` Swift object. By convention `LuaState`/`lua_State` variables are often called `L`, although that is not mandatory.

See the [Readme](https://github.com/tomsci/LuaSwift/blob/main/README.md#usage) for some example usage. See <https://www.lua.org/manual/5.4/manual.html> for documentation of the underlying Lua C APIs.

Note that `LuaState` pointers are _not_ reference counted, meaning the state is not automatically destroyed when it goes out of scope. You must call ``Lua/Swift/UnsafeMutablePointer/close()``.

### Using the LuaState API

There are two different ways to use the `LuaState` API - the **stack-based** API which will be familiar to Lua C developers, just with stronger typing, and the **object-oriented** API using `LuaValue`, which behaves more naturally but has much more going on under the hood to make that work, and is also less flexible. The two styles, as well as the raw `CLua` API, can be freely mixed, so you can for example use the higher-level API for convenience where it works, and drop down to the stack-based or raw APIs where necessary.

In both styles of API, the only call primitive that is exposed is `pcall()`. `lua_call()` is not safe to call from Swift (because it can error, bypassing Swift stack unwinding) and thus is not exposed. Import `CLua` and call `lua_call()` directly if you really need to, and are certain the call cannot possibly error. `pcall()` converts Lua errors to Swift ones (of type ``LuaCallError``) and thus must always be called with `try`.

#### Stack-based API

As in the Lua C API, functions and values are pushed on to the stack with one of the [`push(...)`](#push()-functions) APIs, called using one of the [`pcall(...)`](#calling-into-lua) overloads, and results are read from the stack using one of the [`to...()`](#to…()-functions) APIs.

```swift
import Lua
let L = LuaState(libaries: .all)
L.getglobal("print")
L.push("Hello world!")
try! L.pcall(nargs: 1, nret: 0)
```

#### Object-oriented API

This API uses a single Swift type ``LuaValue`` to represent any Lua value (including `nil`). This type supports convenience call and subscript operators. A computed property ``Lua/Swift/UnsafeMutablePointer/globals`` allows a convenient way to access the global Lua environment. A ``LuaValueError`` is thrown if a `LuaValue` is accessed in a way which the underlying Lua value does not support - for example trying to call something which is not callable.

```swift
import Lua
let L = LuaState(libaries: .all)
let printfn = try L.globals["print"] // printfn is a LuaValue...
try printfn("Hello world!") // ... which can be called

try L.globals("wat?") // but this will error because the globals table is not callable.
```

`LuaValue` supports subscript assignment (again providing the underlying Lua value does), although due to limitations in Swift typing you can only do this with `LuaValue`s, to assign any value use ``LuaValue/set(_:_:)`` or construct a `LuaValue` with ``Lua/Swift/UnsafeMutablePointer/ref(any:)``:

```swift
let g = L.globals
g.set("foo", "bar") // ok
g["baz"] = g["foo"] // ok
g["baz"] = "bat" // BAD: cannot do this
g["baz"] = L.ref(any: "bat") // ok

```

#### C API

To access the underlying [Lua C API](https://www.lua.org/manual/5.4/manual.html#4.6) import `CLua`:

```swift
import CLua
let L = luaL_newstate()
// ...
lua_close(L)
```

The `Lua` and `CLua` APIs can be freely mixed, a `lua_State` from `CLua` can be used as if it were a `LuaState` from `Lua`, and vice versa:

```swift
import Lua
import CLua

let L = luaL_newstate()
lua_getglobal(L, "print")
// This L can be used as a LuaState:
try L.pcall("Hello world")
L.close()
```

Using `CLua` directly is generally only useful for complex stack manipulations for which there are no suitable higher-level functions declared by `Lua`.

### Thread safety

As a result of `LuaState` being usable anywhere a C `lua_State` is, all the internal state needed by the `LuaState` (for example, tracking metatables and default string encodings) is stored inside the state itself (using the Lua registry), meaning each top-level `LuaState` is completely independent, just a normal C `lua_State` is.

Therefore you can safely use different `LuaState` instances from different threads at the same time. More technically, all `LuaState` APIs are [_reentrant_ but _not_ thread-safe](https://doc.qt.io/qt-6/threads-reentrancy.html), in the same way that the Lua C API is.

### Bridging Swift objects

Swift structs and classes can be bridged into Lua in a type-safe and reference-counted manner, using Lua's userdata and metatable mechanisms. When the bridged Lua value is garbage collected by the Lua runtime, a reference to the Swift value is released.

``Lua/Swift/UnsafeMutablePointer/registerMetatable(for:functions:)`` is used to register a Lua metatable for a given Swift type. This defines which members the bridged object has and how to call them. A bridged type with no additional members defined will not be callable from Lua, but retains a reference to the Swift value until it is garbage collected.

All bridged objects automatically gain the ability to be [closed](https://www.lua.org/manual/5.4/manual.html#3.3.8) (when using Lua 5.4 or later), that is to say that in addition to adding a `__gc` function to the type's metatable, a default `__close` function is also added. This default implementation deinits the Swift object, after which point `touserdata<T>()` will always return `nil`. Provide a custom implementation of `__toclose` in the call to `registerMetatable()` to override this behavior if, for example, the object still needs to be callable from Lua after being closed.

The example below defines a metatable for `Foo` which exposes the Swift `Foo.bar()` function by defining a "bar" closure which calls `Foo.bar()`. ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)`` is used to convert the Lua value back to a Swift `Foo` type. Note that by using the `.closure` type, "bar" is allowed to throw Swift errors which are converted to Lua errors. (If `.function` was used instead of `.closure`, throwing errors would not be permitted, see the discussion on ``LuaClosure``.)

```swift
import Lua

class Foo {
    let baz: String
    init(baz: String) {
        self.baz = baz
    }
    func bar() {
        print("Foo.bar() called, baz=\(baz)")
    }
}

let L = LuaState(libraries: [])
L.registerMetatable(for: Foo.self, functions: [
    "bar": .closure { L in
        // Recover the `Foo` instance from the first argument to the function
        guard let foo: Foo = L.touserdata(1) else {
            throw L.error("Bad argument #1 to bar()")
        }
        // Call the function
        foo.bar()
        // Tell Lua that this function returns zero results
        return 0
    }
])
```

Then pass the `Foo` instance to Lua using ``Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)`` or ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)``:

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

### Converting types using Any

Any Swift type can be converted to a Lua value by calling ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)`` (or any of the convenience functions which use it, such as `pcall(args...)` or ``Lua/Swift/UnsafeMutablePointer/ref(any:)``). See the documentation for ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)`` for exact details of the conversion.

Any Lua value can be converted back to a Swift value of type `T?` by calling ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)``. `table`s and `string`s are converted to whichever type is appropriate to satisfy the type `T`. If the type contraint `T` cannot be satisfied, `tovalue<T>()` returns nil. If `T` is `Any` (ie the most relaxed type constraint), but there is no Swift type capable of representing the Lua value (for example, a function written in Lua) then a ``LuaValue`` instance is returned. Similarly if `T` is `Dictionary<AnyHashable, Any>` but the Lua table contains a key which when converted is not hashable in Swift, `LuaValue` will be used there as well.

Any Lua value can be tracked as a Swift object, without converting back into a Swift type, by calling ``Lua/Swift/UnsafeMutablePointer/ref(index:)`` which returns a ``LuaValue`` object.

### Interop with other uses of the C Lua API

The intent is for LuaSwift to be as flexible as possible with regard to what the client code might want to do with the `lua_State`. That said, there are a couple of assumptions that must hold true for LuaSwift to function correctly.

* The [registry table](https://www.lua.org/manual/5.4/manual.html#4.3) must not be manipulated in any way that violates the assumptions of [`luaL_ref`](https://www.lua.org/manual/5.4/manual.html#luaL_ref) or [`luaL_newmetatable`](https://www.lua.org/manual/5.4/manual.html#luaL_newmetatable). [`LUA_RIDX_MAINTHREAD`](https://www.lua.org/manual/5.4/manual.html#pdf-LUA_RIDX_MAINTHREAD) and [`LUA_RIDX_GLOBALS`](https://www.lua.org/manual/5.4/manual.html#pdf-LUA_RIDX_GLOBALS) are assumed to be valid.

* LuaSwift may set registry table entries using keys that are private `lua_CFunction` pointers or strings with prefix `"LuaSwift_"`. Clients must not interfere with such entries. LuaSwift also uses `luaL_ref` internally.

* To use ``Lua/Swift/UnsafeMutablePointer/setRequireRoot(_:displayPath:)``, the `package` library must be imported and `package.searchers` must be set to its default value.

### Support for different Lua versions

LuaSwift by default includes Lua 5.4.6. The codebase will also work with any 5.3 or 5.4 release, but to do that you need to fork the repository and check out an appropriate branch of the submodule `Sources/CLua/lua`.

Versions older than 5.3 are sufficiently different in their API that it's not straightforward to support.

### Push functions toindex parameter

All of the [`push()`](#push()-functions) APIs take an optional parameter `toindex` which specifies where on the stack to put the new element. This is the stack index where the element should be on return of the function, and is allowed to be relative. So `-1` means push the element onto the top of the stack (the default), `-2` means put it just below the top of the stack, `1` means put it at the bottom of the stack, etc. Existing stack elements will be moved if necessary as per [`lua_insert()`](https://www.lua.org/manual/5.4/manual.html#lua_insert).

## Topics

### State management

- ``Lua/Swift/UnsafeMutablePointer/init(libraries:)``
- ``Lua/Swift/UnsafeMutablePointer/openLibraries(_:)``
- ``Lua/Swift/UnsafeMutablePointer/close()``
- ``Lua/Swift/UnsafeMutablePointer/setRequireRoot(_:displayPath:)``
- ``Lua/Swift/UnsafeMutablePointer/addModules(_:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/setModules(_:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/getDefaultStringEncoding()``
- ``Lua/Swift/UnsafeMutablePointer/setDefaultStringEncoding(_:)``

### Basic stack functionality

- ``Lua/Swift/UnsafeMutablePointer/type(_:)``
- ``Lua/Swift/UnsafeMutablePointer/typename(index:)``
- ``Lua/Swift/UnsafeMutablePointer/isnone(_:)``
- ``Lua/Swift/UnsafeMutablePointer/isnoneornil(_:)``
- ``Lua/Swift/UnsafeMutablePointer/pop(_:)``
- ``Lua/Swift/UnsafeMutablePointer/gettop()``
- ``Lua/Swift/UnsafeMutablePointer/settop(_:)``
- ``Lua/Swift/UnsafeMutablePointer/absindex(_:)``
- ``Lua/Swift/UnsafeMutablePointer/checkstack(_:)``
- ``Lua/Swift/UnsafeMutablePointer/insert(_:)``
- ``Lua/Swift/UnsafeMutablePointer/newtable(narr:nrec:)``

### to...() functions

- ``Lua/Swift/UnsafeMutablePointer/toboolean(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tointeger(_:)``
- ``Lua/Swift/UnsafeMutablePointer/toint(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tonumber(_:)``
- ``Lua/Swift/UnsafeMutablePointer/todata(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tostringUtf8(_:convert:)``
- ``Lua/Swift/UnsafeMutablePointer/tostring(_:encoding:convert:)-4dzgb``
- ``Lua/Swift/UnsafeMutablePointer/tostring(_:encoding:convert:)-9syls``
- ``Lua/Swift/UnsafeMutablePointer/toany(_:guessType:)``
- ``Lua/Swift/UnsafeMutablePointer/touserdata(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)``
- ``Lua/Swift/UnsafeMutablePointer/todecodable(_:)``
- ``Lua/Swift/UnsafeMutablePointer/todecodable(_:_:)``

### push() functions

- ``Lua/Swift/UnsafeMutablePointer/pushnil(toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/pushfail(toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(index:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9``
- ``Lua/Swift/UnsafeMutablePointer/push(string:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(utf8String:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(string:encoding:toindex:)-6rddl``
- ``Lua/Swift/UnsafeMutablePointer/push(string:encoding:toindex:)-9nxec``
- ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9``
- ``Lua/Swift/UnsafeMutablePointer/push(bytes:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(function:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(error:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:toindex:)-pont``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:toindex:)-nmyz``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:toindex:)-2hshc``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:toindex:)-7d7ly``
- ``Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/pushGlobals(toindex:)``

### Iterators

- ``Lua/Swift/UnsafeMutablePointer/ipairs(_:start:resetTop:)``
- ``Lua/Swift/UnsafeMutablePointer/for_ipairs(_:start:_:)``
- ``Lua/Swift/UnsafeMutablePointer/pairs(_:)``
- ``Lua/Swift/UnsafeMutablePointer/for_pairs(_:_:)``

### Calling into Lua

- ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:traceback:)``
- ``Lua/Swift/UnsafeMutablePointer/pcall(_:traceback:)-2ujhj``
- ``Lua/Swift/UnsafeMutablePointer/pcall(_:traceback:)-3qlin``

### Registering metatables

- ``Lua/Swift/UnsafeMutablePointer/registerMetatable(for:functions:)``
- ``Lua/Swift/UnsafeMutablePointer/isMetatableRegistered(for:)``
- ``Lua/Swift/UnsafeMutablePointer/registerDefaultMetatable(functions:)``

### Get/Set functions

- ``Lua/Swift/UnsafeMutablePointer/rawget(_:)``
- ``Lua/Swift/UnsafeMutablePointer/rawget(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/rawget(_:utf8Key:)``
- ``Lua/Swift/UnsafeMutablePointer/rawget(_:key:_:)``
- ``Lua/Swift/UnsafeMutablePointer/get(_:)``
- ``Lua/Swift/UnsafeMutablePointer/get(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/get(_:key:_:)``
- ``Lua/Swift/UnsafeMutablePointer/getdecodable(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/getglobal(_:)``
- ``Lua/Swift/UnsafeMutablePointer/setglobal(name:)``
- ``Lua/Swift/UnsafeMutablePointer/setglobal(name:value:)``
- ``Lua/Swift/UnsafeMutablePointer/rawset(_:)``
- ``Lua/Swift/UnsafeMutablePointer/rawset(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/rawset(_:utf8Key:)``
- ``Lua/Swift/UnsafeMutablePointer/rawset(_:key:value:)``
- ``Lua/Swift/UnsafeMutablePointer/rawset(_:utf8Key:value:)``
- ``Lua/Swift/UnsafeMutablePointer/set(_:)``
- ``Lua/Swift/UnsafeMutablePointer/set(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/set(_:key:value:)``

### Convenience get plus to...() functions

- ``Lua/Swift/UnsafeMutablePointer/toboolean(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/toint(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/tonumber(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/todata(_:key:)``
- ``Lua/Swift/UnsafeMutablePointer/tostring(_:key:convert:)``

### Comparison functions

- ``Lua/Swift/UnsafeMutablePointer/rawequal(_:_:)``
- ``Lua/Swift/UnsafeMutablePointer/equal(_:_:)``
- ``Lua/Swift/UnsafeMutablePointer/compare(_:_:_:)``

### Loading code

- ``Lua/Swift/UnsafeMutablePointer/load(file:displayPath:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(data:name:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(buffer:name:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(bytes:name:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(string:name:)``
- ``Lua/Swift/UnsafeMutablePointer/dofile(_:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/dump(strip:)``

### Garbage collection

- ``Lua/Swift/UnsafeMutablePointer/collectgarbage(_:)``
- ``Lua/Swift/UnsafeMutablePointer/collectorRunning()``
- ``Lua/Swift/UnsafeMutablePointer/collectorCount()``
- ``Lua/Swift/UnsafeMutablePointer/collectorStep(_:)``
- ``Lua/Swift/UnsafeMutablePointer/collectorSetIncremental(pause:stepmul:stepsize:)``
- ``Lua/Swift/UnsafeMutablePointer/collectorSetGenerational(minormul:majormul:)``

### Debugging

- ``Lua/Swift/UnsafeMutablePointer/withStackFrameFor(level:_:)``
- ``Lua/Swift/UnsafeMutablePointer/getStackInfo(level:what:)``
- ``Lua/Swift/UnsafeMutablePointer/getTopFunctionInfo(what:)``
- ``Lua/Swift/UnsafeMutablePointer/getTopFunctionArguments()``
- ``Lua/Swift/UnsafeMutablePointer/getInfo(_:what:)``
- ``Lua/Swift/UnsafeMutablePointer/getWhere(level:)``

### Upvalues

- ``Lua/Swift/UnsafeMutablePointer/pushUpvalue(index:n:)``
- ``Lua/Swift/UnsafeMutablePointer/getUpvalue(index:n:)``
- ``Lua/Swift/UnsafeMutablePointer/getUpvalues(index:)``
- ``Lua/Swift/UnsafeMutablePointer/findUpvalue(index:name:)``
- ``Lua/Swift/UnsafeMutablePointer/setUpvalue(index:n:value:)``

### Miscellaneous

- ``Lua/Swift/UnsafeMutablePointer/requiref(name:function:global:)``
- ``Lua/Swift/UnsafeMutablePointer/requiref(name:global:closure:)``
- ``Lua/Swift/UnsafeMutablePointer/setfuncs(_:nup:)``
- ``Lua/Swift/UnsafeMutablePointer/error(_:)``
- ``Lua/Swift/UnsafeMutablePointer/ref(index:)``
- ``Lua/Swift/UnsafeMutablePointer/ref(any:)``
- ``Lua/Swift/UnsafeMutablePointer/popref()``
- ``Lua/Swift/UnsafeMutablePointer/globals``
- ``Lua/Swift/UnsafeMutablePointer/getMainThread()``
- ``Lua/Swift/UnsafeMutablePointer/rawlen(_:)``
- ``Lua/Swift/UnsafeMutablePointer/len(_:)``
