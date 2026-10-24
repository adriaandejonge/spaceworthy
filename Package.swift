// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Spaceworthy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Spaceworthy",
            path: "Sources/Spaceworthy"
        )
    ]
)
