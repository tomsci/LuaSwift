# ``Lua/Pushable``

Protocol adopted by any Swift type that can unambiguously be converted to a basic Lua type.

## Overview

Any type which conforms to `Pushable` (either due to an extension provided by the `Lua` module, or by an implementation from anywhere else) can be pushed onto the Lua stack using ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9``. Several functions have convenience overloads allowing `Pushable` values to be passed in directly, shortcutting the need to push them onto the stack then refer to them by stack index, such as ``Lua/Swift/UnsafeMutablePointer/setglobal(name:value:)``.

Most basic data types, such as `String`, `Int`, `Bool`, `Array` and `Dictionary` are `Pushable`. In the case of `Array` and `Dictionary`, they are `Pushable` only if their element types are. It is an error to treat a `String` as `Pushable` if it is not valid in the default string encoding, see ``Lua/Swift/UnsafeMutablePointer/getDefaultStringEncoding()``.

For example:

```swift
let L = LuaState(libraries: .all)
L.push(1234) // Integer is Pushable
L.push(["abc", "def"]) // String is Pushable, therefore Array<String> is too
L.setglobal(name: "foo", value: "bar") // Assigns the Pushable "bar" to the global named "foo"
```

Note that `[UInt8]` does not conform to `Pushable` because there is ambiguity as to whether that should be represented as an array of integers or as a string of bytes, and because of that `UInt8` cannot conform either. Types should only conform to `Pushable` if there is a clear and _unambiguous_ representation in Lua -- if a type needs to be represented in different ways depending on circumstances (and not simply based on its type or value), then it should not conform to `Pushable`.

For the types which cannot conform to Pushable -- either because their representation in Lua is ambiguous, like `[UInt8]`, or because they cannot adopt Protocols, such as `lua_CFunction` or `LuaClosure` -- `LuaState` provides a custom overload of `push()` instead, for example ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-171ku`` or ``Lua/Swift/UnsafeMutablePointer/push(function:toindex:)``. For such types the "all-in-one" overloads which take a `Pushable` cannot be used, and instead they must be first pushed using the appropriate overload of `push()`, and then used via a function which takes a value from the stack:

```swift
let L = LuaState(libraries: .all)
// Push first...
L.push(function: { L in
    print("Hello!")
    return 0
}
// ...then use an overload that pops a value from the stack instead of
// taking a Pushable argument.
L.setglobal(name: "hellofn")
```
