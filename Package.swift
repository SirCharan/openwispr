// swift-tools-version: 6.0
import PackageDescription

// Dependencies are added per-milestone (loop discipline): WhisperKit at M1,
// KeyboardShortcuts at M4. M0 needs only system AppKit.
let package = Package(
    name: "Whispr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Whispr",
            path: "Sources/Whispr",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
