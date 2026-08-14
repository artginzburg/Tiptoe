// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Tiptoe",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "Tiptoe", targets: ["Tiptoe"]),
    ],
    targets: [
        .target(name: "Tiptoe"),
        .testTarget(name: "TiptoeTests", dependencies: ["Tiptoe"]),
    ],
    swiftLanguageModes: [.v6]
)
