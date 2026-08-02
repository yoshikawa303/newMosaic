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
            // ONNXモデル（計451MB）はGit管理外・同梱対象外とし、個別インストール運用にする。
            // GitHubの100MBファイル上限に掛かりpushできなくなったため（2026-07-31）。
            // 配置先は `~/Library/Application Support/newMosaic/Models/`。
            // 導入は `scripts/install_models.sh`、一覧と入手元は `Docs/MODELS.md` を参照。
            // 実行時の解決は `YOLOONNXModel.cachedModelURL(resourceName:)`（バンドル→上記フォルダ）。
            resources: [
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
