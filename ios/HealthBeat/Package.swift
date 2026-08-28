// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HealthBeat",
    platforms: [.iOS("17.0")],
    targets: [
        .target(
            name: "HealthBeat",
            path: "Sources/HealthBeat",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
