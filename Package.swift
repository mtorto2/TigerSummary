// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TigerSummarizer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TigerSummarizerMenuBar", targets: ["TigerSummarizerMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "TigerSummarizerMenuBar",
            path: "Sources/TigerSummarizerMenuBar"
        )
    ]
)
