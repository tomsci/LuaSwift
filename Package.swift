// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "LuaSwift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Lua",
            targets: [
                "CLua",
                "Lua",
            ]),
        .plugin(
            name: "EmbedLuaPlugin",
            targets: [
                "EmbedLuaPlugin"
            ]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Lua",
            dependencies: [
                "CLua",
            ],
             resources: []
        ),
        .target(
            name: "CLua",
            dependencies: [],
            exclude: [
                "lua/all",
                "lua/ltests.c",
                "lua/lua.c",
                "lua/makefile",
                "lua/manual",
                "lua/onelua.c",
                "lua/README.md",
                "lua/testes",
            ],
            sources: [
                "lua",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_POSIX"),
                .headerSearchPath("lua"),
            ]
        ),
        .executableTarget(
            name: "embedlua",
            dependencies: [
                "CLua",
                "Lua",
            ]
        ),
        .plugin(
            name: "EmbedLuaPlugin",
            capability: .buildTool(),
            dependencies: [
                "embedlua",
            ]),
        .testTarget(
            name: "lua-test",
            dependencies: ["Lua", "CLua"]
        )
    ]
)
