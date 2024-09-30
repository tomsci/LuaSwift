# ``Lua/LuaClosure``

The LuaSwift equivalent of `lua_CFunction`.

## Overview

This type represents Swift closures that behave like the C [`lua_CFunction`](https://www.lua.org/manual/5.4/manual.html#lua_CFunction) type. Arguments to the closure are expected to be pushed on to the Lua stack, and results are returned by pushing them on to the stack and returning the number of result values pushed.

Closures or functions of this type can be pushed on to the Lua stack as Lua functions (like `lua_CFunction`) using ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)``, but additionally they are allowed to throw Swift Errors (unlike `lua_CFunction`), which will be translated to Lua errors according to ``Lua/Swift/UnsafeMutablePointer/push(error:toindex:)``. Also unlike `lua_CFunction`, closures of type `LuaClosure` are allowed to capture variables.

Normally `lua_CFunctions` are allowed to error using `lua_error()`, but `lua_CFunctions` implemented in Swift are not, because it is a violation of the Swift runtime to longjmp across a C-Swift boundary. Where a `lua_CFunction` written in C might do this:

```c
int myErroringFn(lua_State *L) {
    if (/*doom*/) {
        // This is OK to do in C, but not in Swift!
        return luaL_error(L, "Something bad happened");
    }
    return 0;
}
// ...
lua_pushcfunction(L, myErroringFn);
```

The equivalent in Swift using a `LuaClosure` would be:

```swift
func myErroringFn(L: LuaState) throws -> CInt {
    if /*doom*/ {
        throw L.error("Something bad happened")
    }
    return 0
}
// ...
L.push(myErroringFn)
```

or

```swift
L.push({ L in
    if /*doom*/ {
        throw L.error("Something bad happened")
    }
    return 0
})
```

The way this is implemented is that the function responsible for pushing `LuaClosure`, ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)``, actually pushes a wrapper function which is responsible for calling the `LuaClosure`, catching any errors and translating them to Lua errors. Part of this support is provided by the `LuaClosureWrapper` class, although that is an implementation detail. The `type()` of a pushed `LuaClosure` is always `function`, not `userdata`. Similarly the ``Lua/Swift/UnsafeMutablePointer/iscfunction(_:)`` API returns `true` for a `LuaClosure` regardless of it being in Swift rather than C.

## See Also

- ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)``
- ``Lua/Swift/UnsafeMutablePointer/error(_:)-swift.method``
- ``LuaClosureWrapper``
