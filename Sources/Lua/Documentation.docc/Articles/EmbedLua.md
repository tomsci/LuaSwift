# Embedding Lua modules into a Swift binary

## Overview

Normally if you want to be able to use `require(moduleName)` in your Lua code you must use ``Lua/Swift/UnsafeMutablePointer/setRequireRoot(_:displayPath:)`` to specify a root directory in which to search for `.lua` files (unless you are happy to use the system search paths, which seems unlikely when using embedded Lua). This is not always feasible if you want to build a fully self-contained executable with no external dependencies.

There is another option, which is to compile your .lua files into generated Swift code which can then be compiled into your executable/binary just like any other Swift code. This is a cut-down version of similar resources-as-code systems such as Qt resources. To facilitate this a SwiftPM plugin `EmbedLuaPlugin` is supplied, which handles the code generation. Add it to your `Package.swift` as follows:

```swift
    .executableTarget(
        name: "my-standalone-executable",
        dependencies: [
            .product(name: "Lua", package: "LuaSwift")
        ],
        // Adding the EmbedLuaPlugin:
        plugins: [
            .plugin(name: "EmbedLuaPlugin", package: "LuaSwift")
        ]
    )
```

This will add a constant called `lua_sources` to your target which contains the compiled Lua bytecode of every `.lua` file in your target's sources. Add and exclude Lua files with `sources` and `exclude` directives in your Target, as if they were Swift files to be compiled. This doesn't handle nested modules yet - everything is assumed to be a top-level module, currently.

Pass `lua_sources` to ``Lua/Swift/UnsafeMutablePointer/addModules(_:mode:)`` when you construct your `LuaState`:

```swift
L = LuaState(libraries: .all)
L.setRequireRoot(nil) // Disable system search paths
L.addModules(lua_sources)
```

Assuming your project contained a file called `example.lua`, you can now do:

```lua
require("example")
```

`lua_sources` is just a dictionary of module names to compiled luac-style binary data, which looks something like this:

```swift
let lua_sources: [String: [UInt8]] = [
    "example": [
        /* ...data... */
    ],
    "someothermodule": [
        /* ...data... */
    ],
]
```

So if you need to load the Lua code from Swift you can access an individual module and call ``Lua/Swift/UnsafeMutablePointer/load(data:name:mode:)``:

```swift
try L.load(data: lua_sources["example"]!, mode: .binary)
try L.pcall(nargs: 0, nret: 0) // Or nret: 1 if the file returns a table of module fns, etc

// or:

try L.requiref(name: "example") {
    try L.load(data: lua_sources["example"]!, mode: .binary)
}
```
