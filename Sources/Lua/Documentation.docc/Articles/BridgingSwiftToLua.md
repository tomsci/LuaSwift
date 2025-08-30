# Bridging a Swift object into Lua

## Overview

Any Swift type can be made accessible from Lua. The process of defining what fields, methods etc should be exposed is referred to as "bridging". There are two parts to the process: firstly, defining the Lua _metatable_ for the type; and secondly, making specific value(s) of that type available to the Lua runtime, which is often referred to as "pushing" due to the first step always being to push the value on to the Lua stack. Each of these parts are covered below; before that is a brief description of how bridging is implemented.

### Bridging implementation

Basic Swift types are pushed by value -- that is to say they are copied and converted to the equivalent Lua type. A Swift `String` is made available to Lua by converting it to a Lua `string`, a Swift `Array` is converted to a Lua `table`, etc.

Bridged values on the other hand are represented in Lua using the `userdata` Lua type, which from the Swift side behave as if there was an assignment like `var userdataVar: T? = myval` (where `T` is the type used in the `Metatable`, described below). So for classes, the `userdata` holds an additional reference to the object, and for structs the `userdata` holds a value copy of it. A `__gc` metamethod is automatically generated, which means that when the `userdata` is garbage collected by Lua, the equivalent of `userdataVar = nil` is performed.

> Note: While defining metatables for `struct` types is supported, all userdata in Lua are copy-by-reference, so the object will behave more like a class from the Lua side. Overall, `class` types can be a better fit for how the bridging logic behaves.

As described so far, the `userdata` plays nicely with Lua and Swift object lifetimes and memory management, but does not allow you to do anything useful with it from Lua other than controlling when it goes out of scope. This is where defining a metatable comes in.

## Defining a metatable

A metatable is how you define what Swift properties and methods are accessible or callable from Lua. More information about what metatables are is available [in the Lua manual](https://www.lua.org/manual/5.4/manual.html#2.4). You must define a metatable for each type you intend to bridge into Lua - the Swift runtime is not dynamic enough to do much of this automatically. The way you do this is by making a call to ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn`` passing in a ``Metatable`` object describing the Swift type in question, the fields you want to make visible in Lua, and any custom metamethods you want to define.

For example, supposing we have a class called `Foo`, and we want to be able to make instances of this class available to Lua so that Lua code can call the `bar()` method:

```swift
class Foo {
    var prop = "example"

    func bar() -> Bool {
        print("bar() was called!")
        return true
    }
}

// We want to be able to call `foo:bar()` in Lua
```

We need to therefore call `register()` with a `Metatable` whose `fields` containing a ``Metatable/FieldType/closure(_:)`` called `bar` (which will become the Lua `bar()` member function) which calls the Swift `bar()` function. Here we are assuming the Lua API should be a member function called as `foo:bar()`, therefore the `Foo` userdata will be argument 1. We recover the original Swift `Foo` instance by calling ``Lua/Swift/UnsafeMutablePointer/checkArgument(_:)``.

Since we are not making any customizations to the metatable (other than to add fields) we can omit all the other arguments to the `Metatable` constructor.

```swift
L.register(Metatable<Foo>(fields: [
    "bar": .closure { L in
        // (1) Convert our Lua arguments back to Swift values...
        let foo: Foo = try L.checkArgument(1)
  
        // ... (2) make the call into Swift ...
        let result = foo.bar()
  
        // ... (3) and return any results
        L.push(result)
        return 1
    }
]))
```

All fields (and metafields) can be defined using `.function { ... }` or `.closure { ... }` (using a ``lua_CFunction`` or ``LuaClosure`` respectively), but this can require quite bit of boilerplate, for example steps (1) and (3) in the definition of `"bar"` above. This can be avoided in common cases by using a more-convenient-but-less-flexible helper like [`.memberfn { ... }`](doc:Metatable/FieldType/memberfn(_:)-8clk) instead of [`.closure { ... }`](doc:Metatable/FieldType/closure(_:)), which uses type inference to generate suitable boilerplate. `memberfn` can handle most argument and return types (including returning multiple values) providing they can be used with `tovalue()` and `push(tuple:)`. The following much more concise code behaves identically to the previous example:

```swift
L.register(Metatable<Foo>(fields: [
    "bar": .memberfn { $0.bar() }
]))
```

Here we're using Swift shortcuts and type inference to save having to specify explicit parameter names, types and return types. It could equivalently be written in a more verbose fashion:

```swift
L.register(Metatable<Foo>(fields: [
    "bar": .memberfn { (obj: Foo) -> Bool in
        return obj.bar()
    }
]))
```

Any arguments to the closure are type-checked using using `L.checkArgument<ArgumentType>()`. Anything which exceeds the type inference abilities of `memberfn` can always be written explicitly using `closure`. The full list of helpers that can be used to define fields is defined in ``Metatable/FieldType``. Note there are multiple overloads of `memberfn` to accommodate different numbers of arguments.

## Pushing values into Lua

Having defined a metatable for our type, we can use [`push(userdata:)`](doc:Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)) or [`push(any:)`](doc:Lua/Swift/UnsafeMutablePointer/push(any:toindex:)) to push instances of it on to the Lua stack, at which point we can assign it to a variable just like any other Lua value. Using the example `Foo` class described above, and assuming our Lua code expects a single global value called `foo` to be defined, we could use ``Lua/Swift/UnsafeMutablePointer/setglobal(name:)``:

