# LuaState

## Overview

`LuaState` is the primary way of accessing the Lua APIs. It is implemented as a typealias to `UnsafeMutablePointer<lua_State>`, which is then extended to provide the Swift-friendly type-safe APIs described below.

```swift
typealias LuaState = UnsafeMutablePointer<lua_State>
```

It can therefore be constructed either using the explicit constructor provided, or any C `lua_State` pointer obtained from anywhere can be treated as a `LuaState` Swift object. By convention `LuaState`/`lua_State` variables are often called `L`, although this is not mandatory.

See <https://www.lua.org/manual/5.4/manual.html> for documentation of the underlying Lua C APIs.

Note that `LuaState` is an unsafe pointer type which is _not_ reference counted, meaning the state is not automatically destroyed when it goes out of scope. You must call ``Lua/Swift/UnsafeMutablePointer/close()``. Safe ways to do that include wrapping the `LuaState` in a class and calling close from `deinit`, or using a `defer` block:

```swift
class LuaStateWrapper {
    let L: LuaState

    init() {
        L = LuaState(libraries: .all)
    }
    deinit {
        L.close()
    }
}

// or...

let L = LuaState(libraries: .all)
defer {
    L.close()
}
// Use L here...
```

## Using the LuaState API

There are two different ways to use the `LuaState` API - the **stack-based** API which will be familiar to Lua C developers, just with stronger typing, and the **object-oriented** API using ``LuaValue``, which behaves more naturally but has much more going on under the hood to make that work, and is also less flexible. The two styles, as well as the raw `CLua` API, can be freely mixed, so you can for example use the higher-level API for convenience where it works, and drop down to the stack-based or raw APIs where necessary.

In both styles of API, the only call primitive that is exposed is `pcall()`. `lua_call()` is not safe to call directly from Swift (because it can error, bypassing Swift stack unwinding) and thus is not exposed. Import `CLua` and call `lua_call()` directly if you really need to, and are certain the call cannot possibly error. `pcall()` converts Lua errors to Swift ones (by default, of type ``LuaCallError``) and thus must always be called with `try`.

### Stack-based API

