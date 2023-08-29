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
            resources: [],
            swiftSettings: [
                .define("LUASWIFT_NO_FOUNDATION", .when(platforms: [.linux]))
            ]
        ),
        // This target exists to ensure the LUASWIFT_NO_FOUNDATION code always compiles, and to support lua-test-nofoundation
        .target(
            name: "Lua-NoFoundation",
            dependencies: [
                "CLua",
            ],
            resources: [],
            swiftSettings: [
                .define("LUASWIFT_NO_FOUNDATION")
            ]
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
                // LUA_USE_IOS sets LUA_USE_POSIX automatically meaning we have to avoid setting it on iOS...
                .define("LUA_USE_POSIX", .when(platforms: [.macOS, .linux])),
                .define("LUA_USE_IOS", .when(platforms: [.iOS, .macCatalyst])),
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
            dependencies: ["Lua", "CLua"],
            swiftSettings: [
                .define("LUASWIFT_NO_FOUNDATION", .when(platforms: [.linux]))
            ]
        ),
        .testTarget(
            name: "lua-test-nofoundation",
            dependencies: ["Lua", "CLua"],
            swiftSettings: [
                .define("LUASWIFT_NO_FOUNDATION")
            ]
        ),
    ]
)
