// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Usher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Usher", path: "Sources/Usher")
    ]
)
