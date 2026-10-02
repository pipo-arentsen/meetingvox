// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingVox",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingVox",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "MeetingVoxTests",
            dependencies: ["MeetingVox"]
        ),
    ]
)
