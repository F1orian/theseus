// swift-tools-version: 6.2
// Streaming-render benchmark behind ADR 0010: Textual vs swift-markdown + Theseus's renderer.
// Run: swift run -c release --package-path Benchmarks/RenderingBenchmark
import PackageDescription

let package = Package(
    name: "RenderingBenchmark",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Modules"),
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "RenderingBenchmark",
            dependencies: [
                .product(name: "Rendering", package: "Modules"),
                .product(name: "Textual", package: "textual"),
            ],
            resources: [.copy("benchmark-response.md")]
        ),
    ]
)
