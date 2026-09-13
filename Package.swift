// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Orb",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Orb", targets: ["Orb"])],
    targets: [
        .target(name: "TalkerCore"),
        .executableTarget(name: "Orb", dependencies: ["TalkerCore"]),
        .testTarget(name: "TalkerCoreTests", dependencies: ["TalkerCore"]),
        .testTarget(name: "OrbTests", dependencies: ["Orb", "TalkerCore"])
    ]
)
