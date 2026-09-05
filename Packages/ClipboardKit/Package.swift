// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ClipboardKit",
            targets: ["ClipboardKit"]
        ),
    ],
    targets: [
        .target(
            name: "ClipboardKit",
            path: "Sources/ClipboardKit"
        ),
        .testTarget(name: "ClipboardKitTests", dependencies: ["ClipboardKit"]),
    ]
)
