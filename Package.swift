// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ipdfmini",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ipdfmini", targets: ["ipdfmini-cli"]),
        .library(name: "MiniKit", targets: ["MiniKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "MiniGeometry"),
        .target(name: "PDFAnalysis", dependencies: ["MiniGeometry"]),
        .target(name: "LayoutEngine", dependencies: ["MiniGeometry", "PDFAnalysis"]),
        .target(name: "PDFWriting", dependencies: ["MiniGeometry", "PDFAnalysis", "LayoutEngine"]),
        .target(name: "SyntheticCorpus", dependencies: ["MiniGeometry"]),
        .target(name: "MiniKit", dependencies: ["MiniGeometry", "PDFAnalysis", "LayoutEngine", "PDFWriting"]),
        .executableTarget(
            name: "ipdfmini-cli",
            dependencies: ["MiniKit", "SyntheticCorpus", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(name: "ipdfmini-spikes", dependencies: ["MiniGeometry"]),

        .testTarget(name: "MiniGeometryTests", dependencies: ["MiniGeometry"]),
        .testTarget(name: "PDFAnalysisTests", dependencies: ["PDFAnalysis", "SyntheticCorpus"]),
        .testTarget(name: "LayoutEngineTests", dependencies: ["LayoutEngine"]),
        .testTarget(name: "PDFWritingTests", dependencies: ["PDFWriting", "SyntheticCorpus"]),
        .testTarget(name: "SyntheticCorpusTests", dependencies: ["SyntheticCorpus"]),
        .testTarget(name: "MiniKitTests", dependencies: ["MiniKit", "SyntheticCorpus"]),
    ]
)
