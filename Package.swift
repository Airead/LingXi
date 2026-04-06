// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LingXi",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CLua",
            path: "Vendors/lua",
            sources: ["Sources"],
            publicHeadersPath: "module",
            cSettings: [
                .define("LUA_USE_MACOSX"),
            ]
        ),
        .target(
            name: "LingXi",
            dependencies: ["CLua"],
            path: "LingXi",
            exclude: ["Assets.xcassets"],
            swiftSettings: [
                .define("SPM_BUILD")
            ]
        ),
        .testTarget(
            name: "LingXiTests",
            dependencies: ["LingXi"],
            path: "LingXiTests"
        ),
    ]
)