As in the Lua C API, functions and values are pushed on to the stack with one of the [`push(...)`](#push()-functions) APIs, called using one of the [`pcall(...)`](#calling-into-lua) overloads, and results are read from the stack using one of the [`to...()`](#to…()-functions) APIs.

```swift
import Lua
let L = LuaState(libraries: .all)
L.getglobal("print")
L.push("Hello world!")
try! L.pcall(nargs: 1, nret: 0)
```

There are convenience functions to combine pushing the arguments and the `pcall`, using the logic in [`push(any:)`](doc:Lua/Swift/UnsafeMutablePointer/push(any:toindex:)):

```swift
import Lua
let L = LuaState(libraries: .all)
L.getglobal("print")
try! L.pcall("Hello world!")
```

### Object-oriented API

This API uses a single Swift type ``LuaValue`` to represent any Lua value (including `nil`) independently from the current state of the Lua stack, which allows for a much more object-oriented API, including convenience call and subscript operators. A computed property ``Lua/Swift/UnsafeMutablePointer/globals`` allows a convenient way to access the global Lua environment as a `LuaValue`. A ``LuaValueError`` is thrown if a `LuaValue` is accessed in a way which the underlying Lua value does not support - for example trying to call something which is not callable.

```swift
import Lua
let L = LuaState(libraries: .all)
let printfn = try L.globals["print"] // printfn is a LuaValue...
try printfn("Hello world!") // ... which can be called

// but this will error because the globals table is not callable.
try L.globals("wat?")

// and so will this because printfn is not a table (or other indexable)
try printfn["nope"]
```

`LuaValue` supports subscript assignment (again providing the underlying Lua value does), although due to limitations in Swift typing you can only do this with `LuaValue`s, to assign any value use ``LuaValue/set(_:_:)`` or construct a `LuaValue` with ``Lua/Swift/UnsafeMutablePointer/ref(any:)``:

```swift
let g = L.globals
g.set("foo", "bar") // _G.foo = "bar"
g["baz"] = g["foo"] // _G.baz = _G.foo
g["baz"] = "bat" // BAD: cannot do this
g["baz"] = L.ref(any: "bat") // _G.baz = "bat"

```

### C API

To access the underlying [Lua C API](https://www.lua.org/manual/5.4/manual.html#4.6) import `CLua`:

```swift
import CLua
let L = luaL_newstate()
// ...
lua_close(L)
```

Those parts of the C API that are implemented as macros have been reimplemented as functions, so they can be callable from Swift without having to worry about the distinction.

The `Lua` and `CLua` APIs can be freely mixed, an `UnsafeMutablePointer<lua_State>` from `CLua` (bridged from the C `lua_State*` type) can be used as if it were a `LuaState` from `Lua`, and vice versa:

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

Keep in mind that the C API gives access to functions which are (or can be) unsafe to call from Swift. It is possible to leak memory, orphan Swift objects, or crash the process by misusing the C API.

## Error handling

Lua errors (implemented in C using `longjmp`) have no direct equivalent in Swift, because `longjmp` is not safe to call from Swift (just as C++ exceptions are not safe to throw from or through a Swift function either). They are instead translated to and from instances of the Swift Error type ``LuaCallError`` at the appropriate API boundaries. Instead of `lua_call()` erroring using a `longjmp` or `lua_pcall()` returning an error code and leaving an error object on the Lua stack, LuaState's `pcall()` throws a Swift `LuaCallError` instead. This means that `pcall()` and any other LuaState Swift API which can error are annotated with `throws` and thus must be called with a `try`, making it obvious what can error and what can't. APIs like `lua_call()` which are impossible to implement safely in Swift have no equivalent in `LuaState`. Import `CLua` and call `lua_call()` directly if you are absolutely certain the call cannot error and a protected call is not desired.

Any `Error` thrown by a `LuaClosure` (including `LuaCallError`) is automatically translated using ``Lua/Swift/UnsafeMutablePointer/push(error:toindex:)`` and then passed back to the Lua runtime using `lua_error()`. The LuaSwift wrappers ensure that the C `longjmp` does not cross a Swift API boundary when this happens.

Where an error might be raised in a `lua_CFunction` written in C like this:

```c
int myFn(lua_State *L) {
    if (/*something error-worthy*/) {
        return luaL_error(L, "Bad thing happened");
    }
    /* ... */
}
```

In a Swift `LuaClosure` it would be:

```swift
func myClosure(_ L: LuaState) throws -> CInt {
    if /*something error-worthy*/ {
        throw L.error("Bad thing happened")
    }
    /* ... */
}
```

## Thread safety

As a result of `LuaState` being usable anywhere a C `lua_State` is, all the internal state needed by the `LuaState` (for example, tracking metatables and default string encodings) is stored inside the state itself, using the Lua registry. This means each top-level `LuaState` is completely independent, just like a normal C `lua_State` is.

Therefore you can safely use different `LuaState` instances from different threads at the same time. More technically, all `LuaState` APIs are [_reentrant_ but _not_ thread-safe](https://doc.qt.io/qt-6/threads-reentrancy.html), in the same way that the Lua C API is.

## Bridging Swift objects

Swift structs and classes can be bridged into Lua in a type-safe and reference-counted manner, using Lua's userdata and metatable mechanisms. When the bridged Lua value is garbage collected by the Lua runtime, a reference to the Swift value is released.

See <doc:BridgingSwiftToLua> for more information.

### Converting types between Swift and Lua

There are multiple ways in which values can be converted between Swift types and Lua types.

* Primitive types which both languages have can be converted directly -- for example `Bool` maps directly to/from `boolean`, `String` with `string` and so on. These can be converted using the explicit typed functions like [`push<T:Pushable>(_:)`](doc:Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9) (`Boolean` conforms to `Pushable`) and ``Lua/Swift/UnsafeMutablePointer/toboolean(_:)`` or the generic functions [`push(any:)`](``doc:Lua/Swift/UnsafeMutablePointer/push(any:toindex:)) and [`tovalue<T>(_:)`](doc:Lua/Swift/UnsafeMutablePointer/tovalue(_:)) which can convert complex types as well as primitives.
* Arrays and Dictionaries can be converted to/from Lua tables according to the rules described in ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)``.
* Classes and structs can be [bridged](doc:BridgingSwiftToLua) into Lua, in which a proxy Lua object is used to refer to the original Swift value.
* Any Lua value can be tracked as a Swift object, without converting back into a Swift type, by calling ``Lua/Swift/UnsafeMutablePointer/ref(index:)`` which returns a ``LuaValue`` object which acts as a proxy to the Lua value. Broadly speaking this is equivalent to bridging a Swift value into Lua, as described above, just in the opposite direction.
* Alternatively, types conforming to `Encodable` and/or `Decodable` can be represented in Lua using their `Codable` structure, using ``Lua/Swift/UnsafeMutablePointer/push(encodable:toindex:)`` and/or ``Lua/Swift/UnsafeMutablePointer/todecodable(_:)``.

## Remarks

### Interop with other uses of the C Lua API

The intent is for LuaSwift to be as flexible as possible with regard to what the client code might want to do with the `lua_State`. That said, there are a couple of assumptions that must hold true for LuaSwift to function correctly.

* The [registry table](https://www.lua.org/manual/5.4/manual.html#4.3) must not be manipulated in any way that violates the assumptions of [`luaL_ref`](https://www.lua.org/manual/5.4/manual.html#luaL_ref) or [`luaL_newmetatable`](https://www.lua.org/manual/5.4/manual.html#luaL_newmetatable). [`LUA_RIDX_MAINTHREAD`](https://www.lua.org/manual/5.4/manual.html#pdf-LUA_RIDX_MAINTHREAD) and [`LUA_RIDX_GLOBALS`](https://www.lua.org/manual/5.4/manual.html#pdf-LUA_RIDX_GLOBALS) are assumed to behave in the usual way.

* LuaSwift may set registry table entries using keys that are private `lua_CFunction` pointers or strings with prefix `"LuaSwift_"`. Clients must not interfere with such entries. LuaSwift also uses `luaL_ref` internally.

* To use ``Lua/Swift/UnsafeMutablePointer/setRequireRoot(_:displayPath:)``, the `package` library must have been opened.

* ``Lua/Swift/UnsafeMutablePointer/requiref(name:global:closure:)`` assumes [`LUA_LOADED_TABLE`](https://www.lua.org/manual/5.4/manual.html#pdf-LUA_LOADED_TABLE) behaves in the usual way.

* ``Lua/Swift/UnsafeMutablePointer/addModules(_:mode:)`` and ``Lua/Swift/UnsafeMutablePointer/setModules(_:mode:)`` assume that [`LUA_PRELOAD_TABLE`](https://www.lua.org/manual/5.4/manual.html#pdf-LUA_PRELOAD_TABLE) behaves in the usual way.

### Support for different Lua versions

LuaSwift by default includes Lua 5.4.7. The codebase will also work with any 5.3 or 5.4 release, but to do that you need to fork the repository and check out an appropriate branch of the submodule `Sources/CLua/lua`.

Versions older than 5.3 are sufficiently different in their API that it's not straightforward to support.

### Push functions toindex parameter

All of the [`push()`](#push()-functions) APIs take an optional parameter `toindex` which specifies where on the stack to put the new element. This is the stack index where the element should be on return of the function, and is allowed to be relative. So `-1` means push the element on to the top of the stack (the default), `-2` means put it just below the top of the stack, `1` means put it at the bottom of the stack, etc. Existing stack elements will be moved if necessary as per ``Lua/Swift/UnsafeMutablePointer/insert(_:)``.

Most of the time, the desired behavior is to leave the value on the top of the stack, in which case the `toindex` parameter can omitted:

```swift
let x = 1
L.push(x)
```

### C functions deliberately not exposed

Some Lua C APIs do not make sense to be called from Swift; usually this is because they can call (even indirectly) `lua_error()`, which as described in the [#Error-handling](Error handling) section breaks the Swift runtime guarantees. As a result, there are some APIs which the LuaSwift `Lua` framework deliberately does not expose. A brief summary of some of the 'missing' APIs follows - they are all available by importing `CLua`, with the caveat that they _will_ break your program if any of the problematic behaviors (such as erroring) occur.

`lua_call()` - as described in [#Error-handling](Error handling) anything which can call `lua_error()` is not safe to call from Swift. Use `pcall()` instead, or import `CLua` and call `lua_call()` directly if you are _absolutely certain_ that the call cannot error.

`lua_toclose()`, `lua_closeslot()` - to-be-closed slots configured in native code are closely tied to error handling so are not exposed for the same reasons - `lua_closeslot()` can error, and `lua_toclose()` can make calls to `settop()` and `pop()` error (and the Swift wrappers cannot account for this without needing _all_ uses include a `try`). Thus they are too dangerous to expose. Since any Lua native function written in Swift needs to be working with Swift `Errors` anyway, using a Swift `defer {....}` block instead of `lua_closeslot()` is almost always the correct alternative.

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
- ``Lua/Swift/UnsafeMutablePointer/pop(_:)``
- ``Lua/Swift/UnsafeMutablePointer/gettop()``
- ``Lua/Swift/UnsafeMutablePointer/settop(_:)``
- ``Lua/Swift/UnsafeMutablePointer/absindex(_:)``
- ``Lua/Swift/UnsafeMutablePointer/checkstack(_:)``
- ``Lua/Swift/UnsafeMutablePointer/insert(_:)``
- ``Lua/Swift/UnsafeMutablePointer/remove(_:)``
- ``Lua/Swift/UnsafeMutablePointer/newtable(narr:nrec:)``

### to...() functions

- ``Lua/Swift/UnsafeMutablePointer/toboolean(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tointeger(_:convert:)``
- ``Lua/Swift/UnsafeMutablePointer/toint(_:convert:)``
- ``Lua/Swift/UnsafeMutablePointer/tonumber(_:convert:)``
- ``Lua/Swift/UnsafeMutablePointer/todata(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tostringUtf8(_:convert:)``
- ``Lua/Swift/UnsafeMutablePointer/tostring(_:encoding:convert:)-4dzgb``
- ``Lua/Swift/UnsafeMutablePointer/tostring(_:encoding:convert:)-9syls``
- ``Lua/Swift/UnsafeMutablePointer/toany(_:guessType:)``
- ``Lua/Swift/UnsafeMutablePointer/tolightuserdata(_:)``
- ``Lua/Swift/UnsafeMutablePointer/touserdata(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tovalue(_:type:)``
- ``Lua/Swift/UnsafeMutablePointer/todecodable(_:)``
- ``Lua/Swift/UnsafeMutablePointer/todecodable(_:type:)``
- ``Lua/Swift/UnsafeMutablePointer/tofilehandle(_:)``

### push() functions

- ``Lua/Swift/UnsafeMutablePointer/pushnil(toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/pushfail(toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(index:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9``
- ``Lua/Swift/UnsafeMutablePointer/push(string:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(utf8String:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(string:encoding:toindex:)-6rddl``
- ``Lua/Swift/UnsafeMutablePointer/push(string:encoding:toindex:)-9nxec``
- ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-171ku``
- ``Lua/Swift/UnsafeMutablePointer/push(bytes:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(function:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(error:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:toindex:)-pont``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:toindex:)-bpns``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:toindex:)-5gt3d``
- ``Lua/Swift/UnsafeMutablePointer/push(closure:toindex:)-7xtpf``
- ``Lua/Swift/UnsafeMutablePointer/push(lightuserdata:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(encodable:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/push(tuple:)``
- ``Lua/Swift/UnsafeMutablePointer/pushthread()``
- ``Lua/Swift/UnsafeMutablePointer/pushglobals(toindex:)-3ot28``

### Iterators

- ``Lua/Swift/UnsafeMutablePointer/ipairs(_:start:resetTop:)``
- ``Lua/Swift/UnsafeMutablePointer/ipairs(_:type:start:)``
- ``Lua/Swift/UnsafeMutablePointer/for_ipairs(_:start:_:)-16dkm``
- ``Lua/Swift/UnsafeMutablePointer/for_ipairs(_:start:_:)-5kkcd``
- ``Lua/Swift/UnsafeMutablePointer/for_ipairs(_:start:_:)-2u2ns``
- ``Lua/Swift/UnsafeMutablePointer/for_ipairs(_:start:type:_:)-9mbw7``
- ``Lua/Swift/UnsafeMutablePointer/for_ipairs(_:start:type:_:)-3v788``
- ``Lua/Swift/UnsafeMutablePointer/pairs(_:)``
- ``Lua/Swift/UnsafeMutablePointer/pairs(_:type:)``
- ``Lua/Swift/UnsafeMutablePointer/for_pairs(_:_:)-2v2e3``
- ``Lua/Swift/UnsafeMutablePointer/for_pairs(_:_:)-71zhp``
- ``Lua/Swift/UnsafeMutablePointer/for_pairs(_:_:)-b6tx``
- ``Lua/Swift/UnsafeMutablePointer/for_pairs(_:type:_:)-9g8dt``
- ``Lua/Swift/UnsafeMutablePointer/for_pairs(_:type:_:)-8xaw8``

### Calling into Lua

- ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:traceback:)``
- ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:msgh:)``
- ``Lua/Swift/UnsafeMutablePointer/pcall(_:traceback:)-2ujhj``
- ``Lua/Swift/UnsafeMutablePointer/pcall(_:traceback:)-3qlin``
- ``Lua/Swift/UnsafeMutablePointer/pcall(arguments:traceback:)-11jc5``
- ``Lua/Swift/UnsafeMutablePointer/pcall(arguments:traceback:)-8gv5``
- ``Lua/Swift/UnsafeMutablePointer/trypcall(nargs:nret:msgh:)-1otl1``
- ``Lua/Swift/UnsafeMutablePointer/trypcall(nargs:nret:msgh:)-5cvor``

### Coroutines

- ``Lua/Swift/UnsafeMutablePointer/newthread()``
- ``Lua/Swift/UnsafeMutablePointer/resume(from:nargs:)``
- ``Lua/Swift/UnsafeMutablePointer/pcallk(nargs:nret:traceback:continuation:)``
- ``Lua/Swift/UnsafeMutablePointer/pcallk(nargs:nret:msgh:continuation:)``
- ``Lua/Swift/UnsafeMutablePointer/callk(nargs:nret:continuation:)``
- ``Lua/Swift/UnsafeMutablePointer/yield(nresults:continuation:)``
- ``Lua/Swift/UnsafeMutablePointer/closethread(from:)``

### Registering metatables

- ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``
- ``Lua/Swift/UnsafeMutablePointer/register(_:)-4rb3q``
- ``Lua/Swift/UnsafeMutablePointer/register(type:usingExistingMetatableFor:)``
- ``Lua/Swift/UnsafeMutablePointer/isMetatableRegistered(for:)``
- ``Lua/Swift/UnsafeMutablePointer/registerMetatable(for:functions:)``
- ``Lua/Swift/UnsafeMutablePointer/registerDefaultMetatable(functions:)``
- ``Lua/Swift/UnsafeMutablePointer/pushMetatable(for:)``

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

- ``Lua/Swift/UnsafeMutablePointer/isnone(_:)``
- ``Lua/Swift/UnsafeMutablePointer/isnil(_:)``
- ``Lua/Swift/UnsafeMutablePointer/isnoneornil(_:)``
- ``Lua/Swift/UnsafeMutablePointer/isinteger(_:)``
- ``Lua/Swift/UnsafeMutablePointer/iscfunction(_:)``
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
- ``Lua/Swift/UnsafeMutablePointer/dostring(_:name:)``
- ``Lua/Swift/UnsafeMutablePointer/dump(strip:)``

### Garbage collection

- ``Lua/Swift/UnsafeMutablePointer/collectgarbage(_:)``
- ``Lua/Swift/UnsafeMutablePointer/collectorRunning()``
- ``Lua/Swift/UnsafeMutablePointer/collectorCount()``
- ``Lua/Swift/UnsafeMutablePointer/collectorStep(_:)``
- ``Lua/Swift/UnsafeMutablePointer/collectorSetIncremental(pause:stepmul:stepsize:)``
- ``Lua/Swift/UnsafeMutablePointer/collectorSetGenerational(minormul:majormul:minorMajorMul:majorMinorMul:)``

### Debugging

- ``Lua/Swift/UnsafeMutablePointer/withStackFrameFor(level:_:)``
- ``Lua/Swift/UnsafeMutablePointer/getStackInfo(level:what:)``
- ``Lua/Swift/UnsafeMutablePointer/getTopFunctionInfo(what:)``
- ``Lua/Swift/UnsafeMutablePointer/getTopFunctionArguments()``
- ``Lua/Swift/UnsafeMutablePointer/getInfo(_:what:)``
- ``Lua/Swift/UnsafeMutablePointer/getWhere(level:)``
- ``Lua/Swift/UnsafeMutablePointer/printStack(from:to:)``

### Upvalues

- ``Lua/Swift/UnsafeMutablePointer/pushUpvalue(index:n:)``
- ``Lua/Swift/UnsafeMutablePointer/getUpvalue(index:n:)``
- ``Lua/Swift/UnsafeMutablePointer/getUpvalues(index:)``
- ``Lua/Swift/UnsafeMutablePointer/findUpvalue(index:name:)``
- ``Lua/Swift/UnsafeMutablePointer/setUpvalue(index:n:)``
- ``Lua/Swift/UnsafeMutablePointer/setUpvalue(index:n:value:)``

### Argument checks

- ``Lua/Swift/UnsafeMutablePointer/argumentError(_:_:)``
- ``Lua/Swift/UnsafeMutablePointer/checkArgument(_:)``
- ``Lua/Swift/UnsafeMutablePointer/checkArgument(_:type:)``
- ``Lua/Swift/UnsafeMutablePointer/checkOption(_:default:)``

### String matching

- ``Lua/Swift/UnsafeMutablePointer/match(string:pattern:pos:)``
- ``Lua/Swift/UnsafeMutablePointer/matchString(string:pattern:pos:)``
- ``Lua/Swift/UnsafeMutablePointer/matchStrings(string:pattern:pos:)-5g0g4``
- ``Lua/Swift/UnsafeMutablePointer/matchStrings(string:pattern:pos:)-6arli``
- ``Lua/Swift/UnsafeMutablePointer/matchStrings(string:pattern:pos:)-4dggs``
- ``Lua/Swift/UnsafeMutablePointer/gsub(string:pattern:repl:maxReplacements:)-4q8in``
- ``Lua/Swift/UnsafeMutablePointer/gsub(string:pattern:repl:maxReplacements:)-sg1t``
- ``Lua/Swift/UnsafeMutablePointer/gsub(string:pattern:repl:maxReplacements:)-4tcdv``

### Miscellaneous

- ``Lua/Swift/UnsafeMutablePointer/requiref(name:function:global:)``
- ``Lua/Swift/UnsafeMutablePointer/requiref(name:global:closure:)``
- ``Lua/Swift/UnsafeMutablePointer/setfuncs(_:nup:)``
- ``Lua/Swift/UnsafeMutablePointer/error(_:)-swift.type.method``
- ``Lua/Swift/UnsafeMutablePointer/error(_:)-swift.method``
- ``Lua/Swift/UnsafeMutablePointer/setErrorConverter(_:)``
- ``Lua/Swift/UnsafeMutablePointer/ref(index:)``
- ``Lua/Swift/UnsafeMutablePointer/ref(any:)``
- ``Lua/Swift/UnsafeMutablePointer/popref()``
- ``Lua/Swift/UnsafeMutablePointer/globals``
- ``Lua/Swift/UnsafeMutablePointer/getMainThread()``
- ``Lua/Swift/UnsafeMutablePointer/rawlen(_:)``
- ``Lua/Swift/UnsafeMutablePointer/len(_:)``
- ``Lua/Swift/UnsafeMutablePointer/withBuffer(_:)``
- ``Lua/Swift/UnsafeMutablePointer/arith(_:)``
