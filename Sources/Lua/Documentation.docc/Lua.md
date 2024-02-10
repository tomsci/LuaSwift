# ``Lua``

A framework providing Swift typesafe wrappers around the Lua C APIs.

## Overview

This project bundles Lua 5.4 plus Swift wrapper APIs, as a Swift Package. The full Lua C API is available, as well as typesafe Swift equivalents.

To include in your project, use a Package.swift file something like this:

```swift
// swift-tools-version: 5.5
import PackageDescription

let package = Package(
    name: "ExampleLuaSwiftProj",
    platforms: [
        .macOS(.v10_15)
    ],
    dependencies: [
        .package(url: "https://github.com/tomsci/LuaSwift.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "ExampleLuaSwiftProj",
            dependencies: [
                .product(name: "Lua", package: "LuaSwift"),
            ]
        )
    ]
)
```

Alternatively, submodule in the LuaSwift repository and use `.package(path: "LuaSwift")` instead.

Example syntax:

```swift
import Lua

let L = LuaState(libraries: .all)
L.getglobal("print")
try! L.pcall("Hello world!")
L.close()
``` 

The project is hosted here: <https://github.com/tomsci/LuaSwift>.

See <doc:LuaState> for an introduction to the framework.

## Topics

- <doc:LuaState>

@Comment {

Generated with:

    git apply enable-docc-dependency.patch
    swift package --allow-writing-to-directory _site generate-documentation --target Lua --disable-indexing --transform-for-static-hosting --hosting-base-path LuaSwift --output-path _site --include-extended-types

Preview with:

    swift package --disable-sandbox preview-documentation --target Lua --include-extended-types

}
