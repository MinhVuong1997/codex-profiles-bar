// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexProfilesBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "CodexProfilesBar",
            targets: ["CodexProfilesBar"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "CodexProfilesBar",
            path: "Sources/CodexProfilesBar"
        ),
    ]
)
