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

---

# 部位セグメンテーション（形状）モデルの学習

同梱の検出モデル（`censor_detect.onnx` 等）は**枠しか出力しない**。性器・乳首の「形状」を得るには、
形状（セグメンテーション）を学習したモデルが必要になる。ここではその作り方を示す。

背景と実測根拠は `Mosaic/ARCHITECTURE.md` §5.40 / §5.41 を参照。要点は「Visionの前景抽出は
被写体と背景を分けるものであり、被写体**内部**の部位は原理的に分離できない」。画像処理の
パラメータ調整では解決しない。

## S1. 学習データを作る（アプリ側の作業）

形状モデルには**輪郭のアノテーション**が要る。枠や楕円では学習できない（楕円を出力するモデルが育つだけ）。

1. 画像を開き、対象部位に選択範囲を作る
2. インスペクタ＞選択範囲＞形状を「多角形」にする
3. 頂点をドラッグして実際の輪郭に沿わせる（Option+クリックで頂点の追加/削除）
4. 保存する

目安として、**カテゴリごとに100枚以上**あると実用域に入りやすい。少数（20〜30枚）でも
「楕円で塗るよりまし」な結果は出るが、過学習しやすい。まずは50枚程度で1回学習し、
結果を見てから増やす進め方を推奨する。

## S2. データセットを書き出す

アプリからYOLOセグメンテーション形式で書き出す（`YOLOSegDatasetExporter`）。

- `images/` 元画像PNG
- `labels/` 1行 = `class x1 y1 x2 y2 ...`（正規化・左上原点の多角形）
- `classes.txt` / `dataset.yaml`

**既定では手描き多角形のROIだけを書き出す。** 楕円・矩形ROIは形状学習に有害なため除外される
（`includeApproximatedShapes: true` で明示的に含められるが、通常は使わない）。

クラス順は実行側（`PartSegmentationDetector.classCategories`）と一致させてある:

```
0: nipple
1: maleGenital
2: femaleGenital
```

この順序を変えると学習済みモデルのカテゴリが入れ替わる。変更しないこと。

## S3. 学習する（Python 3.10+）

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install ultralytics onnx onnxruntime
```

```bash
yolo segment train \
  model=yolov8n-seg.pt \
  data=/path/to/dataset/dataset.yaml \
  epochs=100 imgsz=640 batch=8 \
  project=runs name=part_seg
```

- `yolov8n-seg.pt` は最小モデル。精度が足りなければ `yolov8s-seg.pt` へ上げる
- `imgsz=640` はアプリ側の入力サイズと合わせる（変える場合は `PartSegmentationDetector(inputSize:)` も合わせる）
- 学習データが少ないうちは `epochs` を増やすより枚数を増やす方が効く

## S4. ONNXへ変換する

```bash
yolo export model=runs/part_seg/weights/best.pt format=onnx opset=12
```

出力される `best.onnx` は**出力が2本**になる（検出専用モデルは1本）。

- `output0`: `(1, 4 + クラス数 + 32, アンカー数)` — 枠・クラススコア・マスク係数
- `output1`: `(1, 32, 160, 160)` — マスクのプロトタイプ

出力が1本しかない場合は `segment` ではなく `detect` で学習している。やり直すこと。

確認方法:

```bash
python3 -c "import onnx; m=onnx.load('best.onnx'); print([o.name for o in m.graph.output])"
```

## S5. アプリへ導入する

```bash
mkdir -p ~/Library/Application\ Support/newMosaic/Models
cp best.onnx ~/Library/Application\ Support/newMosaic/Models/part_seg.onnx
```

アプリを再起動し、インスペクタ＞検出＞マスク生成で「**学習モデル形状**」を選ぶ。

## 注意

- モデルは**同梱しない**。学習データは各自のものであり、配布時のライセンス・権利関係を避けるため
- 未導入・推論失敗・マスクがほぼ空、のいずれの場合も自動的に「図形（矩形/楕円）」へフォールバックする。
  検閲漏れ（マスクが薄い/空になる）を作らないための設計
- 推論は完全ローカル。画像も検出結果も外部へ送信しない
- 学習は既存の検出モデルを置き換えない。ROIの**位置**は従来どおり検出モデルが決め、
  形状モデルはその中の**輪郭**だけを担当する
