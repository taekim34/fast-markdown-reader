// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FastMDReader",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "FastMDReader",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "Sources/FastMDReader",
            // AppKit app is not built around actors; use Swift 5 language mode to avoid
            // spurious strict-concurrency isolation errors against @MainActor AppKit types.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FastMDReaderTests",
            dependencies: ["FastMDReader"],
            path: "Tests/FastMDReaderTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
