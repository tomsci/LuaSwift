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

This will add a constant called `lua_sources` to your target which contains the compiled Lua bytecode of every `.lua` file in your target's sources. Add and exclude Lua files with `sources` and `exclude` directives in your Target, as if they were Swift files to be compiled. The module name is derived from the Lua file name plus heuristics based on what other Lua files are being built (see <doc:#Nested-modules>, below). Note that module names are case sensitive when using `EmbedLuaPlugin`, regardless of the behavior of any underlying filesystem.

> Tip: In a non-Swift-package Xcode project, instead go to the "Build Phases" tab of the target and click the "+" under "Run Build Tool Plug-ins", and select "LuaSwift -> EmbedLuaPlugin". To avoid warnings from the build system, you may want to collect all the Lua sources into a separate "Copy Files" build phase, rather than leaving the Lua files in the "Compile Sources" phase like you (effectively) do with a SwiftPM project. Using a Copy Files build phase with "Destination: Products Directory" and "Subpath: dummyCopyLocationForLuaFiles" is an effective workaround. The `lua_sources` file is added to the project automatically and does not need to be managed manually.

All the included Lua files will be compiled into Lua bytecode when your project is built. Parse and syntax errors in the Lua files will show as clickable errors in the Xcode build log.

Then, pass `lua_sources` to ``Lua/Swift/UnsafeMutablePointer/addModules(_:mode:)`` when you construct your `LuaState`:

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

So if you need to load the Lua code from Swift you can access an individual module and call ``Lua/Swift/UnsafeMutablePointer/load(data:name:mode:)`` or ``Lua/Swift/UnsafeMutablePointer/requiref(name:global:closure:)``:

```swift
try L.load(data: lua_sources["example"]!, mode: .binary)
try L.pcall(nargs: 0, nret: 0) // Or nret: 1 if the file returns a table of module fns, etc

// or:

try L.requiref(name: "example") {
    try L.load(data: lua_sources["example"]!, mode: .binary)
}
```

> Note: When adding additional Lua files to a SwiftPM project, you may have to run `File -> Packages -> Reset Package Cache` and then clean the project, in order for the new files to be noticed by the build system.

## Nested modules

`EmbedLuaPlugin` supports generating a hierarchy of modules, that is modules in subdirectories which are included using dot-separated syntax such as `require("dir.subdir.modulename")`. It does this by looking at all the Lua sources which are included, and for each of them looking at the file's parent directories and seeing if those directories also contain any other Lua sources. If so, that module is considered to be nested. For example, consider a project directory like this:

```
ProjectDir/Sources/MyTarget/
|- MySwiftCode.swift
|- DirA/
|  |- firstmod.lua
|- DirB/
|  |- secondmod.lua
```

In other words there are 2 Lua files located at `ProjectDir/Sources/MyTarget/DirA/firstmod.lua` and `ProjectDir/Sources/MyTarget/DirB/secondmod.lua`. Both `firstmod` and `secondmod` are considered top-level modules because the parent directory (in both cases, `ProjectDir/Sources/MyTarget`) does not itself contain any Lua files which are being compiled. Therefore they would be included by writing something like `require "firstmod"` and/or `require "secondmod"`.

Now, consider the case where there _is_ a Lua file in the parent directory:

```
ProjectDir/Sources/MyTarget/
|- MySwiftCode.swift
|- topmod.lua
|- DirA/
|  |- firstmod.lua
|- DirB/
|  |- secondmod.lua
```

This will produce a `lua_sources` like this:

```swift
let lua_sources: [String: [UInt8]] = [
    "topmod": [
        /* ...data... */
    ],
    "DirA.firstmod": [
        /* ...data... */
    ],
    "DirB.secondmod": [
        /* ...data... */
    ],
]
```

Now, `firstmod.lua` and `secondmod.lua` are considered to be nested because of the presence of `topmod.lua` in their parent directory, and would need to be included using `require "DirA.firstmod"` or similar. The same logic applies for any level of nesting - each directory in the hierarchy must contain at least one Lua file to avoid terminating the hierarchy. As a convenience, if a zero-length file named `_.lua` exists it will count for the purposes of establishing the hierarchy, but will not appear in `lua_sources`.

Note that `EmbedLuaPlugin` does not treat nested `init.lua` files specially - to have a module `foo` and a module `foo.bar`, the files must be structured as `dir/foo.lua` and `dir/foo/bar.lua`.

## Custom module names

If the default behavior of `EmbedLuaPlugin` does not fit exactly the module naming behavior that your project needs, one option is to transform `lua_sources` before passing it to `addModules(_:)` or `setModules(_:)`. For example, to make all modules top-level regardless of their location in the filesystem, you could do:

```swift
var new_sources: [String: [UInt8]] = [:]
for (k, v) in lua_sources {
    let flatName = String(k.split(separator: ".").last!)
    new_sources[flatName] = v
}
L.setModules(new_sources)
```
