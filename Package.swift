// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "fc8c3e4f5103bf63a242453566525272e143a054"),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11552/llama-b11552-xcframework.zip",
            checksum: "ac195b4693da8e250ed778bc66a137912b912c0a6733f9c3e52153d7258172b8"
        ),
        .executableTarget(
            name: "LocalDictation",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "llama",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "LocalDictationTests",
            dependencies: ["LocalDictation"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
