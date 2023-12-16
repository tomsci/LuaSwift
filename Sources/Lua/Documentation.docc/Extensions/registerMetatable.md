# ``Lua/Swift/UnsafeMutablePointer/registerMetatable(for:fields:metafields:)``

Register a metatable for values of type `T`.

Register a metatable for values of type `T` for when they are pushed using ``push(userdata:toindex:)`` or  ``push(any:toindex:)``. A metatable represents how the type should behave when bridged into Lua, and is split into two parts, represented by the `fields` and `metafields` arguments.

`fields` defines all the properties and functions that the value should have in Lua. It is a dictionary of names to some form of closure, depending on the field type. It is a convenience alternative to specifying an explicit `.index` metafield (see below) using type inference on the closure to avoid some of the type conversion boilerplate that would otherwise have to be written. Various helper functions are defined by ``UserdataField`` for different types of field.

`metafields` defines any custom metafields that should be added to the metatable, in addition to what's required by `fields` if it is specified. The metafields that can be defined are given by ``MetafieldName`` and their definitions use one of the values of ``MetafieldValue``. Frequently `fields` is sufficient to define how the type should be bridged, and `metafields:` can be omitted.

Example usage:

```swift
// Assuming a type like this
class Foo {
    var prop = "example"

    public func bar() {
        print("bar() was called!")
    }
}

L.registerMetatable(for: Foo.self, fields: [
    "prop": .property { $0.prop },
    "bar": .memberfn { $0.bar() }
])
```

See <doc:BridgingSwiftToLua#Defining-a-metatable> for a detailed discussion of how to use this API.

> Note: attempting to register a metatable for types that are normally automatically converted to Lua types (such as `Int,` or `String`), is not recommended and will lead to confusing results.

All metatables are stored in the Lua registry using a key starting with `"LuaSwift_"`, to avoid conflicting with any other uses of [`luaL_newmetatable()`](https://www.lua.org/manual/5.4/manual.html#luaL_newmetatable). The exact name used is an internal implementation detail.

- Parameter type: Type to register.
- Parameter fields: dictionary of fields.
- Parameter metafields: dictionary of metafields.
- Precondition: There must not already be a metatable defined for type `T`.