```swift
let foo = Foo()
L.push(userdata: foo)
L.setglobal(name: "foo")
```

This could be simplified by using ``Lua/Swift/UnsafeMutablePointer/setglobal(name:value:)`` which takes a `value`, combined with the Pushable helper function ``Pushable/userdata(_:)``:

```swift
L.setglobal(name: "foo", value: .userdata(Foo()))
```

Either way, there is now a global value in Lua called `foo` which has a `bar()` method that can be called on it:

```lua
foo:bar()
-- Above call results in "bar() was called!" being printed
```

To simplify pushing even further, `Foo` could be made directly ``Pushable``, for example via an extension:

```swift
extension Foo: Pushable {
    public func push(onto L: LuaState) {
        L.push(userdata: self)
    }
}

// ...

L.setglobal(name: "foo", value: Foo())
```

## More advanced metatables

### Properties

The examples used above defined only a very simple metatable which bridged a single member function. One obvious addition would be to bridge properties, as well as functions. This can be done in a similar way to `memberfn`, by using [`.property { ... }`](doc:Metatable/FieldType/property(get:set:)). Here is an example which exposes both `Foo.bar()` and `Foo.prop`:

```swift
L.register(Metatable<Foo>(fields: [
    "bar": .memberfn { $0.bar() },
    "prop": .property { $0.prop },
]))
```

`property` may also be used to define read-write properties, by specifying both `get:` and `set:`:

```swift
L.register(Metatable<Foo>(fields: [
    "prop": .property(get: { $0.prop }, set: { $0.prop = $1 }),
]))
```

Assuming `setglobal` was called as in the above example, there is now a `foo` global with a `prop` member:

```lua
print(foo.prop)
--> Prints "example"
```

Instead of specifying get/set closures, the above can also be expressed using Swift key paths:

```swift
L.register(Metatable<Foo>(fields: [
    "prop": .property(\.prop)
]))
```

By default `.property` will make a read-write property if the key path refers to a writable ("var") property, using [`property(_: WritableKeyPath)`](doc:Metatable/FieldType/property(_:)-6z9uc) and a read-only property otherwise, using [`property(_: KeyPath)`](doc:Metatable/FieldType/property(_:)-7zd5t). [`.roproperty`](doc:Metatable/FieldType/roproperty(_:)) and [`.rwproperty`](doc:Metatable/FieldType/rwproperty(_:)) can be used instead, to explicitly specify whether the property should be read-only or read-write.

