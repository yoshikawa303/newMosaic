# AIモデルの導入（個別インストール運用）

newMosaic が使うONNXモデル（計451MB）は**Gitで管理しません**。GitHubの1ファイル100MB上限に
掛かり push できなくなったためです（2026-07-31）。クローン後・配布アプリ利用時は、
本書の手順でモデルを配置してください。

## 配置先

```
~/Library/Application Support/newMosaic/Models/
```

実行時の解決は `YOLOONNXModel.cachedModelURL(resourceName:)` が行い、
「アプリバンドル内 → 上記フォルダ」の順で探します。モデルはバンドルへ同梱しなくなったため、
実際には上記フォルダが唯一の参照先になります。

## 導入手順

モデル一式を置いたフォルダを指定して実行します。

```bash
scripts/install_models.sh <モデルを置いたフォルダ>
```

導入状況の確認のみ行う場合:

```bash
scripts/install_models.sh --verify
```

## モデル一覧と入手元

いずれも配布元のライセンスに従って各自で取得してください。ファイル名は下表の名前に揃えます
（`<名前>.onnx`）。

| ファイル名 | 用途 | 配布元 | ライセンス | 目安サイズ |
| --- | --- | --- | --- | --- |
| `censor_detect` | アニメ・イラストの部位検出 | deepghs/anime_censor_detection `censor_detect_v1.0_s` | MIT | 43MB |
| `person_detect` | アニメ・イラストの人物検出 | deepghs/anime_person_detection `person_detect_v1.3_s` | MIT | 43MB |
| `photo_censor_detect` | 実写の部位検出 | deepghs/nudenet_onnx `320n`（NudeNet v3） | Apache-2.0 | 12MB |
| `domain_cls` | イラスト／実写の判別 | deepghs/anime_real_cls `mobilenetv3_v1.4_dist` | OpenRAIL | 16MB |
| `anime_seg` | キャラクターと背景の分離 | skytnt/anime-seg `isnetis` | Apache-2.0 | 168MB |
| `anime_pose` | アニメ・イラストの骨格推定 | yzd-v/DWPose `dw-ll_ucoco_384` | Apache-2.0 | 128MB |
| `sam_encoder` | 「対象形状（SAM）」の画像エンコード | MobileSAM (Apache-2.0) のONNX変換版 Acly/MobileSAM | MIT | 27MB |
| `sam_decoder` | 「対象形状（SAM）」のマスク生成 | 同上 | MIT | 16MB |

任意導入（同梱も配布もしない）:

| ファイル名 | 用途 | 備考 |
| --- | --- | --- |
| `part_seg` | マスク生成「学習モデル形状」 | 自前で学習したYOLO-segモデル。置かれている場合のみ有効になる |

## 未導入時の挙動

モデルが見つからない場合、該当機能は無効になり、エラーメッセージで不足しているモデル名と
本書の手順を案内します。アプリ自体は起動し、手動でのROI追加・モザイク処理は行えます。

## 配布アプリ（`dist/newMosaic.app`）について

`scripts/package_macos_app.sh` が作る `.app` にもモデルは含まれません。別のMacで動かす場合は、
そのMacでも本書の手順でモデルを配置してください。
