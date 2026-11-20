// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Quoll",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "QuollCore", targets: ["QuollCore"]),
        .executable(name: "quoll", targets: ["quoll"]),
        .executable(name: "quoll-selftest", targets: ["QuollSelfTest"]),
        .executable(name: "QuollApp", targets: ["QuollApp"])
    ],
    targets: [
        .target(
            name: "QuollCore",
            path: "Sources/QuollCore"
        ),
        .executableTarget(
            name: "quoll",
            dependencies: ["QuollCore"],
            path: "Sources/quoll"
        ),
        .executableTarget(
            name: "QuollSelfTest",
            dependencies: ["QuollCore"],
            path: "Sources/QuollSelfTest"
        ),
        .executableTarget(
            name: "QuollApp",
            dependencies: ["QuollCore"],
            path: "Sources/QuollApp"
        )
    ]
)
