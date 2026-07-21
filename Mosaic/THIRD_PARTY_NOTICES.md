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

## 依存ライブラリ

### ONNX Runtime（onnxruntime-swift-package-manager）

- 提供元: Microsoft（https://github.com/microsoft/onnxruntime-swift-package-manager）
- ライセンス: **MIT License**
- 用途: ONNXモデルのローカル推論実行
- バージョン: 1.24.2（SwiftPM解決）
