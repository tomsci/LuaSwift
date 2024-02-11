# ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``

Register a metatable for values of type `T`.

Register a metatable for values of type `T` for when they are pushed using ``push(userdata:toindex:)`` or  ``push(any:toindex:)``. A metatable represents how the type should behave when bridged into Lua, and is represented by a ``Metatable`` object.

Example usage:

```swift
// Assuming a type like this
class Foo {
    var prop = "example"

    public func bar() {
        print("bar() was called!")
    }
}

L.register(Metatable<Foo>(fields: [
    "prop": .property { $0.prop },
    "bar": .memberfn { $0.bar() }
))
```

See <doc:BridgingSwiftToLua> for background on how metatables are used.

> Note: Attempting to register a metatable for types that are normally automatically converted to Lua types (such as `Int,` or `String`), is not recommended and will lead to confusing results.

All metatables are stored in the Lua registry using a key starting with `"LuaSwift_"`, to avoid conflicting with any other uses of [`luaL_newmetatable()`](https://www.lua.org/manual/5.4/manual.html#luaL_newmetatable). The exact name used is an internal implementation detail.

- Parameter metatable: The metatable to register.
- Precondition: There must not already be a metatable defined for type `T`.