### Custom metamethods

To customize the bridging above and beyond adding fields to the userdata, we can pass in custom metafields. For example, to make `Foo` callable and closable (see [to-be-closed variables](https://www.lua.org/manual/5.4/manual.html#3.3.8)), we'd add `call` and `close` arguments to the `Metatable` constructor:

```swift
L.register(Metatable<Foo>(
    call: .memberfn { obj in
        print("I have no idea what this should do")
    },
    close: .memberfn { obj in
        // Do whatever is appropriate to obj here,
        // eg calling a close() function.
    }
))
```

Note that `memberfn` may be used in some metamethods such as `call` (see [`CallType.memberfn`](doc:Metatable/CallType/memberfn(_:)-11bo5)) and `close` (see [`CloseType.memberfn`](doc:Metatable/CloseType/memberfn(_:))), just as in `fields`. Note that because those two metafields have slightly different call semantics, there is a different `memberfn` definition for each of them -- there are multiple `memberfn` overloads for `call` to support passing additional arguments, whereas there aren't for `close` because the `close` metamethod never takes any arguments. `memberfn` is not available for metamethods like `add` because Lua does not guarantee that the the first argument to that metamethod is of type `Foo` (only that _one_ of the two arguments will be).

Under the hood, the implementation of support for `fields` uses a synthesized `index` metafield, therefore if `fields` is non-nil then `index` must be nil or omitted. `newindex` behaves similarly if there are any read-write properties defined in `fields`.

Explicitly providing a `index` metafield using `.closure` is the most flexible option, but means we must handle all functions, properties and type conversions manually. The following would be one way to define such a metafield for the example `Foo` class defined earlier (omitting the `call` and `close` definitions):

```swift
L.register(Metatable<Foo>(
    index: .closure { L in
        let foo: Foo = try L.checkArgument(1)
        let memberName: String = try L.checkArgument(2)
        switch memberName {
        case "bar":
            // Simplifying, given there are no arguments or results
            // to worry about
            L.push(closure: { foo.bar() })
        case "prop":
            L.push(foo.prop)
        default:
            L.pushnil()
        }
        return 1
    },
    newindex: .closure { L in
        let foo: Foo = try L.checkArgument(1)
        let memberName: String = try L.checkArgument(2)
        switch memberName {
        case "prop":
            foo.prop = L.checkArgument(3)
        default:
            throw L.argumentError(2,
                "no set function defined for property \(memberName)")
        }
        return 0
    }
))
```

Since `index` and `newindex` both support `.memberfn` the above can be simplified slightly if desired (for `newindex` the new value is the third argument passed to the closure, and is represented as a ``LuaValue``):

```swift
L.register(Metatable<Foo>(
    index: .memberfn { obj, memberName in
        switch memberName {
        case "bar":
            return { obj.bar() }
        case "prop":
            return obj.prop
        default:
            return nil
        }
    },
    newindex: .memberfn { obj, memberName, newVal in
        switch memberName {
        case "prop":
            guard let stringVal = newVal.tostring() else {
                throw LuaState.error("Bad arg to newindex")
            }
            obj.prop = stringVal
        default:
            throw LuaState.error(
                "no set function defined for property \(memberName)")
        }
    }
))
```

For this simple example, the explicit `index` metafield may look simpler than using `fields` and the synthesized `index`. When there are many functions with many argument types to convert, `fields` and `.memberfn`/`.staticfn` may be preferable.

The examples throughout this article lean heavily on Swift's convenience syntax for conciseness. For example the following two calls are equivalent:

```swift
L.register(Metatable<Foo>(fields: [
    "prop": .property { $0.prop }
]))

// is the same as:
L.register(Metatable<Foo>(fields: [
    "prop": Metatable<Foo>.FieldType.property(get:
        { (obj: Foo) -> String in
            return obj.prop
        }, set: nil)
]))
```

### Member and non-member functions

There are two ways to define convenience function bindings in `fields`: using `.memberfn` and using `.staticfn`. Both accept a variable number of arguments and automatically perform type conversion on them. The difference is how they are expected to be called from Lua and what the first closure argument is bound to as a result.

`.memberfn` is for Lua functions which will be called using member function syntax, `value:fnname()` where the `foo` object is (under the hood) passed in as the first argument. The first argument (ie `$0`) is always bound to the `Foo` instance (or whatever type we're defining the metatable for).

`.staticfn` is for non-member functions, called with `value.fnname()`, where the object is _not_ the first argument. In the `staticfn` closure, `$0` is not bound to the `Foo` instance, and is instead just the first argument passed to the Lua function, if any. For example:

```swift
class Foo {
    static func baz(_: Bool) {
        // Do whatever
    }
    // .. rest of definition as before
}

L.register(Metatable<Foo>(fields: [
    "baz": .staticfn { Foo.baz($0) },
]))

// Means we can do foo.baz(true) in Lua
```

If you want the Lua code to be callable without using member syntax, but for those functions to be able to call `Foo` member functions, you must define the `index` metafield explicitly rather than using `fields:`, so that you can recover the `foo` instance from the first index argument instead (as the example `index` implementation above does).

## Default metatables

In addition to defining metatables for individual types, you can define a default metatable using [`register(DefaultMetatable(...))`](doc:Lua/Swift/UnsafeMutablePointer/register(_:)-4rb3q) which is used as a fallback for any type that has not had a separate `Metatable` registered for it. This is useful in situations where many related-but-distinct types of value may be pushed and it is easier to provide a single implementation of eg the `index` metamethod and introspect the value there, than it is to call `register()` with every single type.

Because the default metatable is not bound to a specific type, `fields` cannot be configured in the default metatable, nor do any of the metamethods support type-inferencing overloads like `.memberfn`.

## Declarative metatables

The pattern described above using `register(Metatable(...))` and `push(userdata:)` is the most flexible and least intrusive option for bridging objects into Lua, without introducing a dependency on `Lua` into the objects' implementation. There is an alternative option which is for the type itself to declare what its metatable is. This is done by declaring conformance to ``PushableWithMetatable``. Types conforming to `PushableWithMetatable` do not need to call `register()`, and automatically become `Pushable`. See ``PushableWithMetatable`` for more information.

## Registering metatables for structs

While it is permitted to register metatables for structs as well as classes, and bridge them into Lua, the Lua-side `userdata` always has reference (and not value) semantics. That is to say, assigning the `userdata` to a new Lua variable will not copy the struct like it would doing the same operation in Swift.

While pushing a struct always takes a copy (in the same way that assigning it to another Swift variable would), structs bridged into Lua can be modified by their metatable in the same way that classes can be. So, the following example will work:

```swift
struct Foo {
    var str: String

    mutating func setStr(_ newVal: String) {
        str = newVal
    }
}

L.register(Metatable<Foo>(fields: [
    // Both of these definitions are allowed, regardless of
    // whether Foo is a struct or class.
    "str": .property(get: { $0.str }, set: { $0.str = $1 }),
    "setStr": .memberfn { $0.setStr($1) }
]))
```

Note, in LuaSwift v1.0 and earlier, the above `Metatable` definition would cause a compilation error if `Foo` was a struct, because the older versions did not permit struct Metatables to modify the struct.

## Using macros to define metatables

Include the package https://github.com/tomsci/LuaSwiftMacros/ to allow metatables to be autogenerated using Swift macros. See the link for examples.

## See Also

- ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``
- ``Lua/Swift/UnsafeMutablePointer/register(_:)-4rb3q``
- ``Metatable``
- ``DefaultMetatable``
- ``PushableWithMetatable``