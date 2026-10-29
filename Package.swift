// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeDeck",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure-logic library — Models, Services, no @main (testable)
        .target(
            name: "ClaudeDeckCore",
            path: "Sources/Core"
        ),
        // App entry point + Views — depends on Core
        .executableTarget(
            name: "ClaudeDeck",
            dependencies: ["ClaudeDeckCore"],
            path: "Sources/App",
            resources: [.copy("Resources")]
        ),
        // `claudedeck` command-line client for the control socket
        .executableTarget(
            name: "claudedeck-cli",
            dependencies: ["ClaudeDeckCore"],
            path: "Sources/CLI"
        ),
        // Test runner — no XCTest/Testing needed, works with CLI tools only
        // Run with: swift run ClaudeDeckTests
        .executableTarget(
            name: "ClaudeDeckTests",
            dependencies: ["ClaudeDeckCore"],
            path: "Tests/ClaudeDeckTests"
        )
    ]
)
