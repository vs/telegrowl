// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Telegrowl",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Telegrowl",
            targets: ["Telegrowl"]
        ),
    ],
    dependencies: [
        // TDLib Swift wrapper
        .package(url: "https://github.com/Swiftgram/TDLibKit.git", exact: "1.5.2-tdlib-1.8.60-cb863c16"),
    ],
    targets: [
        .target(
            name: "Telegrowl",
            dependencies: [
                "TDLibKit",
            ],
            path: "Telegrowl"
        ),
    ]
)
