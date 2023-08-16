// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "Lua",
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
        .testTarget(
            name: "lua-test",
            dependencies: ["Lua", "CLua"]
        )
    ]
)
