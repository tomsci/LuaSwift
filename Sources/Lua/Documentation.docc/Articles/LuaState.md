# LuaState

## Overview

`LuaState` is the primary way of accessing the Lua APIs. It is technically a typealias to `UnsafeMutablePointer<lua_State>`, which is then extended to provide the Swift-friendly type-safe APIs described below.

It can therefore be constructed either using the explicit constructor provided, or any C `lua_State` obtained from anywhere can be treated as a `LuaState` Swift object. By convention `LuaState`/`lua_State` variables are often called `L`, although that is not mandatory.

See the [Readme](https://github.com/tomsci/LuaSwift/blob/main/README.md#usage) for some example usage. See <https://www.lua.org/manual/5.4/manual.html> for documentation of the underlying Lua C APIs.

Note that `LuaState` pointers are _not_ reference counted, meaning the state is not automatically destroyed when it goes out of scope. You must call ``Lua/Swift/UnsafeMutablePointer/close()``.

### Using the LuaState API

There are two different ways to use the `LuaState` API - the **stack-based** API which will be familiar to Lua C developers, just with stronger typing, and the **object-oriented** API using `LuaValue`, which behaves more naturally but has much more going on under the hood to make that work, and is also less flexible. The two styles, as well as the raw `CLua` API, can be freely mixed, so you can for example use the higher-level API for convenience where it works, and drop down to the stack-based or raw APIs where necessary.

In both styles of API, the only call primitive that is exposed is `pcall()`. `lua_call()` is not safe to call from Swift (because it can error, bypassing Swift stack unwinding) and thus is not exposed. import `CLua` and call `lua_call()` directly if you really need to. `pcall()` converts Lua errors to Swift ones (of type ``LuaCallError``) and thus must always be called with `try`.

#### Stack-based API

As in the Lua C API, functions and values are pushed on to the stack with one of the [`push(...)`](#push()-functions) APIs, called using one of the [`pcall(...)`](#calling-into-lua) overloads, and results are read from the stack using one of the [`to...()`](#to…()-functions) APIs.

#### Object-oriented API

This API uses a single Swift type ``LuaValue`` to represent any Lua value (including `nil`). This type supports convenience call and subscript operators. A computed property ``Lua/Swift/UnsafeMutablePointer/globals`` allows a convenient way to access the global Lua environment. A ``LuaValueError`` is thrown if a `LuaValue` is accessed in a way which the underlying Lua value does not support - for example trying to call something which is not callable.

```swift
import Lua
let L = LuaState(libaries: .all)
let printfn = try L.globals["print"] // printfn is a LuaValue...
try printfn("Hello world!") // ... which can be called

try L.globals("wat?") // but this will error because the globals table is not callable.
```

`LuaValue` supports subscript assignment (again providing the underlying Lua value does), although due to limitations in Swift typing you can only do this with `LuaValue`s, to assign any value use `set()` or construct a `LuaValue` with `L.ref(any:)`:

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

This is generally only useful for complex stack manipulations for which there are no suitable higher-level functions declared by `Lua`.

### Thread safety

As a result of `LuaState` being usable anywhere a C `lua_State` is, all the internal state needed by the `LuaState` (for example, tracking metatables and default string encodings) is stored inside the state itself (using the Lua registry), meaning each top-level `LuaState` is completely independent, just a normal C `lua_State` is.

Therefore you can safely use different `LuaState` instances from different threads at the same time. More technically, all `LuaState` APIs are [_reentrant_ but _not_ thread-safe](https://doc.qt.io/qt-6/threads-reentrancy.html), in the same way that the Lua C API is.

### Bridging Swift objects

Swift structs and classes can be bridged into Lua in a type-safe and reference-counted manner, using Lua's `userdata` and metatable mechanisms. When the bridged Lua object is garbage collected by the Lua runtime, a reference to the Swift value is released.

``Lua/Swift/UnsafeMutablePointer/registerMetatable(for:functions:)`` is used to register a Lua metatable for a given Swift type. This defines which members the bridged object has and how to call them. A bridged type with no additional members defined will not be callable from Lua, but retains a reference to the Swift value until it is garbage collected.

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
        guard let foo: Foo = L.tovalue(1) else {
            throw L.error("Bad argument #1 to bar()")
        }
        // Call the function
        foo.bar()
        // Tell Lua that this function returns zero results
        return 0
    }
])
```

Then pass the `Foo` instance to Lua using ``Lua/Swift/UnsafeMutablePointer/push(userdata:)`` or ``Lua/Swift/UnsafeMutablePointer/push(any:)``:

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

Any Swift type can be converted to a Lua value by calling ``Lua/Swift/UnsafeMutablePointer/push(any:)`` (or any of the convenience functions which use it, such as `pcall(args...)` or ``Lua/Swift/UnsafeMutablePointer/ref(any:)``). Arrays and Dictionaries are converted to Lua tables; Strings are converted to Lua strings using the default string encoding (see ``Lua/Swift/UnsafeMutablePointer/setDefaultStringEncoding(_:)``); numbers, booleans, Data, and nil Optionals are converted to the applicable Lua type. Any other type is bridged as described in the previous section.

Any Lua value can be converted back to a Swift value of type `T?` by calling ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)``. `table`s and `string`s are converted to whichever type is appropriate to satisfy the type `T`. If the type contraint `T` cannot be satisfied, `tovalue<T>()` returns nil. If `T` is `Any` (ie the most relaxed type constrait), but there is no Swift type capable of representing the Lua value (for example, a closure) then a ``LuaValue`` instance is returned. Similarly if `T` is `Dictionary<AnyHashable, Any>` but the Lua table contains a key which when converted is not hashable in Swift, `LuaValue` will be used there as well.

Any Lua value can be tracked as a Swift object, without converting back into a Swift type, by calling ``Lua/Swift/UnsafeMutablePointer/ref(index:)`` which returns a ``LuaValue`` object.

### Interop with other uses of the C Lua API

The intent is for LuaSwift to be as flexible as possible with regard to what the client code might want to do with the `lua_State`. That said, there are a couple of assumptions that must hold true for LuaSwift to function correctly.

* The [registry table](https://www.lua.org/manual/5.4/manual.html#4.3) must not be manipulated in any way that violates the assumptions of [`luaL_ref`](https://www.lua.org/manual/5.4/manual.html#luaL_ref) or [`luaL_newmetatable`](https://www.lua.org/manual/5.4/manual.html#luaL_newmetatable).

* LuaSwift may set registry table entries using keys that are private `lua_CFunction` pointers or strings with prefix `"LuaSwift_"`. Clients must not interfere with such entries. LuaSwift also uses `luaL_ref` internally.

* To use ``Lua/Swift/UnsafeMutablePointer/setRequireRoot(_:displayPath:)``, the `package` library must be imported and `package.searchers` must be set to its default value.

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
- ``Lua/Swift/UnsafeMutablePointer/typename(type:)``
- ``Lua/Swift/UnsafeMutablePointer/typename(index:)``
- ``Lua/Swift/UnsafeMutablePointer/isnone(_:)``
- ``Lua/Swift/UnsafeMutablePointer/isnoneornil(_:)``
- ``Lua/Swift/UnsafeMutablePointer/pop(_:)``
- ``Lua/Swift/UnsafeMutablePointer/gettop()``
- ``Lua/Swift/UnsafeMutablePointer/settop(_:)``
- ``Lua/Swift/UnsafeMutablePointer/absindex(_:)``
- ``Lua/Swift/UnsafeMutablePointer/checkstack(_:)``

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

- ``Lua/Swift/UnsafeMutablePointer/pushnil()``
- ``Lua/Swift/UnsafeMutablePointer/push(index:)``
- ``Lua/Swift/UnsafeMutablePointer/push(_:)-5b22c``
- ``Lua/Swift/UnsafeMutablePointer/push(string:)``
- ``Lua/Swift/UnsafeMutablePointer/push(utf8String:)``
- ``Lua/Swift/UnsafeMutablePointer/push(string:encoding:)-277x``
- ``Lua/Swift/UnsafeMutablePointer/push(string:encoding:)-75xks``
- ``Lua/Swift/UnsafeMutablePointer/push(_:)-3o5nr``
- ``Lua/Swift/UnsafeMutablePointer/push(bytes:)``
- ``Lua/Swift/UnsafeMutablePointer/push(function:)``
- ``Lua/Swift/UnsafeMutablePointer/push(error:)``
- ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:)``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:)-80bt5``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:)-22ess``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:)-4rotd``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:)-5wt8k``
- ``Lua/Swift/UnsafeMutablePointer/push(userdata:)``
- ``Lua/Swift/UnsafeMutablePointer/push(any:)``
- ``Lua/Swift/UnsafeMutablePointer/pushGlobals()``

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
- ``Lua/Swift/UnsafeMutablePointer/registerDefaultMetatable(functions:)-5ul4z``

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

### Loading code

- ``Lua/Swift/UnsafeMutablePointer/load(file:displayPath:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(data:name:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(buffer:name:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(bytes:name:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(string:name:)``
- ``Lua/Swift/UnsafeMutablePointer/dofile(_:mode:)``

### Garbage collection

- ``Lua/Swift/UnsafeMutablePointer/collectgarbage(_:)``
- ``Lua/Swift/UnsafeMutablePointer/collectorRunning()``
- ``Lua/Swift/UnsafeMutablePointer/collectorCount()``

### Debugging

- ``Lua/Swift/UnsafeMutablePointer/getStackInfo(level:what:)``
- ``Lua/Swift/UnsafeMutablePointer/getTopFunctionInfo(what:)``
- ``Lua/Swift/UnsafeMutablePointer/getInfo(_:what:)``

### Miscellaneous

- ``Lua/Swift/UnsafeMutablePointer/requiref(name:function:global:)``
- ``Lua/Swift/UnsafeMutablePointer/requiref(name:global:closure:)``
- ``Lua/Swift/UnsafeMutablePointer/setfuncs(_:nup:)``
- ``Lua/Swift/UnsafeMutablePointer/error(_:)``
- ``Lua/Swift/UnsafeMutablePointer/ref(index:)``
- ``Lua/Swift/UnsafeMutablePointer/ref(any:)``
- ``Lua/Swift/UnsafeMutablePointer/popref()``
- ``Lua/Swift/UnsafeMutablePointer/globals``
- ``Lua/Swift/UnsafeMutablePointer/rawlen(_:)``
- ``Lua/Swift/UnsafeMutablePointer/len(_:)``
- ``Lua/Swift/UnsafeMutablePointer/rawequal(_:_:)``