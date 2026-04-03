// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LingXi",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LingXi",
            path: "LingXi",
            exclude: ["Assets.xcassets"],
            swiftSettings: [
                .define("SPM_BUILD")
            ]
        ),
    ]
)
