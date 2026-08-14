// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Tiptoe",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "Tiptoe", targets: ["Tiptoe"]),
        .library(name: "TiptoeSparkle", targets: ["TiptoeSparkle"]),
        .library(name: "TiptoeGitHub", targets: ["TiptoeGitHub"]),
    ],
    traits: [
        .default(enabledTraits: []),
        .trait(name: "SparkleSupport", description: "Bridge to Sparkle, for sandboxed apps"),
        .trait(name: "GitHubSupport", description: "Bridge to mxcl/AppUpdater and GitHub Releases"),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
        .package(url: "https://github.com/mxcl/AppUpdater", from: "4.1.0"),
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
        .target(
            name: "TiptoeGitHub",
            dependencies: [
                "Tiptoe",
                .product(name: "AppUpdater", package: "AppUpdater", condition: .when(traits: ["GitHubSupport"])),
            ]
        ),
        .testTarget(name: "TiptoeTests", dependencies: ["Tiptoe"]),
        .testTarget(name: "TiptoeGitHubTests", dependencies: ["TiptoeGitHub", "Tiptoe"]),
    ],
    swiftLanguageModes: [.v6]
)
