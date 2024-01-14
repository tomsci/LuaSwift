# ``Lua/LuaPcallContinuation``

The LuaSwift equivalent of `lua_KFunction` when used in a `lua_pcallk()` call.

## Overview

This type represents Swift closures that can be used as the `continuation` argument in `pcallk()` calls, similarly to how the C [`lua_KFunction`](https://www.lua.org/manual/5.4/manual.html#lua_KFunction) type is used by `lua_pcallk()`. See ``Lua/Swift/UnsafeMutablePointer/pcallk(nargs:nret:traceback:continuation:)`` for more information. As in C, the stack on entry to a continuation will contain whatever was on it at the time of the `pcallk()` call (minus the function and `nargs` arguments) plus `nret` results from the call. Errors and results are returned in the same way as in ``LuaClosure``. If the call errors, the continuation is not called.

The second argument to the closure is a status variable of type ``LuaPcallContinuationStatus`` which indicates whether the call yielded, errored, or completed without either of those things occurring.

The `LuaPcallContinuation` type is normally used directly as the `continuation` argument to a `pcallk()` call:

```swift
let my_closure: LuaClosure = { L in
    /* ... */
    return try L.pcallk(nargs: nargs, nret: nret, continuation: { L, status in
        /* Do things after the pcallk... */
        return 0
    })
}
```

## See Also

- ``Lua/Swift/UnsafeMutablePointer/pcallk(nargs:nret:traceback:continuation:)``
- ``LuaClosure``
- ``LuaCallContinuation``
