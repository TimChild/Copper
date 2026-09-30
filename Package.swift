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
            // looks in both places).
            resources: [.copy("Fork/Backdrop")],
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
