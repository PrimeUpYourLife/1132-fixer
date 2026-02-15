// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpoofZoomApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SpoofZoomApp", targets: ["SpoofZoomApp"])
    ],
    targets: [
        .executableTarget(
            name: "SpoofZoomApp",
            path: "Sources/SpoofZoomApp"
        )
    ]
)
