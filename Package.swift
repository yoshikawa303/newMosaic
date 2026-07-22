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
    dependencies: [
        // ONNX Runtime（ローカル推論用。deepghs/anime_censor_detection等のONNXモデル実行に使用）
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0")
    ],
    targets: [
        .target(
            name: "MosaicCore",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            resources: [
                // deepghs/anime_censor_detection censor_detect_v1.0_s (MIT License)
                .copy("Resources/censor_detect.onnx"),
                // deepghs/anime_person_detection person_detect_v1.3_s (MIT License)
                .copy("Resources/person_detect.onnx"),
                // deepghs/nudenet_onnx 320n (Apache-2.0 License, NudeNet v3)
                .copy("Resources/photo_censor_detect.onnx"),
                // deepghs/anime_real_cls mobilenetv3_v1.4_dist (OpenRAIL License)
                .copy("Resources/domain_cls.onnx")
            ],
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
