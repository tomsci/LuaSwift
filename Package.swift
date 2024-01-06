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
    dependencies: [
        // .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
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
            resources: [
                .copy("testRequireRoot1")
            ],
            swiftSettings: [
                // .define("LUASWIFT_NO_FOUNDATION")
            ],
            plugins: [
                .plugin(name: "EmbedLuaPlugin")
            ]
        ),
    ]
)
