// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CaptionLab",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "CaptionLab", targets: ["CaptionLab"]),
    ],
    targets: [
        .executableTarget(
            name: "CaptionLab",
            path: "Sources/CaptionLab"
        ),
    ]
)
