# ``Metaobject``

Define a type object capable of constructing bridged Swift objects.

When using Lua in an object-oriented fashion there is usually a single value representing the type of a given object. This value is frequently also the metatable of objects of that type, and may have its own metatable with a `__call` metamethod which can be used to construct objects of that type. For example this would be one (minimal) way to achieve this, for a pure Lua type:

```lua
MyLuaType = setmetatable({}, { __call = function() return setmetatable({}, MyLuaType) end })
MyLuaType.__index = MyLuaType

function MyLuaType:memberfn()
    -- ...
end

function MyLuaType.staticfn()
    -- ...
end

local myobj = MyLuaType(...)
myobj:memberfn() -- etc
```

The `Metaobject` struct exists to allow a value that behaves similarly to `MyLuaType` above, but for a bridged Swift type (see <doc:BridgingSwiftToLua>). It is a distinct type, and not just part of the functionality of `Metatable`, to allow flexibility in how (or whether) bridged Swift values can be constructed from Lua. By default it exposes all static functions and properties from the `Metatable`, as well as optionally defining a constructor to permit instances of the type to be constructed from Lua.

The `Metaobject` is `Pushable` so that once defined, it can simply be pushed (or assigned to a global using `setglobal` etc) to define the Lua-side object however and wherever is required. Unlike with `Metatable` there is no restriction on how many `Metaobject` instances that can be defined for a given type, although using more than one might make for a confusing API.


As a simple example, this is one way to define a `MySwiftType` object in Lua which behaves similarly to the `MyLuaType` example above, except that it creates bridged Swift `MySwiftType` instances.

```swift
struct MySwiftType {
    let val: String
}
L.register(Metatable<MySwiftType>(fields: ["val": .property(\.val)]))

let typeObj = Metaobject<MySwiftType>(constructor: { return MySwiftType(val: $0) })
L.setglobal(name: "MySwiftType", value: typeObj)
```

The above has defined a Lua global called "MySwiftType" which can be used to create bridged `MySwiftType` instances, for example:

```lua
local foo = MySwiftType("someval")
print(foo.val) -- Prints "someval"
-- foo is a userdata that contains a Swift `MySwiftType` struct, just the same as if
-- `L.push(userdata: MySwiftType(val: "someval"))` had been called from Swift.
```

> Note: The value that is pushed to represent the `Metaobject<T>` is a `table`, not a `userdata` and does not bear any
relation to the metatable used to bridge objects of type `T`. So, for example, you cannot add to the metatable of
`T` userdatas by modifying the metaobject table after it has been created.

## Properties from the metatable

Any static properties or functions defined in the `Metatable` for `T` are also available on the metaobject,
providing they were declared in the metatable using `.const`, `.staticvar` or `.staticfn`. For example:

```swift
struct Foo {
    static func hello() -> String { return "World" }
}
L.register(Metatable<Foo>(fields: ["hello": .staticfn { Foo.hello() }])

L.setglobal(name: "Foo", value: Metaobject<Foo>())
try L.dostring("print(Foo.hello())") // prints "World"
```

Fields can be added to the metaobject (in addition to those from the `Metatable`) by providing a `fields:` argument
to the constructor, using values of type [`StaticFieldType`](doc:Metaobject/StaticFieldType) in a similar way to
how fields are specified in a metatable. For example:

```swift
struct Foo { /*...*/ }
L.register(Metatable<Foo>(fields: [/*...*/])
let metaobj = Metaobject<Foo>(fields: [
    "hello": .staticfn { return "world" }
])
L.setglobal(name: "Foo", value: metaobj)
```

Equally fields from the metatable can be _removed_ from the metaobject by specifying the value `.none` in the `fields:` argument:

```swift
struct Foo {
    static func hello() -> String { return "World" }
}
L.register(Metatable<Foo>(fields: ["hello": .staticfn { Foo.hello() }])
let metaobj = Metaobject<Foo>(fields: [
    "hello": .none
])

L.setglobal(name: "Foo", value: metaobj)
try L.dostring("print(Foo.hello())") // will throw an error because there is no hello() function
```


## Specifying a metatable

The `Metaobject` constructor has an optional `metatable` parameter. If this is not specified, the `Metatable` for `T` must be registered prior to the `Metaobject` being pushed. This can simplify the code if there is an explicit call to `register()` which guarantees the type is registered. If the project is structured such that there isn't, however, the metatable can be passed in to the `Metaobject` constructor instead. This can be more convenient if it not guaranteed if/when the type is registered. Note that there are explicit constructor overloads for when `T` conforms to `PushableWithMetatable`, meaning you do not have to worry about this restriction when using `PushableWithMetatable`. For example:

```swift
struct Foo: PushableWithMetatable {
    static let hello = "world"
    static var metatable: Metatable<Foo> {
        Metatable(fields: ["hello": .staticvar { Foo.hello }])
    }
}

// This is fine because Foo is a PushableWithMetatable
L.setglobal(name: "Foo", value: Metaobject<Foo>())

struct Bar { // not conforming to PushableWithMetatable
    static let hello = "world"
    static var metatable: Metatable<Bar> {
        Metatable(fields: ["hello": .staticvar { Bar.hello }])
    }
}

L.setglobal(name: "Bar", value: Metaobject<Bar>()) // BAD!
// The above line is NOT fine. Need to do one of three things, either:
// (1) Call L.register(Bar.metatable) first, or
// (2) Use the constructor Metaobject<Bar>(metatable: Bar.metatable, ...), or
// (3) Make Bar conform to PushableWithMetatable.
```
