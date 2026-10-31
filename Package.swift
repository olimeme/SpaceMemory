// swift-tools-version:5.9
import PackageDescription

// The app is a tiny launcher that loads everything else from a separate library. macOS ties
// permissions to the launcher's signature, so rebuilding the library doesn't lose them.
let package = Package(
    name: "SpaceMemory",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpaceMemoryCore", type: .dynamic, targets: ["SpaceMemoryCore"]),
        .executable(name: "SpaceMemory", targets: ["SpaceMemory"]),
    ],
    targets: [
        .target(name: "SpaceMemoryCore", path: "Sources/SpaceMemoryCore"),
        .executableTarget(name: "SpaceMemory", path: "Sources/SpaceMemory"),
    ]
)
