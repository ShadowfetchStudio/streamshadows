// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamShadows",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StreamShadows", targets: ["StreamShadows"])
    ],
    targets: [
        .executableTarget(
            name: "StreamShadows",
            path: "Sources/StreamShadows",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "StreamShadowsTests",
            dependencies: ["StreamShadows"],
            path: "Tests/StreamShadowsTests"
        )
    ]
)
