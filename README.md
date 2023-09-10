# LuaSwift

A Swift wrapper for the [Lua 5.4](https://www.lua.org/manual/5.4/) C API. All Swift APIs are added as extensions to `UnsafeMutablePointer<lua_State>`, meaning you can freely mix Lua C calls (and callbacks) with higher-level more Swift-like calls. Any Lua APIs without a dedicated `LuaState` wrapper can be accessed by importing `CLua`.

Because this package mostly uses the raw C Lua paradigms (with a thin layer of Swift type-friendly wrappers on top), familiarity with the [Lua C API](https://www.lua.org/manual/5.4/manual.html#4) is strongly recommended. In particular, misusing the Lua stack or the `CLua` API will crash your program.

## Usage

```swift
import Lua

let L = LuaState(libaries: .all)
L.getglobal("print")
try! L.pcall("Hello world!")
L.close()
``` 

Note the above could equally be written using the low-level API, or any mix of the two, for example:

```swift
import Lua
import CLua

let L = luaL_newstate()
luaL_openlibs(L)
// The above two lines are exactly equivalent to `let L = LuaState(libaries: .all)`
lua_getglobal(L, "print") // same as L.getglobal("print")
lua_pushstring(L, "Hello world!")
lua_pcall(L, 1, 0) // Ignoring some error checking here...
lua_close(L)
```

It could also be written using the more object-oriented (but slightly less efficient) `LuaValue`-based API:

```swift
import Lua

let L = LuaState(libaries: .all)
try! L.globals["print"]("Hello world!")
L.close()
```

`LuaState` is a `typealias` to `UnsafeMutablePointer<lua_State>`, which is the Swift bridged equivalent of `lua_State *` in C.

All functions callable from Lua have the type signature [`lua_CFunction`](https://www.lua.org/manual/5.4/manual.html#lua_CFunction), otherwise written `int myFunction(lua_State *L) { ... }`. The Swift equivalent signature is `(LuaState!) -> CInt`. For example:

```swift
import Lua

func myLuaCFunction(_ L: LuaState!) -> CInt {
    print("I am a Swift function callable from Lua!")
    return 0
}
```

## API summary

There are two different ways to use the `LuaState` API - either the stack-based API which will be familiar to Lua C developers, just with stronger typing, and the object-oriented API using `LuaValue`, which behaves more naturally but has much more going on under the hood to make that work, and is also less flexible. The two styles, as well as the raw `CLua` API, can be freely mixed, so you can for example use the higher-level API for convenience where it works, and drop down to the stack-based or raw APIs where necessary.

In both styles of API, the only call primitive that is exposed is `pcall()`. `lua_call()` is not safe to call from Swift (because it can error, bypassing Swift stack unwinding) and thus is not exposed. import `CLua` and call `lua_call()` directly if you really need to. `pcall()` converts Lua errors to Swift ones (of type `LuaCallError`) and thus must always be called with `try`.

### Stack-based API

As in the Lua C API, functions and values are pushed on to the stack with one of the `push(...)` APIs, called using one of the `pcall(...)` overloads, and results are read from the stack using one of the `to...()` APIs.

### Object-oriented API

This API uses a single Swift type `LuaValue` to represent any Lua value (including `nil`). This type supports convenience call and subscript operators. A computed property `globals` allows a convenient way to access the global Lua environment. A `LuaValueError` is thrown if a `LuaValue` is accessed in a way which the underlying Lua value does not support - for example trying to call something which is not callable.

```swift
import Lua
let L = LuaState(libaries: .all)
let printfn = try L.globals["print"] // printfn is a LuaValue...
try printfn("Hello world!") // ... which can be called

try L.globals("wat?") // but this will error because the globals table is not callable.
```

`LuaValue` supports subscript assignment (again providing the underlying Lua value does), although due to limitations in Swift typing you can only do this with `LuaValue`s, to assign any value use `set()` or construct a `LuaValue` with `L.ref(any:)`:

```swift
let g = L.globals
g.set("foo", "bar") // ok
g["baz"] = g["foo"] // ok
g["baz"] = "bat" // BAD: cannot do this
g["baz"] = L.ref(any: "bat") // ok

```

## Bridging Swift objects

Swift structs and classes can be bridged into Lua in a type-safe and reference-counted manner, using Lua's `userdata` and metatable mechanisms. When the bridged Lua object is garbage collected by the Lua runtime, a reference to the Swift value is released.

Each Swift type is assigned a Lua metatable, which defines which members the bridged object has and how to call them. A bridged type with no additional members defined will not be callable from Lua, but retains a reference to the Swift value until it is garbage collected.

The example below defines a metatable for `Foo` which exposes the Swift `Foo.bar()` function by defining a "bar" closure which calls `Foo.bar()`. `tovalue<Foo>()` is used to convert the Lua value back to a Swift `Foo` type. Note that by using the `.closure` type, "bar" is allowed to throw Swift errors which are converted to Lua errors.

```swift
import Lua

class Foo {
    let baz: String
    init(baz: String) {
        self.baz = baz
    }
    func bar() {
        print("Foo.bar() called, baz=\(baz)")
    }
}

let L = LuaState(libraries: [])
L.registerMetatable(for: Foo.self, functions: [
    "bar": .closure { L in
        // Recover the `Foo` instance from the first argument to the function
        guard let foo: Foo = L.tovalue(1) else {
            throw L.error("Bad argument #1 to bar()")
        }
        // Call the function
        foo.bar()
        // Tell Lua that this function returns zero results
        return 0
    }
])
```

Then pass the `Foo` instance to Lua using `push(userdata:)` or `push(any:)`:

```swift
let foo = Foo(baz: "my foo instance")
L.push(userdata: foo)
// Then pcall into Lua, etc
```

From Lua, the userdata object can be called as if it were a Lua object:

```lua
foo:bar()
-- Prints "Foo.bar() called, baz=my foo instance"
```

## `Any` conversions

Any Swift type can be converted to a Lua value by calling `push(any:)` (or any of the convenience functions which use it, such as `pcall(args...)` or `ref(any:)`). Arrays and Dictionaries are converted to Lua tables; Strings are converted to Lua strings using the default string encoding (see `setDefaultStringEncoding()`); numbers, booleans, Data, and nil Optionals are converted to the applicable Lua type. Any other type is bridged as described above.

Any Lua value can be converted back to a Swift value of type `T?` by calling `tovalue<T>()`. `table`s and `string`s are converted to whichever type is appropriate to satisfy the type `T`. If the type contraint `T` cannot be satisfied, `tovalue<T>()` returns nil. If `T` is `Any` (ie the most relaxed type constrait), but there is no Swift type capable of representing the Lua value (for example, a closure) then a `LuaValue` instance is returned. Similarly if `T` is `Dictionary<AnyHashable, Any>` but the Lua table contains a key which when converted is not hashable in Swift, `LuaValue` will be used there as well.

Any Lua value can be tracked as a Swift object, without converting back into a Swift type, by calling `ref()` which returns a `LuaValue` object, as described in the [Object-oriented API](#object-oriented-api) section.

## Thread safety

There is no hidden global state used to implement the type conversions, or to implement `setDefaultStringEncoding()`. Each top-level `LuaState` is completely independent, just a normal C `lua_State` is. Meaning you can safely use different `LuaState` instances from different threads at the same time. More technically, all `LuaState` APIs are [_reentrant_ but _not_ thread-safe](https://doc.qt.io/qt-6/threads-reentrancy.html), in the same way that the Lua C API is.

## Embedding Lua modules into a Swift binary

Normally if you want to be able to use `require(moduleName)` in your Lua code you must use `LuaState.setRequireRoot()` to specify a root directory in which to search for `.lua` files (unless you are happy to use the system search paths, which seems unlikely when using embedded Lua). This is not always feasible if you want to build a fully self-contained executable with no external dependencies.

There is another option, which is to compile your .lua files into generated Swift code which can then be compiled into your executable/binary just like any other Swift code. This is a cut-down version of similar resources-as-code systems such as Qt resources. To facilitate this a SwiftPM plugin `EmbedLuaPlugin` is supplied, which handles the code generation. Add it to your `Package.swift` as follows:

```swift
    .executableTarget(
        name: "my-standalone-executable",
        dependencies: [
            .product(name: "Lua", package: "LuaSwift")
        ],
        plugins: [
            .plugin(name: "EmbedLuaPlugin", package: "LuaSwift")
        ]
    )
```

This will add a constant called `lua_sources` to your target which contains the compiled Lua bytecode of every `.lua` file in your target's sources. Add and exclude Lua files with `sources` and `exclude` directives in your Target, as if they were Swift files to be compiled. This doesn't handle nested modules yet - everything is assumed to be a top-level module, currently.

Pass `lua_sources` to `addModules` when you construct your `LuaState`:

```swift
L = LuaState(libraries: .all)
L.setRequireRoot(nil) // Disable system search paths
L.addModules(lua_sources)
```

Assuming your project contained a file called `example.lua`, you can now do:

```lua
require("example")
```

Or, if you need to load the Lua code from Swift:

```swift
try L.load(data: lua_sources["example"]!, mode: .binary)
try L.pcall(nargs: 0, nret: 0) // Or nret: 1 if the file returns a table of module fns, etc

// or:

try L.requiref(name: "example") {
    try L.load(data: lua_sources["example"]!, mode: .binary)
}
```

## License

LuaSwift is written and maintained by Tom Sutcliffe, with contributions from Jason Barrie Morley, and is distributed under the [MIT License](LICENSE). It includes Lua 5.4, also distributed under the MIT License. The Lua copyright and license information is reproduced below:

```
Copyright © 1994–2023 Lua.org, PUC-Rio.
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
