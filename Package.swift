// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Search",
            path: "Sources/Search",
            // The animated space backdrop's page and its three.js, copied as a
            // folder into Search_Search.bundle beside the binary (build.sh
            // carries that bundle into the app; Fork/AnimatedBackdrop.swift
            // looks in both places). The canvas page rides the same way
            // (Fork/Canvas/CanvasHost.swift, CanvasPage).
            resources: [.copy("Fork/Backdrop"), .copy("Fork/Canvas/Resources")],
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `swift test`: the pure parts that need no window — so far the
        // crash-report reader and the breadcrumb trail (Fork/Crashes.swift).
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search"],
            path: "Tests/SearchTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
