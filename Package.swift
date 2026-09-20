// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "siri-say",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "siri-say", path: "Sources/siri-say")
    ]
)
