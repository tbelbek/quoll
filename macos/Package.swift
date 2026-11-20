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
            path: "Sources/QuollCore",
            // D7 in docs/DECISIONS.md: per-entry loops read class storage; dynamic
            // exclusivity checks were a measurable share of a 2.3M-entry scan.
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"])]
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
