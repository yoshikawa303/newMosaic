# サードパーティ通知（モデル・ライブラリ）

newMosaic が同梱・利用するサードパーティ成果物の一覧。追加・更新時は本ファイルへ追記する。

## 同梱MLモデル

### anime_censor_detection（censor_detect_v1.0_s）

- 提供元: DeepGHS（https://huggingface.co/deepghs/anime_censor_detection）
- ライセンス: **MIT License**
- 用途: アニメ・イラスト画像のNSFW部位検出（クラス: nipple_f / penis / pussy）
- 同梱ファイル: `Sources/MosaicCore/Resources/censor_detect.onnx`（YOLOv8系ONNX, 約44.6MB）
- 取得日: 2026-07-22
- 備考: 完全ローカル実行。画像・検出結果の外部送信は行わない。

### anime_person_detection（person_detect_v1.3_s）

- 提供元: DeepGHS（https://huggingface.co/deepghs/anime_person_detection）
- ライセンス: **MIT License**
- 用途: アニメ・イラスト画像の人物検出（クラス: person。矩形のみ）
- 同梱ファイル: `Sources/MosaicCore/Resources/person_detect.onnx`（YOLOv8系ONNX, 約44.6MB）
- 取得日: 2026-07-22
- 備考: 完全ローカル実行。画像・検出結果の外部送信は行わない。

### nudenet_onnx（320n）

- 提供元: DeepGHS（https://huggingface.co/deepghs/nudenet_onnx）。元モデル: NudeNet v3（notAI-tech）
- ライセンス: **Apache License 2.0**（HuggingFaceリポジトリ表記）
- 用途: 実写画像のNSFW部位検出（18クラスのうち乳首・性器・肛門クラスのみ採用）
- 同梱ファイル: `Sources/MosaicCore/Resources/photo_censor_detect.onnx`（YOLOv8n系ONNX, 入力320x320, 約12.2MB）
- 取得日: 2026-07-22
- 備考: 完全ローカル実行。画像・検出結果の外部送信は行わない。

### anime_real_cls（mobilenetv3_v1.4_dist）

- 提供元: DeepGHS（https://huggingface.co/deepghs/anime_real_cls）
- ライセンス: **OpenRAIL**（責任あるAI利用の制限付きオープンライセンス。ローカルでの判定用途に使用）
- 用途: 画像種別（実写/アニメ・イラスト）の自動判定
- 同梱ファイル: `Sources/MosaicCore/Resources/domain_cls.onnx`（MobileNetV3系ONNX, 入力384x384, 約16.8MB）
- 取得日: 2026-07-22
- 備考: 完全ローカル実行。画像・判定結果の外部送信は行わない。

## 依存ライブラリ

### ONNX Runtime（onnxruntime-swift-package-manager）

- 提供元: Microsoft（https://github.com/microsoft/onnxruntime-swift-package-manager）
- ライセンス: **MIT License**
- 用途: ONNXモデルのローカル推論実行
- バージョン: 1.24.2（SwiftPM解決）
