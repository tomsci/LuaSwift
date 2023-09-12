# ``Lua``

A framework providing Swift typesafe wrappers around the Lua C APIs.

## Overview

The project is hosted here: <https://github.com/tomsci/LuaSwift>.

See <doc:LuaState> for an introduction to the framework.


## Topics

- <doc:LuaState>


@Comment {

Generated with:

rm -r docs-from-main
swift package --allow-writing-to-directory docs-from-main generate-documentation --target Lua --disable-indexing --transform-for-static-hosting --hosting-base-path LuaSwift --output-path docs-from-main --include-extended-types
git checkout gh-pages
rm -r docs
mv docs-from-main docs
git add docs
git commit -m "Updated documentation"


Preview with:

swift package --disable-sandbox preview-documentation --target Lua --include-extended-types

}
