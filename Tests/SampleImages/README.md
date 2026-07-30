# 検出・マスク生成の実画像回帰テスト用サンプル

このフォルダへ実画像を置くと、`SampleImageRegressionTests` が自動で読み込んで
検出結果と人物マスクの品質を測定します。**画像は Git 管理外です**（`.gitignore` 済み）。
著作物・成人向け画像をリポジトリへ混入させないための措置なので、この設定は変更しないでください。

## 置き方

```
Tests/SampleImages/
  page22.png              ← 実画像（png / jpg / jpeg）
  page22.expected.json    ← 期待値（省略可。省略時は測定のみ行い合否判定しない）
```

## 期待値ファイルの書式

```json
{
  "note": "22ページ目。下段コマは人物が小さい",
  "minimumRecall": 0.8,
  "maximumFalsePositives": 1,
  "maximumPersonMaskCoverage": 0.85,
  "expected": [
    { "category": "femaleGenital", "rect": { "x": 0.40, "y": 0.55, "width": 0.08, "height": 0.13 } },
    { "category": "maleGenital",   "rect": { "x": 0.55, "y": 0.55, "width": 0.14, "height": 0.13 } },
    { "category": "nipple",        "rect": { "x": 0.25, "y": 0.33, "width": 0.05, "height": 0.05 } }
  ]
}
```

- `category`: `MosaicTargetCategory` の rawValue（`nipple` / `femaleGenital` / `maleGenital` / `other` / `eyes` / `lowerFace` / `areola`）
- `rect`: 画像に対する正規化座標（0〜1・左上原点）
- 期待値と検出結果は **同カテゴリかつ IoU 0.3 以上** で対応付けます
- `minimumRecall`: 期待した対象のうち検出できた割合の下限（既定 0.0 = 判定しない）
- `maximumFalsePositives`: 期待値に対応しない検出の上限（既定は判定しない）
- `maximumPersonMaskCoverage`: 人物マスクが人物枠内を占める割合の上限。
  1.0 に近い値は「背景まで塗っている」状態を意味します（既定は判定しない）

## 座標の調べ方

アプリで候補生成した後、ヘルプ＞デバッグ＞デバッグログの `Detection` カテゴリに
`genitalSize` 行として ROI の面積が出ます。正確な座標が必要な場合は、
アプリ上でROIを配置してからライブラリ＞「学習用データセットを書き出す」を実行すると、
`labels/*.txt` に `class cx cy w h`（正規化）で出力されるので、そこから換算できます。

## 実行

```
swift test --filter SampleImageRegressionTests
```

画像を1枚も置いていない場合、テストは何も測定せずに成功します（CIを壊しません）。
測定結果は標準出力へ表形式で出ます。
