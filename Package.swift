// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Telegrowl",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Telegrowl",
            targets: ["Telegrowl"]
        ),
    ],
    dependencies: [
        // TDLib Swift wrapper
        // Note: You may need to use a different TDLib package or build from source
        // .package(url: "https://github.com/Swiftgram/TDLibKit.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "Telegrowl",
            dependencies: [
                // "TDLibKit",
            ],
            path: "Telegrowl"
        ),
    ]
)
