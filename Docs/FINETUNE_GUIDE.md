# 自前ファインチューニング手順（YOLOエクスポート → ultralytics学習 → モデル差し替え）

newMosaic の「学習用エクスポート（YOLO形式）」で出力したアノテーションを使い、
部位検出モデルを自分のデータで転移学習して差し替えるための手順書。
学習はアプリ外（Python環境）で行い、生成したONNXをアプリのモデルと差し替える。

## 1. 学習データの準備

1. アプリでモザイク作業を行い、ROIを保存した画像を蓄積する（作業がそのまま学習データになる）。
2. ライブラリ画面の「学習用エクスポート（YOLO形式）」で任意フォルダへ出力する。
   - `images/` `labels/` `classes.txt` `dataset.yaml` が生成される。
3. 目安: 1カテゴリあたり500〜1000件で効果が出始める。

## 2. 学習環境の構築（要Python 3.10+）

```bash
python3 -m venv venv && source venv/bin/activate
pip install ultralytics onnx
```

## 3. 転移学習の実行

既存の同梱モデル（YOLOv8系）と同じ系統から開始する。アニメ用は
deepghs/anime_censor_detection の重みを初期値にできない場合、`yolov8s.pt` から開始してよい。

```bash
yolo detect train \
  data=/path/to/exported/dataset.yaml \
  model=yolov8s.pt \
  imgsz=640 epochs=100 batch=16 \
  project=newmosaic_finetune name=censor_v1
```

## 4. ONNXへの変換

```bash
yolo export model=newmosaic_finetune/censor_v1/weights/best.onnx? format=onnx imgsz=640 opset=12
# 出力: best.onnx（YOLOv8標準の属性メジャー出力 (1, 4+クラス数, アンカー数)）
```

## 5. アプリへの差し替え

1. `best.onnx` を `Sources/MosaicCore/Resources/censor_detect.onnx`（アニメ用）へ上書きする。
   - クラス数・クラス順が `AnimeCensorDetector.classCategories` と一致していることを確認する。
   - クラス構成を変えた場合は `classCategories` を修正する。
2. モデルキャッシュのマーカーバージョンを上げる（`YOLOONNXModel.cachedModelURL` の
   `ModelCache.<name>.v1` → `.v2`）。これで次回起動時に新モデルが再コピーされる。
3. `swift test` で全テストPASSを確認し、Buildをインクリメントして再パッケージする。

## 注意

- 学習・推論とも完全ローカルで実施する（画像の外部送信は行わない方針）。
- 差し替え前後の検出精度は同じ検証画像セットで比較し、`Docs/QC/` に記録する。
