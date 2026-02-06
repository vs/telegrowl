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
        // OGG/Opus encoding for Telegram voice messages
        .package(url: "https://github.com/element-hq/swift-ogg.git", from: "0.0.3"),
    ],
    targets: [
        .target(
            name: "Telegrowl",
            dependencies: [
                "TDLibKit",
                .product(name: "SwiftOGG", package: "swift-ogg"),
            ],
            path: "Telegrowl"
        ),
    ]
)
