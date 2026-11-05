// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JSONLCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "JSONLCore", targets: ["JSONLCore"]),
        .library(name: "JSONLSummarizer", targets: ["JSONLSummarizer"]),
    ],
    targets: [
        .target(name: "JSONLCore"),
        .target(name: "JSONLSummarizer", dependencies: ["JSONLCore"]),
        .testTarget(name: "JSONLCoreTests", dependencies: ["JSONLCore", "JSONLSummarizer"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
