// swift-tools-version: 6.0
// Lets the platform-independent logic be tested from the command line with `swift test`.
import PackageDescription

let package = Package(
    name: "TournesolCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    targets: [
        .target(name: "TournesolCore", path: "Shared", sources: ["Model/Playback.swift", "Util/TrackMatcher.swift", "Util/NativeQueue.swift"]),
        .testTarget(name: "TournesolCoreTests", dependencies: ["TournesolCore"], path: "Tests/TournesolCoreTests"),
    ]
)
