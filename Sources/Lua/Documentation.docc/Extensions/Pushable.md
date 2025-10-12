# ``Lua/Pushable``

Protocol adopted by any Swift type that can unambiguously be converted to a Lua type.

## Overview

Any type which conforms to `Pushable` (either due to an extension provided by the `Lua` module, or by an implementation from anywhere else) can be pushed on to the Lua stack using ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9``. Several functions have convenience overloads allowing `Pushable` values to be passed in directly, shortcutting the need to push them on to the stack then refer to them by stack index, such as ``Lua/Swift/UnsafeMutablePointer/setglobal(name:value:)``.

Most basic data types, such as `String`, `Int`, `Bool`, `Array` and `Dictionary` are `Pushable`, and convert to the expected Lua types `string`, `number`, `boolean`, and `table` respectively. `Array` and `Dictionary` are both represented as `table`, meaning `tovalue()` has additional logic to disambiguate when converting the other way. In the case of `Array` and `Dictionary`, they are `Pushable` only if their element types are. It is an error to treat a `String` as `Pushable` if it is not valid in the default string encoding, see ``Lua/Swift/UnsafeMutablePointer/getDefaultStringEncoding()``, although since the default string encoding is UTF-8, by default all `Strings` will be representable.

For example:

```swift
// Integer is Pushable
L.push(1234)

// String is Pushable, therefore Array<String> is too
L.push(["abc", "def"])

// Assigns the Pushable "bar" to the global named "foo"
L.setglobal(name: "foo", value: "bar")
```

Note that `[UInt8]` does not conform to `Pushable` because there is ambiguity as to whether that should be represented as an array of integers or as a string of bytes, and because of that `UInt8` cannot conform either. Types should only conform to `Pushable` if there is a clear and _unambiguous_ representation in Lua -- if a type needs to be represented in different ways depending on circumstances (and not simply based on its type or value), then it should not conform to `Pushable`. Similarly `UInt64` is also not `Pushable`, because it can represent numbers larger than the Lua integral number type and thus there is ambiguity - should it wrap, assert, promote to float, etc. The "unambiguous" requirement is not enforced by the compiler; it is the programmer's responsibility to provide declarations that are internally consistent. Perhaps surprisingly, `LuaState` is itself `Pushable`: this is because `LuaState` is also used to represent Lua threads (coroutines).

For types like `LuaClosure` and `lua_CFunction` which conceptually should be pushable but the Swift type system does not permit to conform to `Pushable`, the helper functions ``function(_:)`` and ``closure(_:)`` can be used anywhere a `Pushable` is expected, allowing code like:

```swift
L.setglobal(name: "foo", value: .function { L in
    print("This is a lua_CFunction used as a Pushable!")
    return 0
})
```

Similarly ``nilValue`` can be used to push `nil` as if it were a `Pushable`:

```swift
L.setglobal(name: "foo", value: .nilValue)
```

There is also a ``data(_:)`` helper to treat `[UInt8]` as a string of bytes.

The alternative to using one of the helper functions for non-Pushable types is to use the appropriate overload of `push()` instead, for example ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-171ku`` or ``Lua/Swift/UnsafeMutablePointer/push(function:toindex:)``, then to use them via a function which takes a value from the stack:

```swift
// Push first...
L.push(function: { L in
    print("Hello!")
    return 0
}
// ...then use an overload that pops a value from the stack instead of
// taking a Pushable argument.
L.setglobal(name: "hellofn")
```

> Note: While `Pushable` requires that the type have an unambiguous representation in Lua in order to conform, it makes no requirement the other way -- which is to say, there may or may not be a way to map a Lua value back to a particular instance of the `Pushable` type, and `Pushable` imposes no requirements either way. It is up to the programmer to decide what is appropriate for any given type.
