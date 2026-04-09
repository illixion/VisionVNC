// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonlightCommonC",

    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1)
    ],

    products: [
        .library(
            name: "MoonlightCommonC",
            type: .static,
            targets: ["MoonlightCommonC"]
        )
    ],

    targets: [
        .target(
            name: "enet",
            path: "enet",
            exclude: [
                "win32.c",
                "CMakeLists.txt",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAS_FCNTL", to: "1"),
                .define("HAS_IOCTL", to: "1"),
                .define("HAS_POLL", to: "1"),
                .define("HAS_GETADDRINFO", to: "1"),
                .define("HAS_GETNAMEINFO", to: "1"),
                .define("HAS_INET_PTON", to: "1"),
                .define("HAS_INET_NTOP", to: "1"),
                .define("HAS_MSGHDR_FLAGS", to: "1"),
                .define("HAS_SOCKLEN_T", to: "1"),
            ]
        ),

        .target(
            name: "MoonlightCommonC",
            dependencies: ["enet"],
            path: ".",
            exclude: [
                "nanors",
                "cmake",
                ".github",
                "CMakeLists.txt",
                "README.md",
                "LICENSE.txt",
                ".gitignore",
                ".gitmodules",
                "include",
            ],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("enet/include"),
                .headerSearchPath("nanors"),
                .headerSearchPath("nanors/deps"),
                .headerSearchPath("nanors/deps/obl"),
                .define("HAS_SOCKLEN_T"),
                .define("NDEBUG"),
                .define("USE_COMMONCRYPTO", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
            ]
        ),
    ]
)
