// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "newMosaic",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MosaicCore", targets: ["MosaicCore"]),
        .executable(name: "NewMosaicApp", targets: ["NewMosaicApp"])
    ],
    targets: [
        .target(
            name: "MosaicCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "NewMosaicApp",
            dependencies: ["MosaicCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "MosaicCoreTests",
            dependencies: ["MosaicCore"]
        )
    ]
)
