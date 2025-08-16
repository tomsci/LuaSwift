# LuaSwift

A [Swift](https://www.swift.org) wrapper for the [Lua 5.4](https://www.lua.org/manual/5.4/) C API, all bundled up as a Swift Package with no additional dependencies. All Swift APIs are added as extensions to `UnsafeMutablePointer<lua_State>`, meaning you can freely mix Lua C calls (and callbacks) with higher-level more Swift-like calls. Any Lua APIs without a dedicated Swift wrapper can be accessed by importing `CLua`.

Because this package mostly uses the raw C Lua paradigms (with a thin layer of Swift type-friendly wrappers on top), familiarity with the [Lua C API](https://www.lua.org/manual/5.4/manual.html#4) is strongly recommended. In particular, misusing the Lua stack or the `CLua` API will crash your program.

A copy of the LuaSwift API documentation can be found here: <https://tomsci.github.io/LuaSwift/documentation/lua>.

## Features

* Interop directly with C `lua_State` pointers; no custom Swift objects needed to represent the Lua runtime. Same APIs available within a `lua_CFunction` or `LuaClosure` as callable from the top level. Fully reentrant.
* Swift objects bridgeable into Lua using `userdata` and metatables, observing Swift lifetimes and Lua garbage collection.
* Lots of helper functions for converting Swift data types to and from Lua, supporting both raw and non-raw accesses, including powerful type-inference to support converting `string` to `Data` or `String`, and `table` to `Dictionary` or `Array`, as appropriate.
* Lua tables convertible to Swift types that implement `Decodable`.
* Lua longjmp-based errors translated into Swift throw-based Errors and vice-versa. Use plain `lua_CFunction`, Swift closures that can throw errors, or any mixture of the two.
* `yield`, `callk` and `pcallk` APIs supported in a Swift-safe fashion.
* Swift helpers for `ipairs` and `pairs` iteration operations.
* Optional object-oriented API. Raw C API also available.
* Precompilation of Lua source files at build-time integrated into Xcode (and `swift` command-line) using `swiftpm` plug-in.

## Usage

```swift
import Lua

let L = LuaState(libraries: .all)
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
// The above two lines are exactly equivalent to `let L = LuaState(libraries: .all)`
lua_getglobal(L, "print") // same as L.getglobal("print")
lua_pushstring(L, "Hello world!")
lua_pcall(L, 1, 0) // Ignoring some error checking here...
lua_close(L)
```

It could also be written using the more object-oriented (but slightly less efficient) `LuaValue`-based API:

```swift
import Lua

let L = LuaState(libraries: .all)
try! L.globals["print"]("Hello world!")
L.close()
```

`LuaState` is a `typealias` to `UnsafeMutablePointer<lua_State>`, which is the Swift bridged equivalent of `lua_State *` in C.

All C functions callable from Lua have the type signature [`lua_CFunction`](https://www.lua.org/manual/5.4/manual.html#lua_CFunction), otherwise written `int myFunction(lua_State *L) { ... }`. The Swift equivalent signature is `(LuaState!) -> CInt`. For example:

```swift
import Lua

func myLuaCFunction(_ L: LuaState!) -> CInt {
    print("I am a Swift function callable from Lua!")
    return 0
}
```

A more Swift-friendly function type `LuaClosure` is also defined, which allows Errors to be thrown from the closure body, which are translated into Lua errors.

## API compatibility

The LuaSwift API has been finalized at version 1.0. Subsequent releases may add new APIs, but no changes which break source compatibility are expected from this point on.

## More information

See the [Lua framework documentation](https://tomsci.github.io/LuaSwift/documentation/lua).

## License

LuaSwift is written and maintained by Tom Sutcliffe, with contributions from Jason Barrie Morley, and is distributed under the [MIT License](LICENSE). It includes Lua 5.4, also [distributed under the MIT License](https://www.lua.org/license.html). The Lua 5.4 copyright and license information is reproduced below:

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
