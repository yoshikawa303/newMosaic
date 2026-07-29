// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "newMosaic",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MosaicCore", targets: ["MosaicCore"]),
        .library(name: "MosaicVideoKit", targets: ["MosaicVideoKit"]),
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
                // MobileSAM (Apache-2.0) のONNX変換版 Acly/MobileSAM (MIT License)
                // 検出枠の内部から対象の形状マスクを直接得る（対象形状（SAM））
                .copy("Resources/sam_encoder.onnx"),
                .copy("Resources/sam_decoder.onnx"),
                // deepghs/anime_person_detection person_detect_v1.3_s (MIT License)
                .copy("Resources/person_detect.onnx"),
                // deepghs/nudenet_onnx 320n (Apache-2.0 License, NudeNet v3)
                .copy("Resources/photo_censor_detect.onnx"),
                // deepghs/anime_real_cls mobilenetv3_v1.4_dist (OpenRAIL License)
                .copy("Resources/domain_cls.onnx"),
                // skytnt/anime-seg isnetis (Apache-2.0 License)
                .copy("Resources/anime_seg.onnx"),
                // yzd-v/DWPose dw-ll_ucoco_384 (Apache-2.0 License)
                .copy("Resources/anime_pose.onnx"),
                // 同梱かぶせ画像素材（自前ベクター生成: scripts/generate_overlay_assets.swift）
                .copy("Resources/Overlays")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "NewMosaicApp",
            dependencies: ["MosaicCore", "MosaicVideoKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "MosaicCoreTests",
            dependencies: ["MosaicCore"]
        ),
        // 動画対応のプラグイン境界。既存のMosaicCore/NewMosaicAppは変更せず、
        // MosaicCoreへ依存する独立ターゲットとして動画I/O・追跡・書き出しを提供する
        // （UIとの結線は別途行う想定の土台実装）。
        .target(
            name: "MosaicVideoKit",
            dependencies: ["MosaicCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "MosaicVideoKitTests",
            dependencies: ["MosaicVideoKit", "MosaicCore"]
        )
    ]
)
