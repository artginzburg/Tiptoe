// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Tiptoe",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "Tiptoe", targets: ["Tiptoe"]),
        .library(name: "TiptoeSparkle", targets: ["TiptoeSparkle"]),
    ],
    traits: [
        .default(enabledTraits: []),
        .trait(name: "SparkleSupport", description: "Bridge to Sparkle, for sandboxed apps"),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .target(name: "Tiptoe"),
        .target(
            name: "TiptoeSparkle",
            dependencies: [
                "Tiptoe",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(traits: ["SparkleSupport"])),
            ]
        ),
        .testTarget(name: "TiptoeTests", dependencies: ["Tiptoe"]),
    ],
    swiftLanguageModes: [.v6]
)
