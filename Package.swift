// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orrinix",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Orrinix",
            path: "Sources/Orrinix",
            exclude: ["Resources/Localizable.xcstrings"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OrrinixTests",
            dependencies: ["Orrinix"],
            path: "Tests/OrrinixTests"
        ),
    ]
)
