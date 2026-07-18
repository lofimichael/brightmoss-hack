// swift-tools-version: 6.1

import PackageDescription
import Foundation

let runtimeInfoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist")
    .path

let package = Package(
    name: "Checkpoint",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Checkpoint", targets: ["CheckpointApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/livekit/client-sdk-swift.git",
            exact: "2.15.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "CheckpointApp",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            path: "Sources/CheckpointApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            // `swift run` launches a bare executable rather than an .app
            // bundle. Embed the privacy strings in the Mach-O so TCC can show
            // CHECKPOINT's Accessibility/voice/screen-capture explanations in
            // the hackathon operator build as well as a packaged release.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", runtimeInfoPlist,
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "CheckpointAppTests",
            dependencies: ["CheckpointApp"],
            path: "Tests/CheckpointAppTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
