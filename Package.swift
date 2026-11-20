// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChronoStream",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ChronoStream", targets: ["ChronoStream"])
    ],
    targets: [
        .executableTarget(
            name: "ChronoStream",
            path: "Sources/ChronoStream",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
                .linkedFramework("PDFKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "ChronoStreamTests",
            dependencies: ["ChronoStream"],
            path: "Tests/ChronoStreamTests"
        )
    ]
)
