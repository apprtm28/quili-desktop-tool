// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ParaphraseTool",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ParaphraseTool", path: "Sources/ParaphraseTool"),
    ]
)
