// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "LuaSwift",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
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
    dependencies: [
        // .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "Lua",
            dependencies: [
                "CLua",
            ],
            resources: [],
            swiftSettings: [
                // .define("LUASWIFT_NO_FOUNDATION")
                .define("LUASWIFT_ANYHASHABLE_BROKEN", .when(platforms: [.linux]))
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
                "extensions.c",
                "loadfile.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX", .when(platforms: [.macOS])),
                .define("LUA_USE_LINUX", .when(platforms: [.linux])),
                .define("LUA_USE_IOS", .when(platforms: [.iOS, .macCatalyst])),
                .headerSearchPath("lua"),
            ]
        ),
        .executableTarget(
            name: "embedlua",
            dependencies: [
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
            resources: [
                .copy("testRequireRoot1")
            ],
            swiftSettings: [
                // .define("LUASWIFT_NO_FOUNDATION")
                .define("LUASWIFT_ANYHASHABLE_BROKEN", .when(platforms: [.linux]))
            ],
            plugins: [
                .plugin(name: "EmbedLuaPlugin")
            ]
        ),
    ]
)
