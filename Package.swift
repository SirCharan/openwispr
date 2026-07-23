// swift-tools-version: 6.0
import PackageDescription

// Dependencies are added per-milestone (loop discipline): WhisperKit at M1,
// KeyboardShortcuts at M4. M0 needs only system AppKit.
let package = Package(
    name: "Whispr",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Whispr",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "KeyboardShortcuts",
            ],
            path: "Sources/Whispr",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
