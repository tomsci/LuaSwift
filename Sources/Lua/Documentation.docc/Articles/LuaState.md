# LuaState

## Overview

`LuaState` is the primary way of accessing the Lua APIs. It is technically a typealias to `UnsafeMutablePointer<lua_State>`, which is then extended to provide the Swift-friendly type-safe APIs described below.

It can therefore be constructed either using the explicit constructor provided, or any C `lua_State` obtained from anywhere can be treated as a `LuaState` Swift object. By convention `LuaState`/`lua_State` variables are often called `L`, although that is not mandatory.

```swift
let L = LuaState(libraries: .all)
L.push(1234)
assert(L.toint(-1)! == 1234)
L.close()
```

Note that `LuaState` pointers are _not_ reference counted, meaning the state is not automatically destroyed when it goes out of scope. You must call ``Lua/Swift/UnsafeMutablePointer/close()``.

## Topics

### State management

- ``Lua/Swift/UnsafeMutablePointer/init(libraries:)``
- ``Lua/Swift/UnsafeMutablePointer/close()``
- ``Lua/Swift/UnsafeMutablePointer/setRequireRoot(_:displayPath:)``
- ``Lua/Swift/UnsafeMutablePointer/addModules(_:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/setModules(_:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/getDefaultStringEncoding()``
- ``Lua/Swift/UnsafeMutablePointer/setDefaultStringEncoding(_:)``

### Basic stack functionality

- ``Lua/Swift/UnsafeMutablePointer/type(_:)``
- ``Lua/Swift/UnsafeMutablePointer/isnone(_:)``
- ``Lua/Swift/UnsafeMutablePointer/isnoneornil(_:)``
- ``Lua/Swift/UnsafeMutablePointer/pop(_:)``
- ``Lua/Swift/UnsafeMutablePointer/gettop()``
- ``Lua/Swift/UnsafeMutablePointer/settop(_:)``
- ``Lua/Swift/UnsafeMutablePointer/checkstack(_:)``

### to...() functions

- ``Lua/Swift/UnsafeMutablePointer/toboolean(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tointeger(_:)``
- ``Lua/Swift/UnsafeMutablePointer/toint(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tonumber(_:)``
- ``Lua/Swift/UnsafeMutablePointer/todata(_:)``
- ``Lua/Swift/UnsafeMutablePointer/tostringUtf8(_:convert:)``
- ``Lua/Swift/UnsafeMutablePointer/tostring(_:encoding:convert:)-4dzgb``
- ``Lua/Swift/UnsafeMutablePointer/tostring(_:encoding:convert:)-6oudd``
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
- ``Lua/Swift/UnsafeMutablePointer/push(string:encoding:)-6qhde``
- ``Lua/Swift/UnsafeMutablePointer/push(_:)-3o5nr``
- ``Lua/Swift/UnsafeMutablePointer/push(bytes:)``
- ``Lua/Swift/UnsafeMutablePointer/push(_:)-63v7u``
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

### Loading code

- ``Lua/Swift/UnsafeMutablePointer/load(file:displayPath:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(data:name:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(bytes:name:mode:)``
- ``Lua/Swift/UnsafeMutablePointer/load(string:name:)``
- ``Lua/Swift/UnsafeMutablePointer/dofile(_:mode:)``

### Other

- ``Lua/Swift/UnsafeMutablePointer/requiref(name:function:global:)``
- ``Lua/Swift/UnsafeMutablePointer/requiref(name:global:closure:)``
- ``Lua/Swift/UnsafeMutablePointer/setfuncs(_:nup:)``
- ``Lua/Swift/UnsafeMutablePointer/convertThrowToError(_:)``
- ``Lua/Swift/UnsafeMutablePointer/lua_error()``
- ``Lua/Swift/UnsafeMutablePointer/error(_:)``
- ``Lua/Swift/UnsafeMutablePointer/ref(index:)``
- ``Lua/Swift/UnsafeMutablePointer/ref(any:)``
- ``Lua/Swift/UnsafeMutablePointer/popref()``
- ``Lua/Swift/UnsafeMutablePointer/globals``
- ``Lua/Swift/UnsafeMutablePointer/rawlen(_:)``
- ``Lua/Swift/UnsafeMutablePointer/len(_:)``
- ``Lua/Swift/UnsafeMutablePointer/rawequal(_:_:)``
