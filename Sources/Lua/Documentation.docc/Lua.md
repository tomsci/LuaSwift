# ``Lua``

A framework providing Swift typesafe wrappers around the Lua C APIs.

## Overview

The project is hosted here: <https://github.com/tomsci/LuaSwift>.

```swift
import Lua

let L = LuaState(libraries: .all)
L.getglobal("print")
try! L.pcall("Hello world!")
L.close()
``` 

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
