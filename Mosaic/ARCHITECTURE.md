# newMosaic アーキテクチャ

## 1. 目的

newMosaic は、画像・動画のモザイク作業を完全自動化ではなく半自動化し、人間の作業時間を80%以上削減することを目標とする。

## 2. MVP 範囲

- 対象: 実写静止画
- 優先OS: macOS
- 将来対応: Windows、動画、CoreML、Android、iPhone
- 方針: UI と AI / 画像処理を完全分離し、モデル交換可能な境界を維持する。

## 3. パイプライン

1. `ImageLoader`: 画像読み込み
2. `PersonDetector`: 人物領域抽出
3. `PoseEstimator`: 骨格または姿勢ヒント抽出
4. `ROIGenerator`: 腰・脚・姿勢情報から探索範囲生成
5. `CandidateDetector`: ROI 内の詳細候補生成
6. `SegmentEngine`: 候補範囲からマスク生成
7. `MosaicEngine`: モザイク描画
8. `HistoryEngine`: ユーザー修正履歴保存

## 4. 初期実装方針

- 初期MVPは外部モデルを必須にしない。
- macOS 標準の Vision / CoreImage / AppKit で動作する最小構成を先に成立させる。
- `PersonDetector` / `PoseEstimator` / `SegmentEngine` はプロトコルで抽象化し、後続で MediaPipe、ONNX Runtime、SAM2、CoreML へ差し替え可能にする。
- 自動ROIは補助候補であり、ユーザーの手動矩形追加・削除を必ず可能にする。

## 5. プライバシー

- 画像、生成マスク、修正履歴はローカル処理・ローカル保存を既定とする。
- 外部API送信、クラウド学習、遠隔ログ送信は明示承認なしに追加しない。

## 5.1 検証ライブラリ

- ブラウザ等からコピーした画像は、macOS ペーストボード経由でインポートできる。
- インポート画像は `Application Support/newMosaic/Library/Originals/` へ PNG として保存する。
- モザイク適用後の検証画像は `Application Support/newMosaic/Library/Processed/` へ PNG として保存する。
- ライブラリ索引は `Application Support/newMosaic/Library/index.json` を正とし、元画像、加工後画像、ROI、画像サイズ、更新日時を管理する。
- ライブラリ保存は検証・再確認用途であり、外部送信は行わない。
- ライブラリからの削除は「選択画像を削除」ボタンまたはDeleteキーで行う（確認ダイアログ付き）。索引・元画像PNG・加工後PNGを完全削除する。Shift+クリック（範囲）/Cmd+クリック（個別追加）の複数選択で一括削除できる。

## 5.2 自動検出パイプラインの実装状況（2026-07-22 Phase 1 実装後）

- `PersonDetector`（`VisionPersonDetector`）: `VNGeneratePersonInstanceMaskRequest` により人物ごとの実位置と元画像サイズの人物シルエットマスクを取得する。Visionのインスタンス上限4件へ達した場合は `VNDetectHumanRectanglesRequest`（revision 2・全身矩形）を追加実行し、IoU/包含率による1対1対応でマスク付き人物を維持しながら5人目以降を補完する。両方0件の場合は0件を返す。Vision失敗はUnified Loggingへ診断を残す。
- `PoseEstimator`（`VisionPoseEstimator`）: 人物ごとに領域（矩形+15%マージン）をクロップして `VNDetectHumanBodyPoseRequest` を実行する。人物が横長ならクロップを左右90度回転した候補も評価し、元座標へ復元する。人物矩形内率、人物マスク近傍率、中心距離、confidence、関節数を複合評価し、他人物で採用済みの骨格との重複も除外する。低解像度クロップは拡大してから推論する。通常経路で得られない場合は顔検出を起点に、立位用と横臥用の長軸領域を再探索する。選択した骨格は一部関節がマスク外でも線が分断されないよう保持するが、候補採用には人物矩形内率60%以上・人物マスク近傍率60%以上を要求する。表示用骨格領域は人物検出領域と同じ `bodyBounds` を使う。
- `ROIGenerator`（`SensitiveROIGenerator`）: 関節からの解剖学的プライアでカテゴリ付きROIを人物ごとに生成。胸部（乳首）=肩必須。縦位置 `chestPositionRatio`（既定0.42、肩0〜腰1）、サイズ肩幅14%、横オフセット肩幅22%の左右2点（category `.nipple`）。鼠径部=**左右腰関節の両方検出が必須**で、腰中心から膝方向へ `groinPositionRatio`（既定0.45、UIスライダーで20〜80%へ事前補正可・UserDefaults永続化）のオフセット（category `.other`。性別分類器が未導入のため男女の判別は保留、Phase 2で対応予定）。関節なし・rootのみの固定比率フォールバックはBuild 24で廃止（低精度な巨大誤ROIを出さない=「検出していないものは表示しない」方針）。
- `CandidateDetector`（`SaliencyCandidateDetector`）: 自動候補ROIの周辺領域をクロップし、Visionオブジェクトネス顕著領域と整合すればROIを精密化する（整合しなければ元ROI維持=再現率優先）。実写向けの暫定実装。
- **アニメ部位検出（`AnimeCensorDetector`, Build 30〜）**: `DomainClassifier` がイラスト/漫画と判定した画像では、同梱の deepghs/anime_censor_detection（MIT, YOLOv8系ONNX）をONNX Runtimeでローカル実行し、乳首（nipple_f→`.nipple`）・性器（penis→`.maleGenital` / pussy→`.femaleGenital`）を**画像内容から直接検出**してカテゴリ付きROIを生成する。骨格ベース候補とはIoU 0.5で統合（内容ベース優先）。出力デコードは `YOLODecoder`（信頼度0.3・NMS IoU 0.7）。ライセンスは `Mosaic/THIRD_PARTY_NOTICES.md` 参照。
- **アニメシルエット/骨格（`AnimeSegmenter` Build 49〜 / `AnimePoseEstimator` Build 50〜）**: イラスト/漫画では skytnt/anime-seg（Apache-2.0, ISNet, 入力1024）のキャラクターマスクを人物矩形ごとに分配してシルエット表示し、yzd-v/DWPose（Apache-2.0, SimCC, 入力288x384）で人物ごとに骨格を推定する（体幹13点+neck/root合成、しきい値0.3、シルエットマスク内へ限定）。骨格が取れた人物は骨格レイヤと骨格ベース候補ROI（`SensitiveROIGenerator`）もアニメで生成される。
- **画像種別判定（`DomainModelClassifier`, Build 43〜）**: 自動判定は deepghs/anime_real_cls mobilenetv3_v1.4_dist（OpenRAIL, ONNX, 入力384x384, 2クラス[anime, real]）によるモデル判定を優先し、確信度をステータスへ表示する（例:「自動判定 97%」）。モデルが読み込めない場合は従来の統計ベース `DomainClassifier` へフォールバック。「画像種別」の手動指定は従来どおり最優先。
- **実写部位検出（`PhotoCensorDetector`, Build 38〜）**: 実写と判定した画像では、同梱の deepghs/nudenet_onnx 320n（Apache-2.0, NudeNet v3, YOLOv8n系ONNX, 入力320x320）をローカル実行し、実写でも乳首（FEMALE_BREAST_EXPOSED→`.nipple`）・性器（FEMALE/MALE_GENITALIA_EXPOSED→`.femaleGenital`/`.maleGenital`）・肛門（→`.other`）を**画像内容から直接検出**する（信頼度0.25）。18クラス中この4クラスのみ採用し、顔・足・着衣クラスは無視する。従来の実写経路は骨格からの位置推定のみで性器の内容ベース検出が無かった（「イラストは性器を認識するが実写だとできない」報告への対応）。**全体画像に加えて人物クロップ（1.15倍拡張）ごとにも推論し**（Build 39〜）、320px入力では全身写真の対象部位が数ピクセルに縮小され検出できない問題を解消（人物未検出時は20%重複の2x2タイルで代替。重複検出は同カテゴリ内IoU 0.45で信頼度の高い方へ統合）。しきい値はNudeNet公式実装と同じ0.2。骨格ベース候補とはIoU 0.5で統合（内容ベース優先）。`YOLOONNXModel` は入力解像度可変（censor/person=640, photo=320）。
- `SegmentEngine`（`Segmenting`）: `MosaicEngine.applyMosaic(to:rois:scale:segmentEngine:)` から呼び出される（§5.7）。
- 骨格ボーン表示・人物シルエット表示は**保留解除済み**: 骨格検出レイヤは矩形+関節点+ボーン線を、人物検出レイヤは破線矩形+シルエットマスク（青半透明）を表示する（§5.5）。
- 複数人物は実データで動作する（インスタンスマスク由来）。人物ごとの「人物N」レイヤ自動グループも実検出数に追従。
- 検出品質の改善計画は `Mosaic/DETECTION_IMPROVEMENT_PLAN.md` を正とする（実装ステータスも同書に記録）。

## 5.3 ライブラリUI / 編集操作

- アプリ上部はSF Symbolsの単一アイコンツールバーとmacOS標準メニューで、読み込み→候補生成→適用→保存の順に配置する。各アイコンはツールチップとアクセシビリティラベルを持つ。キャンバスはボタン、ピンチ、スクロールによるズーム/パンに対応する。
- ライブラリ画面は「グリッド（サムネイル、サイズ変更可）」「テキストのみ」「サムネイル付きリスト」の3表示モードを切替可能。
- グリッドはサムネイル比率に合わせた密な行高と最小余白を使う。表示モードとサムネイルサイズはUserDefaultsへ保存する。
- **リスト表示（テキスト/サムネイル）は列テーブル形式**（Build 68〜）: サムネイル/ファイル名/状態/解像度/ROI数/更新日時の6列（サムネイル列はサムネイル表示モードのみ表示）を横一列に並べる。列見出しクリックでその列の内容によりソートできる（`NSTableColumn.sortDescriptorPrototype`+`tableView(_:sortDescriptorsDidChange:)`）。
- **処理済みフラグフィルタ・テキスト検索フィルタ**（Build 68〜）: 表示モード切替の下に「すべて/未処理/処理済」の絞り込みとファイル名検索を配置する。フィルタ・検索・ソートを適用した表示専用配列 `displayedLibraryItems` を一覧・選択・カーソルキー移動が参照する（`libraryItems` はフィルタの影響を受けない全件の原本のまま。一括処理・学習データ書き出し等は全件を対象に動作する）。現バージョンではセッション内のみ保持（再起動で既定に戻る）。
- モザイク編集（ROI手動追加・自動候補生成・ROIクリア・モザイク適用・リサイズ・形状変更）はアンドゥ・リドゥ対応。画像を開き直すと編集履歴はクリアする。
- ROIは矩形・楕円・多角形の3形状に対応（`MosaicROI.shape: ROIShape`）。既存データ（`shape`キー無し）はデコード時に `.ellipse` を既定値として扱う。全形状が自由回転（回転ハンドル・45度スナップ）に対応し、多角形は頂点ドラッグ変形・Option+クリックでの頂点追加/削除（最少3頂点）ができる（Build 45〜46）。
- 手動追加時は直前にドラッグ／リサイズした形状ごとのサイズを記憶し、次回は同一形状でワンクリックすると記憶サイズでROIを配置できる（ドラッグすれば任意サイズで追加）。
- 既存ROIはクリックで選択→四隅ハンドルのドラッグでサイズ変更、形状ボタンで矩形⇄楕円を後から変更できる。
- 既存ROIは内側を左ドラッグすると位置を移動できる（サイズ維持、画像範囲内にクランプ。移動開始時にアンドゥスナップショットを1回記録）。
- 既存ROIはダブルクリックで削除できる（選択状態は問わない）。
- ウィンドウタイトルに `v<MARKETING_VERSION> (beta Build <CURRENT_PROJECT_VERSION>)` を表示する（`Bundle.main.infoDictionary` から取得）。

## 5.4 検出対象カテゴリ

- `MosaicROI.category: MosaicTargetCategory`（`nipple` / `femaleGenital` / `maleGenital` / `other`）でROIが対象とする部位を分類できる。既存データ（`category`キー無し）はデコード時に `.other` を既定値として扱う。
- ツールバーの「対象カテゴリ」は**複数チェック式の生成フィルタ**（Build 37〜）: 乳首/性器（女性）/性器（男性）/その他の各チェックと「人物」「骨格」チェックがあり、候補生成時にチェックされたカテゴリのROI・チェックされたレイヤ（人物検出/骨格検出）だけを生成する。設定は `UserDefaults`（`GenerateFilter.*`）で永続化。除外された候補件数はステータスに表示する。人物・骨格の内部検出はROI位置推定に必要なため常時実行され、チェックは生成物（表示レイヤ）にのみ影響する。
- 既存ROIのカテゴリ変更は、キャンバス上のROIを**右クリック→対象カテゴリメニュー**で行う（旧: ツールバーのカテゴリポップアップ。Build 37で生成フィルタへ置き換えたため移設）。新規手動ROIは「その他」で追加され、右クリックで変更する。
- アニメ部位検出（イラスト/漫画）は内容ベースでカテゴリを自動付与する（§5.2）。実写のカテゴリ自動付与は骨格ベースの位置推定（乳首）のみで、鼠径部推定ROIは「その他」。
- カテゴリはマスク生成アルゴリズム（`MosaicEngine`）の挙動には影響しない。形状（`shape`）のみがマスク形状を決定する。

## 5.5 検出レイヤの表示・グループ化（複数人物対応）

- 画像上に重畳するレイヤは「画像」「モザイク対象（ROI）」の固定2種類と、候補生成の都度動的に生成される「人物検出N」「骨格検出N」（N=検出順の番号）。個別に表示/非表示を切替できる。**レイヤパネル先頭の表示トグル**（「人物検出」「骨格検出」「ROI」チェックボックス。Build 37でツールバーから移設）は全人物・全骨格・ROIレイヤの一括ON/OFF、パネル内の一覧で個別制御。
- **レイヤ毎の輪郭/タグ表示**（Build 47〜）: 各レイヤ行の「輪郭」「タグ」ミニチェックで、枠線とラベル（名称・カテゴリ）を個別にON/OFFできる。人物シルエット・骨格ボーンはレイヤの表示チェックに連動（輪郭チェックは枠線のみ制御）。画像レイヤは対象外。設定はセッション内のみ保持。
- **ROI選択リスト**（Build 37〜）: レイヤパネルの「モザイク対象」配下に現在のROIを一覧表示する。行タイトルはカテゴリ名で、同一カテゴリ名のROIが複数ある場合のみ連番を付与する（例: 乳首 1 / 乳首 2）。行クリックでキャンバス上の該当ROIが選択され、キャンバス側の選択もリストへ同期する。ドラッグ移動中の毎フレーム再読込を避けるため、件数・カテゴリ構成が変わったときだけ再構築する。
- 右ペインは縦3分割（上=ライブラリ、中=レイヤ、下=モザイク設定インスペクタ）で常時表示する。キャンバスとの境界で右ペイン幅、各上下境界で高さを変更できる。ウィンドウ枠と分割位置は固有のautosave名で再起動後も復元し、初期比率は一度だけ適用する。
- 人物検出=青、骨格検出=橙の半透明色で、候補生成時に取得した検出領域を表示する。ライブラリ保存やモザイク処理には影響しない表示専用レイヤ。
- **複数人物・複数骨格の自動グループ化**: 候補生成のたびに人物ごとの「人物N」グループを作り、**骨格の関節が実際に検出できた人物のみ**骨格検出レイヤをグループへ追加する（Build 32〜。骨格が取れない人物へ固定比率のフォールバック矩形を骨格レイヤとして表示することはしない）。自動グループは候補生成のたびに作り直される（古い人物N/骨格Nレイヤは除去してから再構築するため、再生成しても重複・蓄積しない）。ステータスには骨格の実検出数を表示する。
- レイヤパネル（`NSOutlineView`）では2つ以上のレイヤを選択して手動で「グループ化」することもでき、複数レイヤをまとめて1つのマスターチェックボックス（3値: 全表示/全非表示/一部表示）で操作できる。「グループ解除」で個別レイヤに戻せる（各レイヤの直前の表示状態を保持）。**選択対象は未グループのレイヤに限らず、既存グループの内側にある子レイヤ（人物検出/骨格検出など）も選択して直接グループ化できる**（元の場所から取り除き、空になった元グループは自動削除。Build 65〜。以前は未グループの最上位レイヤのみが対象で、実質「画像」「モザイク対象」の2つしか選べず機能しないのと同じ状態だった）。
- グループ構成・表示状態はセッション内のみ保持され、アプリ再起動後は保持されない。画像切替時は人物検出N/骨格検出Nレイヤは除去されるが、「画像」「モザイク対象」レイヤの表示状態や手動グループは維持される。

## 5.6 画像切替の自動化（自動候補生成・自動保存・カーソルキー移動）

- ツールバーの「自動候補生成」チェックボックスがONの場合、画像を開く・貼り付け・ライブラリから切替表示するたびに自動的に候補生成を実行する。ただしライブラリの加工済みアイテムでROIが既に保存されている場合は、既存の編集内容を上書きしないよう自動生成をスキップする。
- 「自動保存」チェックボックスがONの場合、ライブラリ上でカーソルキー（上下左右）を押して別画像へ切り替えると、未保存の変更を自動的にライブラリの加工後スロットへ保存してから次の画像を表示する。
- 「自動保存」がOFFの場合、未保存の変更がある状態でカーソルキーによる画像切替を行うと確認ダイアログ（保存して次へ／保存せず次へ／キャンセル）を表示する。「未保存の変更」は、ROI手動追加・候補生成・クリア・モザイク適用・アンドゥ/リドゥなど編集操作を行った時点でONになり、保存（自動保存または「保存」ボタン）でOFFに戻るフラグで判定する。
- カーソルキーでの画像切替は `NSTableView` / `NSCollectionView` のサブクラスで矢印キーを直接処理する。マウスクリック、元画像/加工後を開く、ファイルを開く、貼り付け、現在画像の削除、ウィンドウを閉じる、アプリ終了の全経路で同じ未保存確認フローを使う。「保存しない」を選んだ状態はセッションキャッシュからも破棄し、後の再選択で復元しない。
- **並び順の安定化（Build 44〜）**: アイテムの集合が変わらない再読込（自動保存・上書き保存など）では現在の表示順を維持する。これによりカーソルキーで連続移動しながら自動保存しても一覧の並びは変わらない。「ライブラリ更新」ボタンは明示操作のため最新の並び（`updatedAt` 降順）で再読込し、画像の追加・削除時も最新順へ並び直す。

## 5.7 マスク生成方式の切替（SegmentEngine）

- `Segmenting` プロトコルは `createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage]` を持ち、`MosaicEngine.applyMosaic(to:rois:scale:segmentEngine:)` の引数として渡す。既定値は `ShapeSegmentEngine()` で後方互換を保つ。
- **`ShapeSegmentEngine`**: ROIの `shape`（矩形/楕円）だけからマスクを幾何学的に生成する。画像内容は参照しない。従来 `MosaicEngine` に内蔵されていたロジックをそのまま移設したもの。
- **`VisionPersonSegmentEngine`**: `VNGeneratePersonSegmentationRequest` を画像全体に対して1回実行し、得られた画素単位マスクをROIごとに切り出して使う（ROIごとにVisionを再実行しない設計）。Vision結果が得られない場合（macOS 14未満、人物が検出されない等）は `ShapeSegmentEngine` に自動フォールバックする。
- **`ForegroundSegmentEngine`**: `VNGenerateForegroundInstanceMaskRequest` で前景（人物・物体）の画素マスクを取得しROIごとに切り出す。SAM系外部モデルのローカル代替（Phase 3）。前景なしは図形ベースへフォールバック。
- 上記2エンジンは同じROI集合に対してマスクを生成するという点で機能が重複するため、ツールバーの「マスク生成」ポップアップでユーザーが明示的に切替えられるようにした（既定は「図形ベース」）。「モザイク適用」実行時に選択中の方式が使われる。
- `VisionPersonSegmentEngine` はVisionの実際のセグメンテーション結果を初めて活用する実装であり、§5.2で「discardしている」と述べていた課題の一部を解消するが、PersonDetector自体（矩形の実位置検出）やPoseEstimator（骨格検出）の固定比率ヒューリスティックはこの変更で置き換わっていない。

## 5.8 ローカル学習（Phase 4）

- `LearningEngine`（`Application Support/newMosaic/Learning/`）が、保存時に採用ROI（正例）と自動候補のうちユーザーが削除したROI（負例）を収集する。二重計上は控えIDで防止。
- 学習内容: カテゴリ別の (1) 選択位置頻度グリッド（8x8。人物検出があれば人物相対座標、無ければ画像相対座標）、(2) 平均サイズ、(3) ROIパッチの知覚ハッシュ（dHash 64bit）、(4) パッチPNG（最大256px縮小。将来の部位検出モデル学習データを兼ねる）。
- 推論時の反映（候補生成のたびに適用）:
  1. 位置頻度ブースト: 候補の中心が高頻度セルにあれば信頼度を加点（最大+0.3）。
  2. 近似画像参照: 候補パッチのdHashを正例群と照合（ハミング距離≤10で+0.2）、負例群と照合（距離≤6で−0.25）。Google画像検索型の類似画像検索をローカル完結の知覚ハッシュ近傍探索で代替した実装。
  3. 追加提案: 高頻度セル（サンプル5件以上・セル頻度30%以上）に候補が無ければ、記憶した平均サイズのROIを `learned-prior` として追加（最大8件）。
- 処理負荷: 集計は保存時のみO(全サンプル)。推論時はグリッド参照+ハッシュ線形走査で数千サンプルまで1ms級。外部送信なし・完全ローカル（§5、DEBUG_LOG_INVENTORY参照）。

## 5.9 画像ごとの編集状態保持とモザイク表示切替

- 画像（ライブラリアイテム）ごとの編集状態（ROI・検出レイヤの中身・アンドゥ/リドゥ履歴・モザイク表示状態・学習記録の控えID）を `PerImageEditState` としてセッション内キャッシュへ自動退避し、画像を切り替えて戻ってきたときに復元する。キャッシュは直近8画像のLRU（renderedImage保持によるメモリ増を抑制）。保存済みデータはライブラリ側に永続化されるため、キャッシュ破棄で失われるのは未保存の編集途中状態のみ。
- 「モザイク表示」チェックボックスで、モザイク適用見た目（未保存プレビュー）と元画像+ROI表示を切替できる。ONでは現在のROIと選択中のマスク生成方式で再レンダリングする。編集開始（ROIの追加/移動/リサイズ/削除）・候補生成・ROIクリアで自動的に解除され、元画像上で再編集できる。アンドゥ/リドゥは `EditorState.renderedImage` の有無とチェック状態を同期する。
- ライブラリ画像を開く際は作業画像を常に元画像とし、加工後画像は `renderedImage`（モザイク表示側）へ読み込む。これにより加工済み画像でも「解除→ROI再編集→再適用」が可能。「元画像を開く」でも保存済みROIを復元する（まっさらに戻すのは「ROIクリア」）。
- 「モザイク適用」ボタンは従来通りライブラリへの保存（確定）を伴う。「モザイク表示」トグルは保存を伴わないプレビュー専用。

## 5.10 モザイク描画スタイル（パターン×共通パラメータ）

- `MosaicStyle`（`MosaicCore/MosaicEngine.swift`）が描画スタイルを表す。②塗りつぶしパターン（`MosaicFillPattern`: モザイク/ノイズ/ボケ/線・エッジぼかし/アンシャープ（エッジ強調）/ボーダー縦・横・ランダム/雲/任意パターン画像の10種）と、①共通パラメータ（透明度・色付け・パターン細かさ・範囲輪郭ぼかし・ボーダー帯太さ/間隔・雲の密度/トーン化）の組み合わせで描画する。ボーダーランダムはシード固定乱数で帯幅・間隔±40%+斜め回転+ノイズ変位の揺れ、雲は白ノイズ2オクターブ合成+密度ガンマ+網点（トーン化ON時）で生成する。
- 合成順序: SegmentEngineのROIマスク →（ボーダー時）縞アルファマスクを乗算（帯=塗り、間隔=透明）→ 輪郭ぼかし（マスクへのガウスぼかし。塗りパッチはフェザー分拡張）→ 透明度（マスク輝度への乗算）→ `CIBlendWithMask` で元画像へ合成。マスク段で全パラメータを処理するため、任意のSegmentEngine（図形/人物/前景/ROI内前景）と任意のパターンを直交して組み合わせられる。
- 色付けは非ボーダーでは `CIColorMonochrome`（塗りを単色調へ）、ボーダーでは帯そのものの色。任意パターン画像は `CIAffineTile` で敷き詰め、細かさスライダーで拡縮する。
- `MosaicROI.style: MosaicROIStyle?` がROI単位の永続設定を保持する。nilは画面既定設定を継承する。選択ROIのインスペクタ変更はそのROIだけへ保存し、「全レイヤへ適用」で全ROIへコピーする。任意パターン画像はUUID識別子で `Application Support/newMosaic/Library/Patterns/<UUID>.png` に保存し、ライブラリ一式と同時に移行できる。既存JSONのstyle欠落と旧 `Application Support/newMosaic/Patterns/custom_pattern.png` は互換読込する。
- UI: 右側のモザイク設定インスペクタへ常時表示する。パターンポップアップは実処理を縮小描画したアイコンと名称を表示し、選択パターンに無関係な設定を無効化する。既定設定は `UserDefaults` へ保存し、モザイク表示中は即時再描画する。
- 従来の `applyMosaic(to:rois:scale:segmentEngine:)` は後方互換APIとして維持し、内部で既定スタイル（モザイク・不透明）に変換して新APIへ委譲する。

## 5.10.1 顔領域カテゴリとかぶせ画像（Build 56〜57）

- 検出対象カテゴリ「目元」（両目+眼窩上部）「眼窩下〜あご」を追加。実写は `FaceRegionDetector`（Visionランドマーク: 目・眉・輪郭）、アニメは `AnimePoseEstimator.faceRegionROIs`（DWPoseのCOCO-WholeBody顔68点）が、共通の `FaceRegionBuilder` で顔ごとの領域ROIを生成する（追加モデル不要）。対象カテゴリのチェックで生成ON/OFF。
- パターン「かぶせ画像（マスク・メガネ等）」（`overlayImage`）: 画像をROI矩形へ引き伸ばして1枚だけ重ねる（タイルしない）。PNG透過対応・回転追従・透明度調整可。目元→メガネ/グラサン/パーティーマスク、眼窩下→医療マスク/ガスマスク/犬の鼻口等のアクセサリ重ねを想定。ROI別スタイルと組み合わせて部位ごとに別画像を指定できる。モザイク等の既存パターンでの隠蔽も従来どおり。
- **バグ修正（Build 62）**: 「目元」「眼窩下〜あご」カテゴリのROIをVision系マスク生成方式（人物セグメンテーション/前景オブジェクト/対象の形状）で処理すると、モザイクが均一に適用されずまだらな色調になる不具合を修正した。原因は、これらのVisionベースのマスクが前髪など細部が重なる領域で完全不透明にならず部分的な半透明値を持つことがあり（`ShapeSegmentEngine.restrict` で形状範囲には正しく制限されているが、範囲内の値自体がまだらになりうる）、モザイクフィルとの合成時に元画像の色が透けて混ざり色調異常に見えていたこと。目元・眼窩下〜あごはメガネ等のアクセサリを重ねる/隠す用途で、そもそも被写体の実形状ではなく指定した矩形/楕円/多角形どおりに覆うべき領域であるため、`MosaicEngine.createMasks` でこの2カテゴリのみ選択中のマスク生成方式に関わらず常に図形ベース（`ShapeSegmentEngine`）を使うよう分離した（他カテゴリの挙動・選択中のマスク生成方式は変更なし）。

## 5.11 候補生成の非同期実行

- Vision/ONNXの人物・骨格・部位検出は `CandidateGenerationWorker` がバックグラウンドTaskで直列実行し、AppKit状態の反映だけをMainActorで行う。モデルインスタンスは同ワーカー内で再利用し、並行アクセスさせない。
- 実行中に画像が切り替わった場合はアイテムIDが一致しない結果を破棄する。切替先で自動生成要求が発生した場合は保留し、現在の推論完了後に再実行する。

## 5.12 ポータブル設定とサイドパネル配置

- 全アプリ設定は `AppSettings`（UserDefaults互換API）が、**アプリ本体と同じフォルダ**の `newMosaic_Settings/settings.json` へJSON保存する（Windowsの*.ini相当）。アプリ+設定フォルダをまとめて移動すれば他PCでも同じ設定で動作する。保存先が書き込めない場合は `Application Support/newMosaic/Settings/` へ自動フォールバック。既存UserDefaults設定は初回起動時に自動移行（Build 51）。モデルキャッシュのマーカーは機種ローカル情報のためUserDefaultsのまま。書き込みは連続変更（スライダー・分割ドラッグ等）対策として0.3秒デバウンスする（`scheduleSave()`）ため、`AppDelegate.applicationShouldTerminate` で `AppSettings.shared.persistNow()` を明示的に呼び、終了直前の変更がデバウンス待機中に失われないようにしている（Build 71〜。以前は変更直後にアプリを終了すると保存タイマーが発火せず設定が失われることがあった）。
- メイン分割は「左ペイン/キャンバス/右ペイン」。各ウィンドウ（ライブラリ/レイヤ/モザイク設定）は右上の「◀」「▶」で左右のサイドパネルへ移動でき、配置（`Layout.panelSide.*`）・ペイン幅・ペイン内分割位置・ウィンドウ枠はすべて `Layout.*` キーで保存・復元される（Build 51〜52）。空ペインは自動で畳む。
- **サイドパネル幅のドラッグ**（Build 63〜）: `mainSplitView` の境界ドラッグ可能範囲は `NSSplitViewDelegate` の `constrainMinCoordinate`/`constrainMaxCoordinate` で算出する（隣接ビューの現在フレーム＋最小幅）。Auto Layoutの `greaterThanOrEqualToConstant` 必須制約を併用するとNSSplitViewの独自フレーム操作と競合し、ドラッグ直後に元の幅へ戻される（「幅がまったく調整できない」不具合の原因だった）ため、幅制約は使わずdelegateのみで制御する。
- **非表示→表示切替時の幅確保**（Build 65〜）: `applyPanelAssignments()` は移動前後の `isHidden` を比較し、非表示だったペインが移動操作で表示に転じた場合は `NSSplitView.setPosition` で既定幅（左=280pt、右=`libraryTwoColumnPaneWidth()`）を明示的に割り当てる。`adjustSubviews()` だけでは幅0のまま残ることがあり、「サイドパネルを左へ移動すると表示されなくなる」不具合の原因だった。
- **再起動後の消失バグ対策**（Build 69〜）: `applyPanelAssignments()` は起動直後（`init()` 内、ウィンドウがまだ実ジオメトリを持たない時点）にも呼ばれるため、上記の「非表示→表示」判定はアプリ再起動時には成立しない（`isHidden` の初期値が既に`false`のため）。この場合、幅の実際の反映は後段の `applyInitialLayoutIfNeeded()`→`restoreSplitPositions()` に委ねられるが、当該ペインの保存幅（`Layout.leftPaneWidth`/`rightPaneWidth`）が一度もドラッグ保存されていない場合、他ペインの復元成功により `restoreSplitPositions()` が`true`を返しても当該ペインは幅0のまま気づかれず「左サイドバーが再起動後に表示されない」不具合になっていた。`applyInitialLayoutIfNeeded()` に、復元結果によらず表示状態のペインの実フレーム幅が50pt未満なら既定幅を強制する保険チェックを追加して解消した。
- **パネル移動時の幅引き継ぎ**（Build 69〜）: `movePanel(from:to:)` は、移動先サイドが現在空（他パネルが無い）の場合、移動元ペインの現在のフレーム幅を `applyPaneWidth(_:side:)` で移動先へそのまま引き継ぐ（`Layout.leftPaneWidth`/`rightPaneWidth` にも保存し次回起動時も維持）。移動先に既に他パネルがある場合は既存幅を尊重し、引き継ぎは行わない。
- **右パネルの工場初期値=ライブラリ2列幅**（Build 69〜）: `libraryTwoColumnPaneWidth()` が、ライブラリグリッドの既定アイテム幅（120pt）・アイテム間隔・セクション余白・スクロールバー・パネル内パディングから、サムネイルがちょうど2列になる幅を算出する。右サイドパネルが既定配置（`Layout.panelSide.*`未設定時は全パネルが右へ配置される）であるため、初回起動時・非表示→表示復帰時の右ペイン既定幅として使用する。
- **ツールバーアイコンの選択ハイライト**（Build 69〜）: `configureToolbarButton` の `bezelStyle` は `.texturedRounded`（20〜24pt想定の旧来ハイライト画像）から `.shadowlessSquare`（ボタンの実フレームいっぱいに矩形ハイライトを描く）へ変更。Build 66のアイコン拡大（正方形フレーム40〜58pt）後、旧スタイルではハイライトが横長に潰れて表示される不具合があった。

## 5.14 プロジェクトファイルと詳細設定

- ファイル＞設定＞「保存」/「読込」は `AppSettings.exportSnapshot()`/`importSnapshot(_:)` で全設定値（モザイクスタイル・レイアウト・検出設定・ライブラリ表示・アイコンサイズ等の `AppSettings` に保存されているすべてのキー）をJSONファイル（`.nmcf`, newMosaic Config の略。Win/Mac対応の4文字拡張子。旧`.newmosaicproj`は冗長のためBuild 66で短縮）として書き出し/読み込みする。読込後は `refreshAllUIFromSettings()` で画面上の全コントロールを再同期する。
- 「プロジェクト」サブメニューは最近保存/読込したプロジェクトを最大10件（同一パスは重複排除）表示し、`NSMenuDelegate.menuNeedsUpdate` でメニューを開く直前に再構築する。
- 「初期化」は確認ダイアログの上で `AppSettings.resetAll()`（全設定値を空にして次回起動時の既定値に戻す）を実行し、その場でUIへ反映する。ライブラリの画像・ROI（`LibraryEngine` 管理下）は対象外。UI反映を行う `refreshAllUIFromSettings()`（「読込」からも共通で呼ばれる）は、分割位置の復元に `applyInitialLayoutIfNeeded()` を使う（Build 70〜。旧実装は `restoreSplitPositions()` を直接呼んでおり、保存値が無い場合に分割位置が変更前のまま残ってしまい「レイアウトも既定値に戻る」という説明と食い違っていた）。
- **mainSplitViewの右ペイン幅設定・真因判明（Build 74で確定）**: `NSSplitView.setPosition(_:ofDividerAt:)` はプログラムからの呼び出しでも `NSSplitViewDelegate` の `constrainMinCoordinate`/`constrainMaxCoordinate` を経由して結果をクランプする。この2メソッドはインタラクティブなドラッグ操作を想定し、隣接ビューの「現在のフレーム値」を基準に計算するよう書かれているため、初期化・復元などプログラムによる一括レイアウト設定中（隣接ビューのフレームがまだ更新途中）に適用されると、意図しない位置へクランプされる（Build 73で追加した診断表示の実測値 `canvasW=200` が `constrainMinCoordinate` のキャンバス最小幅定数と完全一致したことで特定）。これがBuild 69〜72で右ペイン幅の既定化が繰り返し失敗していた真因であり、divider indexの選び方（0か`arrangedSubviews.count - 2`か）自体は無関係だった。
  - 対策: 既存の `isRestoringSplitPositions` フラグ（`splitViewDidResizeSubviews` の保存抑制用に導入済み）を `constrainMinCoordinate`/`constrainMaxCoordinate` でも参照し、フラグが立っている間はこの制約を適用しない。
  - 右ペイン幅を扱う全関数（`restoreSplitPositions()`・`setMainSplitRightPaneWidth(_:mainSplit:rightPane:)`・`applyPaneWidth()`・`applyPanelAssignments()`・`applyInitialLayoutIfNeeded()`）は、このフラグを `let wasRestoring = isRestoringSplitPositions; isRestoringSplitPositions = true; defer { isRestoringSplitPositions = wasRestoring }` という「呼び出し前の値へ復元する」パターンで設定・復元する。ネストした呼び出し（例: `applyInitialLayoutIfNeeded()` が内部で `restoreSplitPositions()` を呼ぶ）で内側の `defer` が外側のフラグを誤って `false` に戻さないようにするため。
  - `setMainSplitRightPaneWidth()` の「候補divider indexを順に試して実測で確定する」仕組み自体（Build 72で導入）は保険として維持しているが、根本原因はdivider indexではなくdelegateのクランプだったため、このフラグ対策のみでも通常は1回目の試行で正しく反映される。
  - 新たに `mainSplitView` 上でプログラム的に分割位置を設定するコードを追加する場合は、`isRestoringSplitPositions` を立てずに直接 `setPosition(_:ofDividerAt:)` を呼ばないこと（同じクランプ不具合が再発する）。
- 「詳細設定」ウィンドウはアイコンサイズ（小/中/大）とテキストサイズ（小/中/大）を持つ（Build 66〜）。ツールバーアイコンはSF Symbolsの `SymbolConfiguration(pointSize:)` とボタンの幅/高さ制約を動的に差し替えて見た目サイズを変更する（既定=中。小=18pt/40pt枠、中=23pt/48pt枠、大=28pt/58pt枠。Build 66で全体を一段階拡大し、既定値も大→中へ変更）。テキストサイズは `MosaicWindowController.textScale()`（小=0.8倍・中=1.0倍・大=1.25倍。Build 69で既定「中」を基準に再調整）を介して画面内のラベル・キャンバス描画テキストのフォントサイズへ反映する。静的コントロールは生成時に `applyScaledFont(_:size:weight:)` でフォント適用とレジストリ（`scaledTextControls`）登録を同時に行い、`textSizeChanged()` がレジストリを走査して全登録コントロールへ即時再適用する（Build 69〜、インスペクタ/レイヤ/ライブラリ両パネル・下部ステータス/ヘルプバー・詳細設定/画像出力ウィンドウ等を網羅）。ライブラリのテーブル/コレクションビューはセル再利用時（`NSTableView`/`NSCollectionView` の `makeView`/アイテム再利用）にもフォントを再適用するようにし、旧来の「静的な見出し等は次回起動時に反映」という制限を撤廃した。OSネイティブのツールチップ（`NSButton.toolTip`）はmacOSにフォント変更の公開APIが無いため対象外（アプリ独自のホバーヘルプ表示 `HoverHelpRelay`→ステータスバーは対象内、Build 66〜）。

## 5.13 フォルダ一括登録（リンク）と一括処理

- 「フォルダを一括登録」は選択フォルダ内の画像をコピーせず**リンク**（`MosaicLibraryItem.linkedOriginalPath`）としてライブラリへ登録する（Build 54）。ROI・レイヤ情報は従来どおり索引側で管理。リンクアイテムは🔗表示、参照先が無い場合は「⚠️リンク切れ」を赤字表示し、削除時も参照先の元ファイルは消えない。
- リンク切れ修正: リンク切れアイテムを選択して「リンク切れを修正」→ファイル指定の画像単位修正。未選択で実行→フォルダ指定のファイル名一致による一括修正（`repairBrokenLinks`）。
- 「一括処理」は未加工（加工後なし）かつリンク有効な全画像を、候補生成→モザイク適用（現在の既定スタイル・マスク生成方式・対象カテゴリ設定を使用）→ライブラリ保存で連続処理する（Build 55）。処理はバックグラウンドで実行され、シートに処理中件数・画像名・進捗バーをリアルタイム表示し、キャンセルボタンで途中中断できる（処理済み分は保存済みのまま残る）。

## 5.15 画像出力（多形式・プレビュー付き）

- 「画像出力」ウィンドウ（Build 64〜、旧「画像を書き出す」）はリサイズ可能な専用ウィンドウで、ファイル名（旧NSSavePanelの約2倍幅）・保存先フォルダ・出力形式・形式ごとの詳細設定・全体/中央拡大プレビューを1画面にまとめる。
- `MosaicCore.ImageExporter` が形式別の書き出しを一元化する。`jpg/png/bmp/gif/tiff/heic` はCGImageDestination（ImageIO標準）、`pdf`/`ai` はCGContextのPDFコンテキストへ画像をDPI換算のポイントサイズで配置する（`ai` はIllustratorが開けるPDF互換コンテナであり、本アプリはベクターパスを持たないためパスとしての編集はできない旨をUIに明記）。
- `PSDWriter`（自前実装, Adobe公開仕様準拠・RGB 8bit非圧縮RAWエンコード）は、`includeOriginalLayer` がtrueかつ元画像がある場合「元画像」（非表示）＋「モザイク適用」（表示）の2レイヤ構成で書き出す（本アプリの「元画像/モザイク適用結果」という2状態を活かした構成）。macOS標準ImageIOのPSDリーダーで読み戻し、統合画像のピクセルが正しいことをテスト済み。
- `EPSWriter`（自前実装）はJPEG圧縮した画像をPostScript Level 2のDCTDecodeフィルタへASCII85エンコードで埋め込む、標準的なラスターEPSを生成する（本アプリはベクターデータを持たないため真のベクターEPSは生成しない）。
- 共通オプション（`ImageExportOptions`）: 出力解像度（DPI, ImageIO/PDF/EPSへメタデータとして反映）、透明保持ON/OFF（OFF時は白背景へ合成してから出力）、jpg/heicのみ品質（圧縮率）。
- プレビューはjpg/heicのみ実際の品質設定でメモリ上エンコード→デコードした結果を表示し（保存前に圧縮アーティファクトを確認可能）、それ以外の形式は元画素をそのまま表示する。
- **CLIP/SAI/MDP（CLIP STUDIO PAINT/SAI/MediBang Paint）は仕様非公開の独自バイナリ形式のため対応しない**（ユーザー確認済み。2026-07-24）。

## 5.16 ショートカット管理（テンキー割当・ヘルプ一覧）

- `AppShortcut`（Build 67〜）が全ショートカット対応操作の唯一の情報源。id・分類（ファイル/編集/処理/表示/ライブラリ/一括処理）・タイトル・キー等価文字・修飾キー・「おすすめ」フラグ・action Selectorを持つ。表示文字列（例:「⌘O」）はkey/modifiersから自動生成し手入力しない。
- メインメニュー構築（`shortcutMenuItem`）・ツールバーのツールチップ（`shortcutToolbarButton`/`configureShortcutToolbarButton`）は両方ともこのレジストリを直接参照する。これにより表示（メニュー文言・ツールチップ）と実際の動作（keyEquivalent・action）が食い違うバグを構造的に防ぐ。
- **テンキー割当**（詳細設定＞「テンキー割当…」）: `NumpadKey`（macOS仮想キーコード82〜92, 65, 67, 69, 75, 76, 78, 81。トップ行の数字キーとは別の物理キー）を任意のショートカットへ割り当てられる。`NSMenuItem.keyEquivalent` は文字ベースの一致でテンキーとトップ行を区別できないため、`NSEvent.addLocalMonitorForEvents(matching: .keyDown)` でキーコードを直接判定してディスパッチする（`installNumpadShortcutMonitor()`、アプリ起動時に一度だけ設置）。割当は `AdvancedSettings.numpadAssignments`（キーコード文字列→ショートカットID の辞書）でポータブル設定へ保存。同じテンキーへの再割当は元の割当を自動解除する。
- **ヘルプ＞ショートカット一覧**: 先頭に「よく使うおすすめショートカット」（`isRecommended`）、続けて分類ごとにグループ表示する。テンキー割当があれば併記する。
- **Build 67でのコードレビュー修正**: 「モザイクを適用」（ライブラリへの保存を伴う）が、ツールチップに表示されないまま裸のReturnキー（修飾キーなし）に割り当てられていた。誤操作でライブラリを上書きしうる状態だったため、⌘Return（Command+Return）へ変更し、ツールバーのツールチップにも表示されるよう修正した。

## 5.17 バージョン表示方式（2026-07-25〜）

- 従来の `v<MARKETING_VERSION> (beta Build <CURRENT_PROJECT_VERSION>)` という2つの版数を併記する方式を廃止し、`MARKETING_VERSION`（`0.0.00000`形式の末尾5桁）だけをコード修正ごとにインクリメントするrunning単一カウンタへ一本化した。`CFBundleVersion` は内部的に同じ数値へ同期するが、UI（ウィンドウタイトル等）には表示しない。表示は `v0.0.00075` のように `v<MARKETING_VERSION>` のみ。

## 5.18 デバッグログ（ヘルプ＞デバッグ＞デバッグログ、2026-07-25〜）

- アプリ独自の永続ログファイルは持たず、macOS Unified Logging（`os.Logger`）へ出力する。`enum AppLog`（`Sources/NewMosaicApp/main.swift`）が subsystem `com.yoshikawa.newMosaic`（MosaicCore側のVision検出診断ログ§5.2と同一subsystem）で category `UI`/`Library`/`Export`/`Project` のロガーを提供する。記録対象はアプリ起動・エラーダイアログ表示・一括処理結果・画像出力成否・プロジェクト読込成否・設定初期化などのイベントのみで、画像内容やファイルパス（ファイル名を除く）、ROI座標は記録しない。
- 「ヘルプ＞デバッグ＞デバッグログ」ウィンドウ（`showDebugLogWindow()`）は `OSLogStore(scope: .currentProcessIdentifier)` で自プロセスの直近1時間分を取得し、上記4カテゴリとVision検出診断（`Detection`）をまとめて時刻順に一覧表示する。「更新」で再取得、「書き出し…」でテキストファイルへ保存できる（不具合報告時にログを共有しやすくする目的）。

## 5.19 ROI選択リストのグループ化（2026-07-25〜）

- `MosaicROI.roiGroupName: String?`（Codable、後方互換。旧JSONはnilとして読込）を追加し、同じ値を持つROIをレイヤ一覧のROI選択リスト上で1つのグループにまとめる。`ROIListGroup`（表示専用、`[ROIListEntry]`を保持）を新設し、`NSOutlineViewDataSource` の `.roi` リーフ配下を「グループ」＋「未グループ行」の二段構成へ拡張した。
- 既存の「グループ化」ボタン（`groupSelectedLayers()`）は、人物検出/骨格検出などの `LayerLeaf` 選択のみを対象としており、ROI選択リストの行（`ROIListEntry`。目元・乳首等）を複数選択して押しても常に無反応だった（型が異なり `as? LayerLeaf` に失敗するため）。ROI選択リスト側の選択も検出して `roiGroupName` を設定するよう修正し、レイヤ一覧の右クリックメニュー（`attachLayerContextMenu()`）からも「グループ化」（既存グループが混在する場合は「再グループ化」と表示）・「グループ解除」を実行できるようにした。

## 5.20 画像上のレイヤ選択同期・Command+ドラッグコピー（2026-07-25〜）

- `ImageCanvasView.selectedDetectionLayer`（`fileprivate`、`LayerKind?`）を追加。レイヤ一覧で人物検出/骨格検出レイヤの行を選択すると（`outlineViewSelectionDidChange`経由）、画像上の対応する矩形へ強調枠（`drawSelectedLayerHighlight(_:)`、アクセントカラーの太枠）を表示する。ROI選択リスト（`ROIListEntry`）は元から双方向同期済み（`syncROIListSelectionFromCanvas()`/`outlineViewSelectionDidChange`）。
- 画像上のROIをCommandキーを押しながらドラッグすると、ドラッグ開始時にROIを複製（新規UUID）してから移動する（Finderのオプションドラッグ相当。`ImageCanvasView.mouseDown`）。元のROIはその場に残る。

## 5.21 モザイクスタイル関連の細部修正（2026-07-25〜）

- **かぶせ画像の巻き添え不具合**: `MosaicEngine.applyMosaic` は、`requiresPatternImage` なパターンで画像が未解決の場合に即例外を投げる仕様のため、ライブプレビュー（`toggleMosaicPreview`/`resumeMosaicPreviewIfNeeded`）で1件でも未設定のROIがあると、他の設定対象でないレイヤのプレビューまで丸ごと解除されていた（例外で`mosaicPreviewCheckbox`がOFFになる）。`applyMosaic` に `skipIncompletePatterns: Bool = false` を追加し、プレビュー2箇所のみ `true` を渡して該当ROIだけスキップするよう変更（「モザイクを適用」の最終書き出しは従来通り厳格に例外を投げ、未設定のまま保存させない）。
- **パターン画像候補のレイヤタグ連動**: `choosePatternImage()` が、編集中ROIの `category` と一致する同梱素材（`OverlayAssetCatalog`）を「〜向けの素材」として先頭にまとめ、それ以外は「その他の同梱素材」として下にまとめるよう変更。
- **ノイズパターンのモノクロ化**: `CIRandomGenerator` はRGB各chが独立乱数でカラーノイズになるため、`CIColorControls(saturation: 0)` を追加してモノクロへ統一。プレビューアイコンは実エンジンを呼んで生成しているため自動的に追従する。
- **パターン選択のタイル表示化**: `stylePatternPopUp`（NSPopUpButton）は状態保持用として非表示のまま残し、UIは `makePatternTileGrid()` が生成するプレビューアイコンのタイル（1行4個、`patternTileButtons`）へ置き換えた。選択状態のハイライトは `updateMosaicStyleControlAvailability()` 内の `refreshPatternTileSelectionHighlight()` で同期し、各タイルはホバー時に `HoverHelpRelay` 経由でステータスバーへヘルプ文（パターン名）を表示する。
- **インスペクタ幅追従の修正**: モザイク詳細設定の7種のスライダー（透明度・細かさ・輪郭ぼかし・帯の太さ/間隔・雲の密度・鼠径部位置）に `lessThanOrEqualToConstant: 220` の必須最大幅制約を追加し、サイドパネルを広げても際限なく伸びないようにした。`styleRowLabel(_:)` を新設し、`styleGrid`（NSGridView）のラベル列の最小幅を `inspectorRow` と同じ78ptへ統一して左マージンのズレを解消した。
- **ツールバーアイコンの選択枠（Build時点でfocusRingType=.noneのみでは未解決。§5.22で`SquareIconButton`により最終解決）**: `configureToolbarButton` に `focusRingType = .none` を追加したが、ネイティブベゼル自体も大きな正方形フレームへ追従しないケースが残り、再発報告があった。
- **マスク生成の名称変更**: `SegmentEngineKind.displayName` を一般名称へ変更（図形（矩形/楕円）／人物の輪郭（AI自動認識）／物体の輪郭（自動抽出）／対象形状。最後の「対象形状」は「対象の形状（ROI内前景）」から短縮）。

## 5.22 UI再修正・ROIグループの画像上一括操作・自動回転（2026-07-25 v0.0.00076〜）

- **ツールバーアイコン選択枠の最終解決**: `.texturedRounded`/`.shadowlessSquare`ベゼルとフォーカスリングは、いずれもAppKit内部の既定寸法に依存した描画のため大きな正方形フレームへ追従せず、2回の異なる修正でも再発した。ネイティブのベゼル・フォーカスリングを一切使わない`SquareIconButton`（`NSButton`サブクラス。`isBordered = false`、`draw(_:)`内で`isHighlighted`時のみ`bounds`いっぱいに矩形ハイライトを自前描画）へ置き換え、サイズに依存しない描画へ変更した。`makeToolbarButton`/`shortcutToolbarButton`の両生成経路で使用する。
- **デバッグログのフリーズ修正**: `OSLogStore`の走査（システム全体を一旦スキャンしてから絞り込むため直近分でも数秒かかることがある）をメインスレッドで同期実行しており、ウィンドウを開く・更新するたびにUIが固まっていた。`refreshDebugLog()`/`exportDebugLog()`を`Task.detached`でバックグラウンド実行し、取得範囲も1時間→10分・最大500件へ縮小した。
- **ROIグループの画像上一括選択・一括移動**: `ImageCanvasView.selectedROIGroupIDs: Set<UUID>`を追加。レイヤ一覧で`ROIListGroup`（または複数の`ROIListEntry`）を選択すると、画像上でも該当ROI全てに強調枠（`drawSelectedLayerHighlight`）を表示し、いずれか1つをドラッグすると`GroupMoveState`により全ROIを同じ量だけ一括移動する。`outlineViewSelectionDidChange`で同期する。
- **レイヤ名の省略表示バグ**: `layerOutlineView`の唯一の列は`resizingMask = .autoresizingMask`だけではサイドパネルの分割ドラッグに追従せず、パネル幅が十分でも旧い（狭い）列幅のままトランケートされ続けていた。`splitViewDidResizeSubviews`と`reloadLayerList()`の両方で`layerOutlineView.sizeLastColumnToFit()`を呼ぶよう変更。
- **選択レイヤ情報のステータスバー移動**: インスペクタ上部にあった`selectedLayerStyleLabel`（NSTextField）を廃止し、`selectedLayerStatusSummary: String?`として下部ステータスバー（`updateStatsBar()`）へ統合。表記は「(既定設定を継承)」→「`<継承>`」、「(個別設定)」→「`<個別>`」に簡略化。レイヤ一覧のROI選択リスト行タイトル（`rebuildROIListEntries()`）にも、レイヤ名とモザイク種別の間へ同じフラグを追加した。
- **輪郭/タグ表示の一括化**: `LayerRowView`から行毎の`outlineCheckbox`/`tagCheckbox`ミニコントロールを削除（`LayerLeaf.showsOutline`/`showsTag`のモデル・canvas描画側は変更なし）。代わりにレイヤパネルの表示:設定へ`layerOutlineAllCheckbox`/`layerTagAllCheckbox`（全レイヤ一括の輪郭/タグ表示）を新設。「モザイク表示」（`mosaicPreviewCheckbox`）も「ワークフロー」からレイヤパネルの表示:行へ移動した。
- **モザイクパターン名・ボタン名の変更**: `MosaicFillPattern`の`.customImage`「パターン画像」、`.overlayImage`「マスク画像（マスク・メガネ等）」に変更。`applyStyleToAllButton`「全レイヤ適用」、`stylePatternImageButton`「画像選択...」に短縮。
- **候補生成時のROI自動回転**: `SensitiveROIGenerator`（胸部/鼠径部）に`tiltAngleDegrees`/`unitVector`ヘルパーを追加し、肩ライン/腰ラインの傾きを`MosaicROI.rotation`と横方向オフセット（肩ラインの単位ベクトル方向）へ反映。体が横臥・斜め姿勢のとき、ROI形状が認識範囲（体の向き）に沿うようになる。`FaceRegionBuilder`にも`tiltAngleDegrees(leftEyePoints:rightEyePoints:)`を追加し、Vision顔検出（`FaceRegionDetector`）の目元/眼窩下〜あごROIへ適用（アニメ向けDWPose経由の`AnimePoseEstimator.faceRegionROIs`は左右の目キーポイントが分離されておらず未対応のまま）。既存テスト（`roiGeneratorUsesPoseJointsForChestAndGroin`等）は水平姿勢（傾き0度）のフィクスチャのため回帰なし。
- **モザイク詳細設定の左マージン再修正**: `styleGrid`（NSGridView）は他のinspectorRow系の行と異なり内容から一意な幅が決まらず、親の`content`スタック（`alignment = .leading`だが`leadingAnchor`/`trailingAnchor`をdocumentへ両端固定しているため、intrinsicContentSizeが不定なビューは伸縮してしまう）内で幅いっぱいに引き伸ばされていたのが真因。`styleGrid.widthAnchor.constraint(lessThanOrEqualToConstant: 362)`（ラベル78+間隔8+スライダー220+間隔8+数値48の想定最大値）を追加して解消。
- **ライブラリの拡大縮小アイコン無効化**: `thumbSmallerButton`/`thumbLargerButton`をインスタンスプロパティ化し、`updateLibraryModeVisibility()`で`libraryViewMode == .thumbnailGrid`のときのみ有効化（テキスト/サムネイルリスト表示では意味を持たないため）。

## 5.23 コードレビュー由来の品質改善（2026-07-25 v0.0.00077〜）

- **`LibraryEngine`の並行アクセス安全化**: `loadItems()`→変更→`saveItems()`というread-modify-writeパターンに排他制御が無く、一括処理のバックグラウンドTaskとメインアクター側の単発保存（ROI保存・削除等）が同一インスタンスへ並行アクセスすると、後勝ちの`saveItems`で一方の更新が消えるTOCTOU競合があった（コードレビューで検出）。直列`DispatchQueue`を追加し、全mutatingメソッド（`importOriginal`/`saveProcessedImage`/`deleteItems`/`importLinked`/`relink`/`repairBrokenLinks`）をこのキュー上で実行するよう変更。キュー内から再度キューへ同期投入するとデッドロックするため、内部専用の`loadItemsUnsynchronized()`を分離した。`HistoryEngine.append`・`LearningEngine.record`（`appendToFile`の`seekToEnd()+write()`が非アトミック）にも同種の排他制御を追加。
- **`ImageCanvasView`のジェスチャー状態残留バグ**: `mouseDown()`が直前の未完了ジェスチャー（ウィンドウがキーを失う等でmouseUpを受け取れず中断したドラッグ）の状態をクリアしておらず、次のドラッグが古い状態を引き継いで別のROIを誤操作しうる不具合があった。`mouseDown()`冒頭で全ジェスチャー状態（`vertexDragState`/`rotationState`/`resizeState`/`moveState`/`groupMoveState`/`dragStart`/`dragCurrent`）を明示的にクリアするよう修正。
- **`MosaicEngine`の`CIEdges`クランプ順序**: `.edgeBlur`/`.unsharpEdges`の`edges`生成で、`CIEdges`等の近傍サンプリングフィルタを`clampedToExtent()`より前に適用しており、画像外周で透明領域との境界を偽エッジとして検出していた（`blurred`側は正しい順序）。`blurred`と同じ「clamp→filter」の順序へ統一。
- **`VisionPersonSegmentEngine`のフォールバック統一**: Vision実行を`try`（例外伝播）から`try?`へ変更し、`ForegroundSegmentEngine`/`RegionForegroundSegmentEngine`と同じ「失敗時はShapeSegmentEngineへフォールバック」という挙動に統一。
- **`MosaicStyle`のSendable対応・`NormalizedRect`のゼロ除算ガード・`patternImageCache`のLRU化・`AppSettings.persistNow()`のエラーログ・`outlineView(child:ofItem:)`のフォールバック安全化・`setWorkingImage`のforce-unwrap除去・`AnimePoseEstimator`の出力名不一致検知ログ**: いずれも小規模な堅牢性向上。詳細は `Docs/QC/CodeReview/QC_CodeReview_v0.0.00077.md` を参照。
- **見送った指摘（今後の対応候補）**: 6つのONNX推論クラスが個別に`ORTEnv`を生成している点（共有Env化は範囲が大きく別回で対応）、`AnimeSegmenter`の出力行方向が実測未検証な点、ONNX系検出器3クラスへのログ未追加、`importLinked`のO(n²)、`performLibraryAutoSave`/`exportConfirmed`のメインスレッド同期IO。いずれも詳細は上記QC記録を参照。

## 5.24 ツールバーのモード切替・レイヤ/グループ修正・パターン毎スタイル記憶（2026-07-26 v0.0.00078〜）

- **ツールバーの編集モード/範囲選択モード切替**: `ImageCanvasView.InteractionMode`（`.edit`/`.marqueeSelect`）を追加し、ツールバーの2segment `canvasModeControl`で切替える。既定は`.edit`（従来通り、空白ドラッグで新規ROIを作成）。`.marqueeSelect`では同じ空白ドラッグがラバーバンド矩形になり、矩形と交差する既存ROI全てを`selectedROIGroupIDs`へ一括選択する（`onROIGroupSelectionByMarquee`でレイヤ一覧選択にも同期）。Option(⌥)キーを押しながら開始したドラッグは、そのドラッグ限定で一時的にモードを入れ替える（`dragIsMarqueeSelect`をmouseDown時に判定）。マーキー矩形は新規ROI作成時の実線プレビュー（`drawPreviewShape`）と区別するため、破線+半透明塗り（`drawMarqueeSelectionRect`）で描画する。
- **レイヤパネルのテキスト左寄せ修正**: `LayerRowView.label`の`alignment`が明示指定されておらず右寄せ表示になっていた不具合を修正し、`.left`を明示設定。
- **グループ再作成時の連番バグ修正**: `roiGroupCounter`/`layerGroupCounter`という単調増加カウンタが原因で、グループ解除後に再度グループ化すると常に過去の番号から連番が振られていた。既存グループ名を避けた最小の未使用番号を採番する`nextAvailableGroupName(excluding:)`へ置き換えた。
- **グループ内個別選択時のグループ解除**: `ungroupSelectedGroup()`を拡張し、グループ名自体ではなく`LayerLeaf`/`ROIListEntry`を個別選択して「グループ解除」を押した場合は、その項目だけをグループから除外するようにした（空になったグループは自動的に消える）。グループ名選択時の全体解除は従来通り。右クリックメニューの表示条件（`updateLayerContextMenu`）も同様に拡張。
- **レイヤ表示トグルの表記・並び順**: 「人物検出」→「人物」、「骨格検出」→「骨格」、「モザイク表示」→「モザイク」に短縮（`LayerKind.title`・チェックボックスラベル・画像上のレイヤ名表示を統一）。「表示:」行の並びをROI・モザイク・人物・骨格の順に変更。
- **マスク生成のデフォルト変更**: `segmentEngineControl`の初期選択を`SegmentEngineKind.regionForeground`（対象形状）に変更。
- **モザイクパターン毎の詳細設定記憶**: 従来、透明度・色付け・粒度等の詳細設定はパターンをまたいだ単一のグローバル状態で保持されており、例えば色付き帯パターンから「ノイズ」へ切替えると、色付けチェックがONのまま引き継がれて「ノイズがカラーになる」ように見える不具合があった。UserDefaultsキーをパターン毎に名前空間分け（`mosaicStyleKeyPrefix(for:)`＝`"MosaicStyle.<pattern>."`）し、パターン切替時（`patternTileClicked`）に該当パターン専用の記憶済み設定（無ければ`MosaicStyle`の既定値）を`loadMosaicStyleDetails(for:)`で復元してから適用するよう変更。個別スタイル設定中のROIを選択したままパターンを切替えた場合、グローバルな既定スタイルまで書き換えないよう`canvas.selectedROIID == nil`のガードを追加。
- **ツールバー項目の整理**: 「ライブラリを更新」ボタンをツールバーからライブラリパネルの拡大縮小アイコンの右（`modeRow`）へ移設。「選択範囲をすべて消去」を「レイヤ削除」に改名し、ライブラリの「選択画像を削除」（`trash`アイコン）と区別するため`rectangle.badge.minus`アイコンへ変更。

## 5.25 検出・マスク生成バグ修正、パネル既定配置、フラッシュ/ボーダー統合（2026-07-26 v0.0.00079〜）

- **ライブラリのサムネイル拡大縮小アイコン統一**: `thumbSmallerButton`/`thumbLargerButton`が独自の`.texturedRounded`ベゼルで構築されており、キャンバスのズームボタン（`shortcutToolbarButton`経由の`SquareIconButton`）とサイズ・詳細設定「アイコンサイズ」への追従が食い違っていた。同じ`configureToolbarButton`経路で構築し直して統一。
- **乳首検出の誤ROIバグ**: `SensitiveROIGenerator.chestROIs`（v0.0.00076で追加したROI自動回転）が、肩ラインの傾き方向へROI中心まで投影オフセットしていたため、肩関節推定角度の僅かなずれで中心が実際の乳首位置から外れやすくなっていた。ずれたROIは直接検出器（`AnimeCensorDetector`等）の正しい検出とIoUベースの重複除去（`mergeCandidates`、閾値0.5）でマッチしなくなり、斜めにずれた誤ROIが正しいROIと並んで残る不具合があった。中心位置は水平オフセットのみ（回転導入前の位置式）へ戻し、`rotation`のみ肩の傾きへ反映するよう修正（`groinROI`は元々この方式で問題なし）。
- **回転ROIで「対象形状」が検知できないバグ**: `RegionForegroundSegmentEngine.regionMask`が無回転の`roi.rect`のみでVision用クロップを切り出しており、回転したROIでは実際の選択範囲とクロップ位置がずれ、対象物がクロップ外へ出て検知できないことがあった。回転後の外接矩形（`rotatedBoundingBox(of:rotationDegrees:)`）を基準にクロップするよう修正。他のマスク生成方式（`ShapeSegmentEngine`は回転を直接描画、`ForegroundSegmentEngine`/`VisionPersonSegmentEngine`は画像全体を処理してから回転対応の`ShapeSegmentEngine.restrict`で制限）は元々問題なし。
- **サイドパネル既定配置の修正**: 全パネル種別の既定サイドが一律「right」だったため、初期化するとインスペクタまで含めた3ウィンドウが右ペインへ詰め込まれ、右ペイン幅がアプリの大半を占める不具合があった（左ペインが空のまま非表示になり、右ペイン幅解決ロジックが想定していない状態に陥っていたのが真因）。`defaultPanelSide(for:)`を新設し、`.inspector`のみ既定「left」、`.library`/`.layers`は既定「right」に変更（右＝ライブラリ+レイヤ、左＝インスペクタ）。
- **ボーダー3パターンの統合**: `MosaicFillPattern`の`.stripesVertical`/`.stripesHorizontal`/`.stripesRandom`を`.border`1つへ統合し、`MosaicStyle`/`MosaicROIStyle`の`stripeVertical`（縦/横）・`stripeRandom`（ランダムON/OFF）・`stripeTone`（帯を元画像の網点変換で塗るON/OFF）で切替える方式に変更。既存ライブラリ/プロジェクトJSONとの互換性のため、`MosaicROIStyle`にカスタム`init(from decoder:)`を追加し、旧パターン名（`stripesVertical`等）を`.border`＋対応するフラグへ変換して読み込む。
- **フラッシュ（集中線）パターンの追加**: `MosaicFillPattern.flash`を新設。`MosaicEngine.flashLayer(style:roi:extent:)`が固定シードの乱数で放射状の線をCGContextに描画する（`SeededRandomGenerator`で再現性を確保、ボーダーランダムと同じ考え方）。中心位置は`MosaicStyle.flashCenter`（ROIローカル正規化座標、nilはROI中心）で保持し、`ImageCanvasView`上に十字マーク付きの黄色いハンドルを表示してドラッグで指定できる（`FlashCenterDragState`、回転ROIでも逆回転してローカル座標を計算）。フラッシュは中心位置がROIごとに異なるため、他パターンと違い`MosaicEngine`の`layerCache`（`MosaicROIStyle`をキーとする共有フィルキャッシュ）の対象から除外し、ROIごとに毎回生成する。
- **パターン表示名の変更**: 「雲」→「トーン」（`MosaicFillPattern.clouds.displayName`）、「トーン化（漫画トーン）」→「トーン」（`styleCloudToneCheckbox`のタイトル）。ボーダーの「トーン」チェックボックス（`styleBorderToneCheckbox`）も同名だが、雲パターンのトーン化とは別の実装（帯の塗りを元画像の網点変換にする）で、UI上は文脈（表示中のパターンの詳細設定）で区別される。

## 5.26 検出誤ROI抑制・モード切替UI調整・ボーダー/フラッシュ拡張（2026-07-26 v0.0.00080〜）

- **レイヤ名右寄せデグレの恒久対策**: `NSTextField`は`lineBreakMode`の設定がalignmentを既定へ戻すことがあるため、`LayerRowView.configure`で段落スタイル（左寄せ+末尾省略）を明示したNSAttributedStringを毎回設定する方式へ変更。
- **骨格由来乳首ROIの抑制**: v0.0.00079の位置修正でも、骨格推定による乳首ROI（source "pose-chest"、常に左右2個生成）は体勢によって位置・個数が実際と合わず誤ROIとして残った。部位検出モデル（AnimeCensorDetector/PhotoCensorDetector）が乳首を1つでも検出できた場合は骨格由来ROIを全て取り除き、検出器が見つけられなかった画像でのみフォールバックとして残す方針へ変更（`dropPoseChestPriors`）。
- **「レイヤ削除」の全レイヤ化**: `clearROIs()`がROIに加えて人物/骨格レイヤ（canvasの`personLayerRects`等の表示配列と、レイヤ一覧の`LayerLeaf`）も削除するよう拡張。人物・骨格レイヤはEditorState（アンドゥ）に含まれないため「元に戻す対象外」である旨をステータスに表示する。
- **モード切替アイコンとカーソル**: 編集モード=矩形破線（ROIを描くモード）、範囲選択モード=カーソル、に入替。画像上のカーソルは編集=crosshair（＋）、範囲選択=arrow で、Option(⌥)一時反転にも追従する。`flagsChanged`はファーストレスポンダにしか届かないためローカルイベントモニタで受け、`applyHoverCursor`（ROI上はopenHand優先）で統一的に設定する。
- **人物/骨格レイヤのダブルクリック削除**: `ImageCanvasView.detectionLayerHit`（骨格優先のヒットテスト）と`onDetectionLayerDeleteRequest`を追加し、ROIと同じダブルクリック操作でレイヤ一覧から該当レイヤを取り除く（表示配列はインデックス維持のため該当のみfalse化）。
- **ボーダーランダムの仕様変更**: 旧実装（斜め固定回転+ノイズ変位）を廃止し、「方向」設定（縦/横）に従った帯の太さ・間隔のみをランダム化する方式へ。新設の「並行揺れ」（`stripeWobble` 0〜1、最大±25度）は各線を線の中央を軸にランダムで傾ける。CGContextへの直接描画（帯毎に回転）で実装し、シード固定で再現性を保つ。
- **フラッシュの拡張**: `flashBeta`（集中線=白地に黒 / ベタフラッシュ=黒地に白）を追加。放射線は先細りの三角形で描き、本数は「密度」（`cloudDensity`をトーンと兼用）で調整、「トーン」（`cloudTone`兼用）ONで`CIDotScreen`の網点変換を適用。乱数シードをROIのIDから導出し、レイヤ毎に異なる形（同一ROIでは再現性あり）にした。
- **パターン詳細設定の行表示制御**: `styleGridView`への参照を保持し、`updateStyleGridRowVisibility(pattern:)`がNSGridViewの行（`row(at:).isHidden`）をパターン毎に切替える。共通行（透明度・塗りつぶし色・細かさ・輪郭ぼかし）以外は該当パターンでのみ表示され、「トーン」等の同名行が複数並ぶ問題も解消。
- **スライダー値ラベルの左寄せ**: 右寄せ+固定幅48ptでは数値が短いときスライダーとの間に不要な空白が見えるため左寄せへ変更（固定幅はドラッグ中のレイアウト揺れ防止のため維持）。

## 5.27 セグメンテーション反転修正・対象形状の輪郭復元・ウニフラッシュ・ツールバー再配置（2026-07-26 v0.0.00081〜）

- **レイヤ名左寄せの恒久対策（3回目）**: alignment指定（v78）・属性付き文字列の段落スタイル（v80）のいずれも環境により右寄せ表示が再発したため、テキストの寄せ設定に依存する方式を放棄。ラベルのtrailing制約を`lessThanOrEqualTo`（上限のみ）にしてフレーム幅=内容幅とし、チェックボックス直後へ左詰め配置する。テキストがフレーム内でどう寄っても見た目は左寄せになる。
- **AnimeSegmenterの行方向確定**: モデル出力の行方向は「入力と同一（行0=上）」とコメントで仮定していたが、実際は逆（行0=下）であることが「人物認識範囲が上下反転表示される」GUI報告で実測確定（コードレビューの「実測未検証」指摘項目）。読み出しループを上下反転。人物マスクは表示専用のため他経路への影響なし。実写経路（Vision）のマスク・矩形は`verticallyFlippedForRaster`/`normalizedRect(fromVisionRect:)`で補正済みで問題ないことを確認した。
- **対象形状の輪郭マスク復元**: v76の`ShapeSegmentEngine.restrict`導入により、楕円ROIでは前景マスクが楕円形状（放射グラデーション）でも切り取られ、対象物の輪郭どおりにマスクできなくなっていた（精度低下デグレの真因）。「対象形状」はROI図形を検索範囲としてのみ扱う意図のため、制限を回転対応の矩形マスク（`rectangleMask(rect:extent:rotation:)`）のみに変更。
- **フラッシュ種別の3択化**: `MosaicFlashKind`（line=集中線/beta=ベタフラッシュ/uni=ウニフラッシュ）を新設し、v80の一時形式`flashBeta: Bool`を置換（JSON/UserDefaultsとも読み込み互換あり）。ウニフラッシュはROIサイズを基準にした半径帯（内側30〜50%・外側90〜120%）へ両端が尖った紡錘形（ひし形）の線をリング状に描く。
- **人物へのモザイク**: レイヤ一覧の右クリックメニューに「モザイク対象に追加」（人物レイヤ選択時のみ表示）を追加。人物認識範囲から矩形ROI（source "person-layer"、カテゴリその他）を作成する。マスク生成「人物の輪郭」との併用でシルエットに沿ったマスクになる。
- **レイヤ一覧の表示順**: ルート項目を`rootLayerItems()`で モザイク対象→人物グループ/人物→骨格→画像 の順に構築（従来は画像が先頭）。
- **スライダー+設定値の隣接**: styleGridの列幅依存（他行の幅で間隔が変わる）をやめ、スライダーと値ラベルを1つのNSStackView（spacing 8）へまとめて行の第2列に配置。ボーダーのランダム/トーンも同様に1スタック（spacing 12）へ。
- **ツールバー再配置**: ライブラリ関連操作（リンク切れ修正・画像出力・Finderで表示）をライブラリパネルの操作行へ集約し、削除は誤操作防止のため行末尾へ。メインツールバーは ファイル系 | 一括処理→自動候補生成→適用→レイヤ削除 | 元に戻す/やり直す | モード切替 の並びに変更。名称変更:「候補を生成」→「自動候補生成」、「リンク切れを修正」→「リンク切れ修正」（`AppShortcut`レジストリ経由でメニュー・ツールチップ・ショートカット一覧へ自動反映）。

## 5.28 人物マスク表示の真因特定・レイヤ移動・対象形状の精度向上（2026-07-26 v0.0.00082〜）

- **人物マスク反転/鏡映の真因特定**: 合成マスク（既知位置の白領域）で`AnimeSegmenter.personMask`を実測テストし、マスク合成ロジックは正しい（上原点boundsどおりに制限・配置される）ことを証明した。真因は表示側: `NSImage.draw(in:from:operation:fraction:)`（4引数版）は`respectFlipped`の既定がfalseのため、flippedビューでは上下反転して描画される（`draw(in:)`単独版は補正するため、同じ方法で描く元画像は正常に見え、マスクだけ反転していた）。表示側へ`respectFlipped: true`を明示し、v81で行ったモデル出力の反転読み出し（誤修正）は元へ戻した。切り分けに使った実測テストは`AnimeSegmenterPlacementTests`として恒久化。
- **人物/骨格レイヤの選択+移動**: 枠線帯（±8px）のクリックで選択（`onDetectionLayerSelected`でレイヤ一覧と同期）し、ドラッグで移動できる（`DetectionMoveState`）。人物矩形は画面の大部分を覆うことがあるため、内側クリックまで奪うとROIの新規作成ができなくなる——枠帯のみを掴む設計。マスク画像・骨格ボーン/関節点の追従は毎フレームではなくドラッグ完了時に累積移動量でまとめて行う（`applyDetectionLayerMove`、`translatedMask`はCGContextへオフセット描画）。
- **対象形状の精度向上**: 小さな部位ROIのクロップはVisionの前景抽出・顕著領域の実効解像度が不足して輪郭が取れないため、短辺384px以上へ整数倍拡大してから推論する（マスクは後段でクロップ実サイズへスケールされるため座標系への影響なし）。顕著領域マスクはヒートマップのままでは「ぼやけた塊」にしかならないため、`CIColorThreshold`（0.35）で二値化してから軽くぼかし、対象物の形が出る硬めのマスクへ変更。

## 5.29 対象形状の当初実装復元・人物毎マスク推論・人物ROIのシルエットモザイク（2026-07-27 v0.0.00083〜）

- **対象形状の当初実装との差分レビュー**: 「実装当初は輪郭がかなり一致していた」報告を受け、Build 41（`2170d1a`）の`regionMask`と現在を比較。精度を下げた変更は (1) v76のROI形状（楕円）による切り取り（v81修正済み）、(2) v82の384px拡大入力（当初うまく動いていたVision前景抽出への入力を変えた）、(3) v82の顕著領域二値化（当初のソフトマスクを角張った塊に変えた）の3件。(2)(3)を撤去し、クロップ計算・顕著領域処理を当初と同一へ復元（回転ROIの外接矩形クロップのみ維持）。
- **人物毎マスク推論**: 全体画像1回の`characterMask`では2人目以降の小さい人物のマスクが取れないため、`personMaskByCrop`（人物矩形1.08倍クロップ→個別推論→全体フレーム配置→bounds制限）へ変更。人物数分の推論コストは増えるが、実効解像度の向上で検出率・輪郭精度が上がる。
- **人物ROIのシルエットモザイク**: 「モザイク対象に追加」で作るROIのsourceへ人物インデックスを埋め込み（"person-layer-N"）、`PersonLayerSegmentEngine`（Segmentingラッパー）が候補生成時の未着色シルエット（`personMaskImages`）をROI矩形制限付きで適用する。シルエットは表示用の着色版と別に保持し、画像切替の退避/復元・レイヤ移動の平行移動にも追従する。
- **範囲選択モードのレイヤ移動**: 編集モードは枠帯（±8px）のみ（内側はROI新規作成用）、範囲選択モードは新規作成と競合しないため矩形内側のどこでも掴める。

## 5.30 対象形状のスピル防止・形状しきい値・人物マスクのフォールバック・パネル保存（2026-07-27 v0.0.00084〜）

- **対象形状の制限方針**: v81で矩形制限へ変更したが、Visionがクロップ全面に近い塊しか返せない画像では楕円ROIの外（回転矩形の四隅）までモザイクが広がるため、最終制限をROI形状（`ShapeSegmentEngine.restrict`）へ戻した。輪郭が取れている場合は形状内にそのまま残るため、スピル防止を優先。補助として「形状しきい値」スライダー（`RegionForegroundSegmentEngine.maskThreshold`、既定0=自動のみ）を新設し、広がりすぎるマスクを任意で二値化して締められる。
- **人物毎マスクの分離失敗フォールバック**: クロップ個別推論はクロップ内を人物が占める割合が高いと全面マスク（背景巻き込み）を返すことがある。被覆率>0.92（`coverageRatio`、1/4縮小サンプリング）を分離失敗としてnilを返し、アプリ側で全体画像1回推論（遅延計算）+矩形切り出しへフォールバックする。
- **サイドパネルの確実な保存と初期幅クランプ**: 分割位置の保存はリサイズ通知経由に依存せず、終了直前に`saveSplitPositionsNow()`で明示保存。起動時はサイドペイン幅がウィンドウの50%を超える場合（保存値なしの初回起動で左ペインが全幅解決されるケース）に既定幅へ強制する。
- **動画対応プラグイン（基盤統合済み）**: 既存機能へ影響を与えない独立モジュール`MosaicVideoKit`（フレーム読出し/VNTrackObjectRequestによるROI追跡/モザイク付き再エンコード/キーフレーム検出+追跡のパイプライン）をv0.0.00085で統合。初期段階の制約: 音声なし・H.264出力。AVFoundationを使う処理の待機は全てタイムアウト付き（無期限セマフォ待機はテスト並列実行でスレッドプールを枯渇させ全体ハングを起こすため禁止。動画テストは`@Suite(.serialized)`で直列実行）。UI統合（ライブラリでの再生・動画ROI操作）は次段階で導入する。

## 5.31 状態保存の穴埋め・サイドパネルUIの統一・動画V2基盤（2026-07-27 v0.0.00086〜）

- **ウィンドウ枠の保存漏れ**: `windowDidEndLiveResize`はドラッグを伴うリサイズでしか発火しないため、ズーム（緑ボタン/タイトルバーのダブルクリック）でのサイズ変更が保存されなかった。`windowDidResize`を追加し、さらに`applicationShouldTerminate`でも現在のフレームを明示保存する（v0.0.00084で分割位置に施した対策と同じ考え方をウィンドウ枠へも適用）。
- **復元時の画面外クランプ**: 保存枠をそのまま`setFrame`すると、外部ディスプレイを外した後などにウィンドウが画面外へ開き操作不能になる。`frameClampedToVisibleScreen`で重なり面積が最大の画面の可視領域へサイズ・位置を収め、どの画面とも重ならない場合は既定位置へフォールバックする。
- **ワークフロー設定の永続化**: 「自動候補生成」「自動保存」だけがセッション限りだったため、`Workflow.autoGenerate`/`Workflow.autoSave`として保存・復元する。
- **サイドパネルUIの統一**: `NSGridView`は leading整列スタック内で幅を持たず伸長するため、`styleGrid`と同様に`categories`へも幅上限を付与。Layer/Libraryパネルのタイトル左右マージンを他の子ビューと同じ8ptへ統一。インスペクタを含むペインは、パターンタイル（44pt×4＋ラベル列）の必須制約に合わせて最小幅を340ptへ引き上げ（`minimumWidth(forPane:)`）。見出しは`inspectorHeading`経由へ統一し、テキストサイズ追従の漏れ（並行揺れ・形状しきい値）を解消。数値スライダーのツールチップとVoiceOverラベルのカバレッジを揃えた（`inspectorRow`が行ラベルを自動でVoiceOverラベルへ反映）。
  以後の新規UIは `Docs/QC/CodeReview/QC_CodeReview_v0.0.00086.md` の「推奨統一ルール」に従う。
- **動画V2基盤**: 動画のキーフレームROIは、静止画ライブラリの`index.json`へ埋め込まず、ライブラリ配下の`VideoEdits/<itemID>.json`へ`VideoEditStore`が保存する（既存スキーマ・読み書き経路へ影響を与えないプラグイン方式）。`VideoThumbnailProvider`はファイル更新日時込みキーのLRUキャッシュでサムネイルを提供し、ディスクへは書き出さない。

## 5.32 動画対応 V2: ライブラリ統合（2026-07-27 v0.0.00087〜）

- **データモデル**: `MosaicLibraryItem`へ`kind`（image/video）と`videoDurationSeconds`のみを追加し、キーフレームROI等の動画固有情報は`index.json`へ入れない（`MosaicVideoKit.VideoEditStore`のサイドカーJSONが持つ）。カスタム`init(from:)`で既存JSONを`.image`として読む後方互換を担保する。
- **登録方式**: 動画は常にリンク登録（`importLinkedVideo`）。本体をライブラリへコピーしないため容量が増えず、リンク切れ修正の既存導線がそのまま使える。解像度・尺は`MosaicVideoKit.VideoFrameReader.loadInfo()`で取得する（デコードを伴うためバックグラウンド実行）。
- **一覧表示**: 動画は🎬バッジ＋代表フレームのサムネイル（`VideoThumbnailProvider`。ディスクへは書き出さない）＋解像度欄に尺を併記。状態欄は「動画」「動画済」。
- **プレビュー再生**: AVKitの`AVPlayerView`はSwiftPMの実行ファイルターゲットからリンクできない（SwiftUICoreへの暗黙依存）ため使用せず、`AVPlayerLayer`＋自前の最小コントロール（再生/一時停止・シーク・時刻）で`VideoPreviewView`を構成する。時刻オブザーバはdeinitから`@MainActor`隔離プロパティへ触れられないため、ウィンドウを閉じる際の`stop()`で明示解除する。
- **編集導線の分離**: V2では動画を作業画像として開かず（静止画として読めないため）プレビューへ回す。キャンバスでのキーフレーム編集はV3で追加する。

## 5.33 動画対応 V3: キーフレーム編集UI（2026-07-27 v0.0.00088〜）

- **編集の考え方**: 動画は「時刻→フレーム画像」を静止画キャンバスへ流し込むだけで、ROI編集・モザイク設定は静止画と同一のコード（`ImageCanvasView`・インスペクタ）をそのまま使う。動画専用の編集UIを別に作らないことで、機能差・実装揺れが生じないようにする。
- **レイアウト**: キャンバスを`canvasContainer`で包み、下部に`videoTimelineBar`を積む。静止画では`isHidden`で従来と同じ見た目。分割ビューの最小/最大幅判定もコンテナ基準へ変更した。
- **キーフレーム**: 「現在時刻のROI群」を`VideoEditState`へ`upsert`し、`VideoEditStore`（サイドカーJSON）へ保存する。動画本体は再エンコードしない。時刻±0.01秒は同一キーフレームとして丸ごと置き換える。
- **追跡プレビュー**: 毎回のシークで自動追跡すると重いため、明示操作（⌘T）とした。直前キーフレームから現在時刻まで`VideoROITracker`をバックグラウンドで進め、目標フレーム到達時は`readFrames`のハンドラから内部シグナル（`TrackingPreviewStop`）を投げて走査を打ち切る。完了時に対象の動画・時刻が変わっていない場合のみ反映する（非同期完了時の取り違え防止）。
- **ロスト表示**: 見失ったROIは`ImageCanvasView.trackingLostROIIDs`へ入れ、黄色破線（`drawTrackingLostWarning`）で警告表示する。位置は直前フレームのまま保持されるため、ユーザーが直して「キーフレーム追加」すればそこが新しい追跡起点になる。

## 5.34 動画対応 V4: 書き出しUI・音声パススルー（2026-07-27 v0.0.00089〜）

- **ROIの供給方式**: 書き出しは`VideoMosaicExporter.export`の`roiProvider`へ「フレーム番号→そのフレームのROI」を返すクロージャを渡す。キーフレーム区間が切り替わった時だけ`VideoROITracker.start`し直し、区間内は`track`で追随させる（キーフレーム＝追跡の起点。V3のプレビューと同じ考え方を書き出しでも使う）。
- **音声パススルー**: モザイクは映像のみが対象のため、音声は`AVAssetReaderTrackOutput`/`AVAssetWriterInput`とも`outputSettings: nil`（無変換）でサンプルバッファをそのまま書き写す（`AudioPassthrough`）。再エンコードしないため音質が劣化せず、処理も軽い。音声トラックが無い動画では何もしない。
- **待機の原則を踏襲**: 音声転送のスピン待ちも30秒デッドライン＋キャンセル判定付き。無期限待機は禁止（v0.0.00085の全体ハングの教訓）。
- **キャンセル/失敗の後始末**: どちらの場合も出力ファイルを削除し、中途半端なファイルを残さない。キャンセルはエラーダイアログを出さずステータス表示のみとする。

## 5.35 「対象形状」の初期実装を比較用に併存（2026-07-28 v0.0.00090〜）

- **経緯**: 「対象形状の精度がリリース初期より悪い」というGUI報告に対し、初期実装（Build 41、コミット`2170d1a`）と現行の差分を再確認した。クロップ範囲・前景抽出・顕著領域マスクはv0.0.00083で当時と同一へ復元済みで、**残る差分は最終段の制限方法のみ**だった。
  - 初期実装: `mask.cropped(to: roiRect)` — ROIの**矩形**で切る。楕円ROIでも対象物の輪郭がそのまま残る。
  - 現行（v0.0.00084〜）: `ShapeSegmentEngine.restrict` — ROIの**形状マスク**を乗算する。楕円マスクは`CIRadialGradient`（半径0.44で白→0.50で黒）のため、ROI矩形の隅へ向かってマスクが減衰し、対象物の輪郭が縁で欠ける。ROI外へのはみ出し（v0.0.00084で修正した症状）は防げるが、縁いっぱいまで対象物が写るROIでは精度低下として現れる。
- **対応**: どちらが良いかは画像によって変わるため、片方を消さずに`SegmentEngineKind.regionForegroundLegacy`（表示名「対象形状（初期実装・比較用）」）として併存させ、ユーザーが同じ画像で切り替えて比較できるようにした。実装差は最終段のみで、他の処理は現行と共通コードを使う。
- **実測の恒久化**: 楕円ROIの隅で現行方式は輝度100未満まで減衰し、矩形クロップ方式は200超を維持することをテスト（`ellipseShapeRestrictionAttenuatesMaskNearROICorners`）で固定した。今後どちらを既定にするか判断する際の根拠として残す。

## 5.36 初期実装エンジンの回転対応（2026-07-28 v0.0.00091〜）

- **症状**: 「対象形状（初期実装・比較用）」で、傾いた選択範囲に対してマスクが軸並行の四角いブロックになる（GUI報告）。
- **真因**: 初期実装（Build 41）は選択範囲の回転機能が導入される前（`5f2169f`）のコードで、`roi.rotation`を一切参照していない。そのまま復元したため、回転ROIでは (1) クロップ範囲が`roi.rect`（無回転）基準で実際の傾いた範囲から外れる (2) 最終の`cropped(to: roiRect)`も無回転の矩形で切る、という二重のずれが出ていた。
- **対応**: クロップは回転後の外接矩形基準へ、最終制限は`ShapeSegmentEngine.rectangleMask(rect:extent:rotation:)`（**二値**の回転矩形マスク）の乗算へ変更した。`rectangleMask`は白/黒の二値なので、現行の楕円マスク（`CIRadialGradient`）と違い縁でマスクが薄くならず、初期実装の「対象物の輪郭がそのまま残る」性質は保たれる。
- **整理（3方式の違い）**:
  | 方式 | 縁の減衰 | 回転追従 | ROI外へのはみ出し |
  |---|---|---|---|
  | 初期実装（当時のまま） | なし | **なし（不具合）** | 矩形内に収まる |
  | 初期実装（v0.0.00091〜） | なし | あり | 回転矩形内に収まる |
  | 現行「対象形状」 | **あり（楕円は放射グラデーション）** | あり | ROI形状内に収まる |

## 5.37 「対象形状」の輪郭抽出を実測データに基づき再設計（2026-07-28 v0.0.00093〜）

- **実測で判明した事実**（v0.0.00092の診断ログをユーザー実機で取得）:
  - 大きめのROI（100〜270px四方）では `foreground=yes` だが被覆率0.78〜0.88 ＝ **クロップのほぼ全面が「前景」**。Visionの前景抽出は「被写体 vs 背景」を分離するもので、体の内部にある部位（性器・乳首）は周囲に背景が無いため原理的に分離できない。
  - 小さいROI（28〜41px四方）では `foreground=no` かつ顕著領域も被覆率0.00 ＝ **マスクが空**。空マスクをそのまま採用していたため、**モザイクが一切掛からない検閲漏れ**が発生していた。
- **被覆率測定のバグ**: `coverageRatio`がsRGB（ガンマあり）で平均値を読み出していたため、面積比が過大に出ていた（白60%の二値マスクが0.80と測定される）。しきい値判定の前提が崩れていたため、リニア色空間での読み出しへ修正した。
- **線画向けアルゴリズムの追加**: `inkDensityMask`（グレースケール→`CIEdges`→`CIMorphologyMaximum`＋ブラーで線を面へ→`CIColorThreshold`）。漫画では対象部位が周囲の平坦な肌より線・網点が密という性質を利用する。合成線画テストで、平坦な白地の中から線の密な領域のみを取り出せることを実測確認した。
- **採用ロジックの変更**: 「前景→（全面なら）顕著領域」の先着順から、**3候補（前景/描き込み密度/顕著領域）のうち有効帯に入るもので被覆率が最小＝最も対象を絞り込めているもの**を採る方式へ。
  - 下限`minimumUsableCoverage`=0.03: 空マスクを弾く（採用すると検閲漏れになるため必須）。
  - 上限`maximumUsableCoverage`=0.64: クロップはROIの1.15倍（面積1.32倍）のため、マスクがROIと一致すると被覆率は約0.76。その85%を上限とし「ROIを丸ごと塗るだけ」のマスクを弾く。
  - どれも使えない場合は図形ベースへフォールバックし、ROIは必ず塗られる（検閲漏れを構造的に防ぐ）。

## 5.38 「対象形状」に輪郭線ベースの領域抽出を追加（2026-07-28 v0.0.00094〜）

- **経緯**: v0.0.00093で追加した「描き込み密度」方式は、線の密度が高い領域を拾うため、対象部位の周囲にある陰影・しずき・効果線など「線は多いが別物」の領域まで巻き込むことがGUI確認で判明した。
- **輪郭線ベースの領域抽出（`inkBoundedRegionMask`）**: 漫画は対象部位が輪郭線（濃い線）で囲まれて描かれるという構造的性質を利用する。クロップをグレースケール化し、明暗レンジに対する相対しきい値（レンジの45%）で線を判定、ROI中心を種として4近傍で領域拡張する。斜め近傍を含めると細い線の隙間から漏れるため4近傍とする。囲っていた輪郭線自体もモザイク対象に含めるため、結果を1画素太らせる。
  - 紙の白さやトーンの濃さに依存しないよう、しきい値は固定値ではなくクロップ内の明暗レンジから決める。
  - 明暗差が24未満（＝線が無い）の場合はnilを返し、写真の平坦部などで誤って全面を塗らないようにする。
  - 輪郭が途切れて外へ漏れた場合は被覆率が跳ね上がるため、有効帯（0.03〜0.64）で自然に弾かれ、従来方式へフォールバックする。
- **候補の優先順**: 輪郭線領域 → Vision前景抽出 → 描き込み密度 → 顕著領域。有効帯に入る最初のものを採用する（v0.0.00093の「被覆率最小」から変更。線画では輪郭線領域が意味的に最も正しいため、単純な数値比較より優先順が適切と判断した）。
- **検証**: 合成線画（閉じた円＋外側の無関係な短い線群）で、円の内側だけが塗られ外側を巻き込まないこと、平坦な画像では有効帯で弾かれることを実測テストで固定した。

## 5.39 検出設定のレイヤ個別適用（2026-07-29 v0.0.00095〜）

- **背景**: マスク生成方式やしきい値は全体設定として1つしか持てず、値を変えると全ROIのマスクが作り直された。1レイヤだけ方式を変えたいとき、調整済みの他レイヤまで巻き添えで変わってしまう。
- **モデル**: `MosaicROI`へ`maskEngine`（`SegmentEngineKind`のrawValue）と`maskThreshold`を追加。nilは全体設定を継承する。永続化はライブラリJSONへ同居し、旧JSONはキー欠落でnil（継承）として読む。
- **振り分け**: `PerROISegmentEngine`が、個別設定を持つROIを「方式＋しきい値」ごとにグループ化して専用エンジンへ、持たないROIを全体設定のエンジンへ渡す。ROIごとに個別呼び出しすると推論回数が件数分に増えるため、同一設定はまとめて1回に渡す。`PersonLayerSegmentEngine`の内側に入るため、人物レイヤ由来ROIのシルエットマスク優先は維持される。
- **UI**: 「検出」見出しの先頭に「個別」チェック（既定ON、`Detection.individual`へ永続化）。ONかつレイヤ選択があるとき、マスク生成方式・形状しきい値の変更は選択中ROIへ書き込まれ、全体設定（AppSettings）は変更しない。レイヤ選択時はそのROIの個別設定をインスペクタ表示へ反映し、表示値と書き込み値の不一致を防ぐ。
- **既定値**: `Layer.mosaicVisibleDefault`（既定true）でモザイク表示ONから開始。`Workflow.autoGenerate` / `Workflow.autoSave` も既定trueへ変更した。

## 5.40 マスク生成の実測所見（v0.0.00095時点・未解決）

- `censor_detect.onnx` / `photo_censor_detect.onnx` はYOLO系の**検出（バウンディングボックス）モデル**であり、出力は`[cx, cy, w, h, クラススコア…]`のみ。**形状（セグメンテーション）マスクは出力しない**。ROIの形状は常に`.ellipse`固定で生成される。
- したがって「性器の形状マスク」に使える学習モデルは存在せず、形状はVisionの汎用API（前景インスタンス/顕著領域）と画像処理で近似している。Visionの前景抽出は**被写体と背景**を分ける目的のため、被写体内部にある性器・乳首は分離対象にならない（実測ログで`fgCoverage=0.80〜0.83`＝クロップのほぼ全面）。これが「1回で形状が決まらない」構造的な理由である。
- ROI内適用処理の変遷（当初実装との差分）: 当初（`2170d1a`）は`mask.cropped(to: roiRect)`による**矩形ハードクロップ**のみ。現在は`ShapeSegmentEngine.restrict`による**形状（楕円/回転）制限**であり、加えて候補選択が「前景→顕著領域の2段」から「輪郭線領域→前景→描き込み密度→顕著領域の優先順＋被覆率有効帯」へ変わっている。比較用に`regionForegroundLegacy`（当初実装＋回転対応）を残している。

## 5.41 「対象形状」の性器マスク品質: 初期実装との差分検証（2026-07-29 v0.0.00096）

「初期実装なら性器形状が正しく取れていた」という前提で戻し作業を繰り返したため、実測で検証した結果を記録する。**この節の調査でアルゴリズムは変更していない。**

### 検証1: 性器ROIのジオメトリは初期実装から変わっていない

- 性器ROIは `AnimeCensorDetector` / `PhotoCensorDetector` が返す `detection.rect` をそのまま使い、`rotation` は付かず、拡大もしない。
- 自動回転（v0.0.00076）が `rotation` を設定するのは `pose-chest`（乳首）と `pose-groin`（鼠径部・カテゴリは`.other`）のみ。**性器ROIには回転が入らない。**
- `LearningEngine.refineCandidates` は `confidence` のみ変更し、`rect` は変更しない。
- → 「矩形形状の回転対応が性器の認識精度を落とした」という仮説は成り立たない。

### 検証2: v0.0.00091の「初期実装・比較用」は忠実な再現だった

当時（`2170d1a`）との一致を確認した項目:

| 項目 | 初期実装 | v0.0.00091の比較用エンジン |
|---|---|---|
| 被覆率の測定色空間 | sRGB | sRGB（ガンマ修正はv0.0.00093） |
| 顕著領域への切替しきい値 | 0.85 | 0.85 |
| `saliencyMask` | contrast 2.2 / blur 1.5 のソフトなヒートマップ | 同一コード |
| ROI内の制限 | `cropped(to: roiRect)` | `rectangleMask`（白黒二値、無回転時は等価） |

忠実な再現であるにもかかわらず品質が改善しなかったため、**戻すべきアルゴリズムの差分は存在しない**。以降「初期実装へ戻す」方向の変更は行わない。

### 検証3: 初期実装が実際に行っていた処理

Visionの前景抽出は性器クロップに対し実面積比0.80前後を返す（実機ログ実測）。これをsRGBで測ると以下になる（`CoverageCalibrationTests`で実測固定）。

| 実面積比 | sRGB測定 | リニア測定 | 初期実装で顕著領域へ切替(>0.85) |
|---|---|---|---|
| 0.60 | 0.796 | 0.600 | no |
| 0.69 | 0.847 | 0.690 | no |
| 0.75 | 0.882 | 0.749 | **YES** |
| 0.80 | 0.906 | 0.800 | **YES** |
| 0.83 | 0.922 | 0.831 | **YES** |

つまり初期実装は、性器クロップに対して**前景マスクを実質的に一度も採用しておらず、必ず顕著領域ヒートマップへ切り替えていた**。そのヒートマップはソフトなグラデーションで、形状制限の乗算も無かったため、対象を中心に濃く周辺へ薄くなるモザイクになる。「形状に沿っていた」という印象はこの濃度勾配によるものと考えられ、画素単位の形状抽出が成立していたわけではない。

### 検証4: v0.0.00093で比較用エンジンの挙動が変わっている（未修正）

ガンマ修正で `coverageRatio` をリニア測定へ変更した際、`LegacyRegionForegroundSegmentEngine` のしきい値0.85を据え置いた。切替が起きる実面積比が **0.69 → 0.85** へ上がり、実測値0.80/0.83が切替対象から外れている。比較用エンジンはv0.0.00091と異なる挙動になっており、当時の再現として使えない。修正するならしきい値をリニア基準の0.70へ換算する（既定の「対象形状」には影響させない）。

## 5.42 学習モデルによる部位形状抽出（2026-07-29 v0.0.00097〜）

§5.40 / §5.41 の実測結果（同梱検出モデルは枠しか出さず、Visionの前景抽出は被写体内部の部位を分離できない）を受け、形状そのものを学習したモデルを使う経路を追加した。**既存のマスク生成方式・既定値は変更していない。**

- **デコード（`YOLOSegDecoder`）**: YOLOv8/YOLO11-seg のONNXは出力が2本ある。`output0` = `(1, 4+クラス数+32, アンカー数)`（枠・クラススコア・マスク係数）、`output1` = `(1, 32, protoH, protoW)`（マスクのプロトタイプ）。マスクは `sigmoid(Σ 係数ᵢ × プロトタイプᵢ)` で合成し、検出枠の外は0にする（枠外を残すと他部位のマスクが混ざる）。出力要素数が合わない場合（検出専用モデルを渡した等）は空を返し、クラッシュさせない。
- **実行（`PartSegmentationDetector`）**: モデルは**同梱しない**。`~/Library/Application Support/newMosaic/Models/part_seg.onnx` にあれば有効。プロトタイプ解像度は入力の1/4。レターボックスのパディング分を切り落としてから元画像サイズへ拡大することで、マスクの位置ずれを防ぐ。出力が2本ない場合は「検出専用モデルを配置していないか」を示すエラーにする。推論は完全ローカル。
- **エンジン（`LearnedShapeSegmentEngine` / `SegmentEngineKind.learnedShape`）**: 画像ごとに1回推論し、各ROIへIoU 0.2以上で対応付ける（同カテゴリを優先）。マスクはROIの**矩形**（回転対応・白黒二値）で制限する。楕円マスクで制限すると放射グラデーションのため輪郭が縁へ向かって薄まる（§5.41）。モデル未導入・推論失敗・被覆率0.02未満のいずれも `ShapeSegmentEngine` へフォールバックし、選択範囲が必ず塗られるようにする（検閲漏れ防止）。
- **学習データ（`YOLOSegDatasetExporter`）**: 1行 `class x1 y1 x2 y2 ...`（正規化・左上原点の多角形）。**既定では手描き多角形ROIのみ書き出す**。楕円・矩形ROIを輪郭として与えると「楕円を出力するモデル」が育ち、形状抽出という目的を達成できないため。回転は画素空間で適用する（正規化空間のまま回すと非正方形画像で形が歪む）。
- **クラス順の統一**: `PartSegmentationDetector.classCategories` = `[nipple, maleGenital, femaleGenital]`。書き出し側と実行側の両方がこれを参照し、テストで固定している。ここがずれると学習済みモデルのカテゴリが入れ替わる。
- **役割分担**: ROIの**位置**は従来どおり検出モデルが決め、形状モデルはその中の**輪郭**だけを担当する。検出モデルは置き換えない。
- 手順は `Docs/FINETUNE_GUIDE.md`「部位セグメンテーション（形状）モデルの学習」。

## 5.43 「対象形状（SAM）」: プロンプト型セグメンテーションによる自動形状抽出（2026-07-29 v0.0.00098〜）

- **経緯**: §5.42の学習モデル形状は手作業アノテーションが前提であり、「モザイク処理を限りなく自動化する」というアプリの目的に反するとユーザー指摘を受けた。SAM（Segment Anything）は「枠を与えると枠内の物体の形状を返す」プロンプト型モデルであり、既存の検出枠をそのまま渡せるため**手作業ゼロ**で形状が得られる。初期実装時（Phase 3）に「SAM/MobileSAM等の外部モデル同梱を避け」Vision標準APIを採用した判断が、§5.40の構造的限界（被写体内部の部位を分離できない）の起点だった。
- **モデル**: MobileSAM（Apache-2.0、9.66Mパラメータ）。ONNX変換版（Acly/MobileSAM、MIT）の`sam_encoder.onnx`（28MB）+`sam_decoder.onnx`（16MB）を同梱。完全ローカル実行。
- **前処理の要注意点（実測で確定）**: このエンコーダは正規化・1024x1024へのパディングを**モデル内部で行うが、リサイズは行わない**。呼び出し側で長辺を1024へ揃える必要がある。省略すると座標系がずれ、マスクが対象の一部にしか付かない（Python事前検証でIoU 0.315まで劣化→リサイズ追加で0.989に回復することを実測）。
- **推論経路**: エンコーダ（重い・画像毎1回）→ 画像埋め込み → デコーダ（軽い・ROI毎）。埋め込みは直近1枚をCGImage同一性でキャッシュし、プレビュー再生成ではデコーダのみ実行する（実測: 初回1.3秒→キャッシュ後0.6秒）。ORTセッションはプロセス内で共有（`@unchecked Sendable`コンテナ+NSLock）。
- **プロンプト**: ROI枠の画素座標を長辺1024空間へスケールし、左上点(label=2)+右下点(label=3)の2点として渡す。回転ROIは回転後の外接矩形。
- **後処理**: マスクlogits>0を二値化し、ROI矩形（回転対応・白黒二値）で制限（楕円制限は§5.41のとおり輪郭を薄めるため使わない）。被覆率（リニア測定）0.02未満は図形フォールバック（検閲漏れ防止）。セッション初期化失敗・エンコード失敗も同様にフォールバック。
- **実測結果（漫画風合成線画・輪郭線で囲まれた有機形状+効果線等のクラッタ）**:

| 枠の与え方 | SAM形状 IoU | 枠塗り IoU（現状方式相当） |
|---|---|---|
| ぴったり枠 | 0.990 | 0.664 |
| ずれ+大きめ枠（検出誤差想定） | 0.989 | 0.556 |
| 1.4倍の大きすぎる枠 | 0.647 | 0.311 |

- Swift実装のend-to-endテスト（実モデル推論込み）でIoU>0.8を固定。
- **既定は変更していない**。GUI確認で品質が確認でき次第、「対象形状（SAM）」の既定化は§2.2に従いユーザー判断で行う。

## 5.44 骨格由来プライアの整理とUI初期化の修正（2026-07-29 v0.0.00099〜）

- **`PoseDerivedROIFilter`**: 骨格（関節位置）からの幾何プライアROIを、直接検出器の結果に応じて落とす純ロジック。`MosaicCore`へ切り出してテスト可能にした。
  - `dropChestPriors`: 検出器が乳首を検出したら`source == "pose-chest"`を除去（v0.0.00080から存在。ここへ移設）。
  - `dropGroinPriors`: 検出器が性器を検出したら`source == "pose-groin"`を除去（**新規**）。鼠径部プライアはカテゴリが`.other`のため、検出器の性器ROIとはIoUベースの重複除去でも統合されず、人数分の「その他」誤ROIとして残っていた（3人検出で「その他1〜3」が生成され、うち1件はコマ全体を覆っていた）。
  - どちらも検出器が該当部位を見つけられなかった画像ではフォールバックとして残す。
- **`hardShapeMask`**: ROI形状（矩形/楕円/多角形+回転）の**二値**マスク。`SAMSegmentEngine`の制限を矩形からこれへ変更した。矩形制限のままだと、SAMのマスクがROI全体を覆ったとき「楕円のROIなのに四角いモザイク」になる。`shapeMask`の楕円は放射グラデーションのため輪郭が縁で薄まる（§5.41）が、二値版では起きない。
- **サイドパネル既定幅**: `applyInitialLayoutIfNeeded`が左ペインへ280ptをハードコードしていたが、インスペクタの最小幅は340pt。初期化するとこの矛盾で「性器（男性）」が「性」になる等の省略表示、モザイクパターンタイルの横切れが起きていた。`inspectorPaneDefaultWidth`(360)と`defaultLeftPaneWidth(_:)`で一元管理する。`libraryTwoColumnPaneWidth()`にも下限340ptを設けた。
- **設定初期化の網羅**: `refreshAllUIFromSettings`が「検出」「ワークフロー」「レイヤ表示」を再同期しておらず、初期化しても直前の状態が残っていた（レイヤ表示が全OFFのまま等）。`loadDetectionSettings` / `loadLayerVisibilityDefaults` / `loadWorkflowOptions`を追加。レイヤ表示の既定はROIとモザイクがON、人物・骨格がOFF。
- **レイヤ一覧の実体連動**: ROI 0件で「モザイク対象」、画像未読込で「画像」を出さない。`numberOfChildrenOfItem`を`rootLayerItems().count`へ統一し、フィルタ追加時の件数不整合を防ぐ。

## 5.45 検出結果の後処理（乳首/乳輪の分離・過大性器ROIの除去）（2026-07-29 v0.0.00100〜）

`DetectedROIRefiner`（`MosaicCore`）に、検出器の生の出力を使いやすいROIへ整える純ロジックを集約した。骨格由来プライアの除去（§5.44 `PoseDerivedROIFilter`）の後段に位置する。

- **乳首と乳輪の分離（`splitNippleAndAreola`）**: `anime_censor_detection`の`nipple_f`クラスの枠は、乳首だけでなく**乳輪（色の変わった領域）とほぼ同じ大きさ**で返る。このためSAM等で形状を取ると乳輪範囲がマスクされ、「乳首単位で欲しい」という要望と食い違っていた。検出枠そのままを`.areola`（乳輪）、中心へ0.55倍縮小した範囲を`.nipple`（乳首）として2つのROIへ分ける。
  - 面積比は0.55² ≈ 0.30 のため、IoUベースの重複除去（>0.5）では統合されず両方が残る。
  - 派生ROIには別のUUIDを与える（同一IDだとレイヤ一覧・選択状態が壊れる）。
  - `source == "manual"`のROIは分割しない（ユーザーが指定した範囲を勝手に縮めない）。
  - `.areola`は候補カテゴリの既定OFF。乳首を含む上位範囲なので、両方ONだと同じ場所へ大小2つのROIが並ぶ。
- **過大な性器ROIの除去（`dropOversizedGenitalROIs`）**: 検出器が寝具の陰影などを性器と誤検出し、大きな範囲がマスクされる事例があった。性器ROIの面積が、それを最もよく含む人物領域の面積の**12%**を超える場合に除去する。
  - 実測根拠（GUI報告の画像）: 正しい性器ROIは人物領域の約**1.8%**、誤検出は約**17%**。人物検出は全身を枠にするため、性器が人物領域の十数%を占めることは解剖学的に起こらない。
  - **体格基準の人物領域の選び方（v0.0.00101で修正）**: `bodyScaleReference(for:persons:)` が、ROIの6割以上を含む人物領域のうち**面積が最小のもの**を採る。当初は「重なり面積が最大のもの」を採っていたが、人物検出は複数人をまとめた過大な枠を返すことがあり（実測: 下段コマ全体を覆う人物枠）、その枠が基準になると面積比が薄まってフィルタが働かなかった（締まった枠基準なら22%、過大な枠基準では10%でしきい値12%を下回る）。端がわずかに重なるだけの枠を基準にしないよう、ROIの6割以上を含むことを条件とする（`minimumROICoverageByPerson`）。
  - 人物未検出（部位のクローズアップ等）・手動追加ROI・性器以外のカテゴリは対象外。
  - **診断ログ**: category `Detection` の `genitalSize` 行に、カテゴリ・検出スコア・ROI面積・基準面積・面積比・しきい値・人物数・判定結果を記録する。誤検出が残る場合はこの値で切り分ける（推測でしきい値をいじらない）。
  - **経緯**: この誤検出は以前から存在していたが、骨格由来の鼠径部ROI（`.other`）が同じ位置に重なり、IoUベースの重複除去で先に置き換えていたため見えていなかった。§5.44で鼠径部プライアを抑制した結果、下層にあった誤検出が露出した。
- **`MosaicTargetCategory`の拡張規則**: 新カテゴリは必ず列挙の**末尾**へ追加する。`allCases`の索引が学習データ書き出しのクラス番号に対応しており、途中挿入すると既存の書き出し済みデータのラベルがずれる。テストで索引を固定している。

## 5.46 楕円ROIによる検閲漏れの防止と多重スケール検出（2026-07-29 v0.0.00102〜）

### 楕円ROIで対象がはみ出す問題

楕円は外接矩形より約21%（1 - π/4）小さく、**四隅を削ぎ落とす**。§5.44でSAMのマスクをROI形状（二値）で切るようにしたが、対象が枠いっぱいに描かれている場合、楕円で切った瞬間に対象の一部がマスクから外れ**検閲漏れ**になる（GUI報告: 男性器が楕円からはみ出す）。

一方で矩形制限のみに戻すと、SAMが枠のほぼ全面を返したとき「楕円のROIなのに四角いモザイク」になる（§5.44の元の報告）。

そこで **SAMが対象を分離できたかで切り方を変える**:

| SAMマスクのROI矩形内被覆率 | 解釈 | 制限方法 |
|---|---|---|
| `> shapeConformCoverage`(0.85) | 枠を埋め尽くしている＝対象を分離できていない | ROIの形状（楕円等）で切る |
| `<= 0.85` | 対象の輪郭を取れている | ROI矩形のみで切り、輪郭をそのまま残す |

診断ログ（category `SegmentMask`, `samShape`行）へ `rectCoverage` と `clip=shape|rect` を出力する。

### 多重スケール検出（`MultiScaleDetection`）

`AnimeCensorDetector`は**全体画像1回のみ**の推論だった。モデル入力は640x640のため、1ページに複数コマがある漫画では小さいコマの対象部位が数ピクセルへ縮小され検出できない（GUI報告: 下段コマの男性器が自動検出されず、手動追加が必要だった）。

実写側（`PhotoCensorDetector`, Build 39〜）には既に人物クロップごとの再推論があったため、同じ方式をアニメ側へ適用し、両者の実装を`MultiScaleDetection`へ共通化した。

- 全体画像 + 人物領域（1.15倍拡張）ごとのクロップで推論
- 人物未検出時は20%重複の2x2タイルで代替
- クロップ内の正規化座標を画像全体へ変換（`mapToImage`）
- 同カテゴリ内IoU 0.45で重複統合し、信頼度の高い方を残す（`dedupe`）

## 5.47 実画像回帰テストと人物マスクのSAMフォールバック（2026-07-29 v0.0.00103〜）

### 実画像回帰テスト（`Tests/SampleImages/`）

GUIで見つけた問題を数値で再現・追跡できるようにするための基盤。推測でしきい値を動かす作業を繰り返さないために設けた。

- 画像は **Git管理外**（`.gitignore`。`README.md`のみ管理下）。著作物・成人向け画像をリポジトリへ混入させないため、この設定は変更しない。
- `SampleImageRegressionTests` がフォルダ内の png/jpg を自動で読み込み、`AnimeCensorDetector`（多重スケール）→ `DetectedROIRefiner` を通した結果を測定する。
- 期待値は `<画像名>.expected.json`。カテゴリ＋正規化rectの一覧に加え、`minimumRecall` / `maximumFalsePositives` / `maximumPersonMaskCoverage` で合否条件を宣言する。期待値ファイルが無い画像は測定のみ。
- 対応付けは **同カテゴリ・IoU 0.3以上**。
- 画像が1枚も無い場合は何も測定せず成功する（CIを壊さない）。

### 人物マスクのSAMフォールバック

`anime_seg.onnx`（SkyTNT anime-segmentation）は「キャラクターか背景か」の**二値分類**であり、インスタンス分離をしない。このため以下の症状が出る（GUI報告）。

- 人物が重なる場面で、相手の体の一部が自分の人物範囲へ含まれる
- 寝具や小物の多いコマで、背景まで人物範囲になる（枠全体が塗られる）
- 効果音の描き文字など、キャラクターに隣接する黒い要素を巻き込む

SAMは枠プロンプトで**インスタンス**を取るため、この用途に向く。人物マスクの経路を次の順に変更した。

1. `AnimeSegmenter.personMaskByCrop`（クロップ推論。被覆率0.92超は分離失敗とみなしnil）
2. `SAMSegmentEngine.instanceMask(in:box:)`（**新規**。枠プロンプト）
3. `AnimeSegmenter.characterMask` の全体画像推論を人物枠で切り出す（従来のフォールバック）

なお、輪郭の細部（指先・足先の欠け）は`anime_seg`/SAMいずれもモデルの分解能に依存し、この経路変更では解決しない。実画像回帰テストで被覆率を継続測定し、悪化を検知できるようにしている。

## 5.48 小さいROIのSAM形状抽出と検出しきい値の実測校正（2026-07-31 v0.0.00104〜）

### 5.48.1 小さいROIで形状が出ない原因と対処

SAMは画像全体を長辺1024へ縮小して埋め込みを作り、デコーダは256×256のマスクlogitsを生成する。
つまり元画像のROIは「長辺1024換算のさらに1/4」の格子でしか表現されない。
漫画1ページ（実測1132×1584）の乳首ROI（25×27px）は入力換算17、マスク格子では約4×4しか占めず、
形状はまったく出ない（GUI報告: 小さい男性器はSAMより「対象形状」の方が正しい形状になる）。

対処として、小さいROIは**周辺を切り出してから推論する**経路を追加した
（`SAMSegmentEngine.binaryMaskViaCrop`）。窓はROI長辺の3倍の正方形（`cropContextScale`）で、
SAMが対象を切り出すのに必要な周辺の文脈を残す。結果は元画像座標へ貼り戻す（`place(_:at:inImageOfSize:)`）。

実測（サンプル3枚・ROI13件。値はROI矩形内の被覆率。1.0付近＝枠を塗り潰しており分離できていない）:

| 入力換算のROI長辺 | 全体推論 | 切り出し推論 |
| --- | --- | --- |
| 17〜59 | 0.89〜0.97 | 0.72〜0.82 |
| 61 | 0.76 | 0.71 |
| 130〜255 | 0.36〜0.70 | 0.36〜0.66 |

効果のある側（〜61）と無い側（130〜）の間を取り、`minimumBoxSideInInput = 96` とした。
切り出しは窓ごとにエンコーダを回すため、利点の無い大きなROIには使わない。
埋め込みキャッシュは (元画像, 切り出し窓) キーの多エントリ方式（上限24）へ変更し、
元画像が変わった時点で全て捨てる。再測定は
`swift test --filter compareSAMWholeImageAndCropForSmallROIs`。

### 5.48.2 検出しきい値 0.30 → 0.40

`AnimeCensorDetector.defaultConfidenceThreshold` を0.4とした。実測（サンプル3枚）で、
0.30では寝具の陰影を性器と誤検出する例が1件（スコア0.33）あり、0.40へ上げるとその1件だけが消え、
真の検出（最低スコア0.44 / 0.47）は1件も失われなかった。再測定は
`swift test --filter reportDetectionAcrossConfidenceThresholds`。

### 5.48.3 `dropOversizedGenitalROIs` の削除（規則そのものが誤り）

v0.0.00100で入れた「人物枠に対して大きすぎる性器ROIを誤検出として落とす」後処理を削除した。
実測で**真の検出を消していた**ためである。アップのコマでは性器が人物枠の相当割合を占めるのが正常で、
「人物枠に対する比率」は誤検出の指標にならない。§5.45の当該記述はこの節で置き換える。
誤検出はしきい値（§5.48.2）で扱う。

### 5.48.4 人物シルエットの経路をコアへ集約

`PersonSilhouetteProvider` を新設し、経路（クロップ推論 → SAM → 全体画像推論）と
「人物枠を塗り潰したマスクを弾く」判定をコアへ集約した。アプリとテストが同じ経路を通る。

従来の判定は `personMaskByCrop` 内でクロップ（枠の1.08倍）に対する割合を0.92で見ていたため、
**人物枠に対して0.96でもクロップ比では0.82にしかならず働いていなかった**。
`PersonSilhouetteProvider.maximumUsableCoverage = 0.90` として人物枠に対する割合で判定する。
実測の被覆率: 0.96→0.79、0.97→0.68（いずれもSAM経路へ切り替わった）。

### 5.48.5 マスク生成の既定変更と初期実装の削除

既定を `samShape`（対象形状（SAM））へ変更。`regionForegroundLegacy`（対象形状（初期実装・比較用））と
`LegacyRegionForegroundSegmentEngine` は、§5.41の比較検証が完了し用途が無くなったため削除した
（ユーザー指示による。CLAUDE.md §2.2の事前確認に相当）。

## 5.49 メモリ使用量の実測と削減（2026-07-31 v0.0.00105〜）

「アプリの使用メモリがVS Codeより異常に大きい6GBオーバー」報告（2026-07-31）への対応。
測定は `MemoryFootprintTests`（`swift test --filter MemoryFootprintTests`）。
`phys_footprint`（アクティビティモニタの「メモリ」に相当）で測る。

### 5.49.1 モデル常駐分（実測・約1.0〜1.5GB。現状の下限）

| 項目 | 増分 |
| --- | --- |
| 検出モデル | +83 MB |
| キャラクター分離モデル | +207 MB |
| 骨格モデル | +135 MB |
| SAM（読込のみ） | +93 MB |
| SAM（初回推論） | +540 MB |
| SAM（2回目以降） | +4〜6 MB（頭打ち） |

SAMの初回推論で確保される540MBはMobileSAMエンコーダ（入力1024×1024）の作業領域である。
`setIntraOpNumThreads` を1/2/4/既定で振っても500〜540MBで変わらず、スレッド由来ではない。
ONNX Runtimeの `memory.enable_memory_arena_shrinkage`（`ORTMemory`）も指定しているが、
効果は約50MBにとどまる。これ以上削るにはモデルのアンロード（アイドル時解放）が必要で、未実装。

### 5.49.2 6GBの主因: 「元に戻す」がフル解像度画像を保持していた

`EditorState` が `renderedImage: CGImage?` を持ち、**1ステップごとにフル解像度の描画結果**を
保持していた。A4・300dpi（2480×3508・RGBA）で1枚34.8MB。さらに:

- `undoStack` / `redoStack` に**上限が無い**
- 画像切替用の `imageEditStates`（最大8枚）が、それぞれ独自のundo/redoスタックを持つ

このため 8枚 × 20ステップ × 34.8MB ≒ **5.6GB** に達し得た。報告の6GBと符合する。

対処として `EditorState` はROIのみを保持し、`applyEditorState` がROIから描画し直す方式にした
（`renderMosaicOutput(for:)`）。`undoHistoryLimit = 100` も追加した（1段が数KBになったため）。

**注意**: モザイク表示OFFでも `renderedImage` は画像出力（`exportImage()`）と
ライブラリ保存（`performLibraryAutoSave()`）が参照する。したがって `applyEditorState` は
表示の有無にかかわらず再描画する。ここを省くと、元に戻した直後の出力が無修正になり検閲漏れになる。

**代償**: 「元に戻す」「やり直し」が即座ではなく再描画時間を要する。ROIが多い画像では体感できる。
SAMの画像埋め込みはキャッシュされるためエンコーダは回らないが、ROIごとのマスク生成は再実行される。

### 5.49.3 画像切替キャッシュ（v0.0.00106）

`PerImageEditState`（画像を切り替えても編集内容を保つ退避データ）も `renderedImage` を
保持していた。`imageEditStateLimit`（当時8）枚ぶん常駐し、A4・300dpiで約278MB。
さらに人物マスクを `personLayerMasks`（表示用・着色済み）と `personMaskImages`（未着色）の
2系統×人数分、フル解像度グレーで持つため、4人なら1枚あたり約70MB＝8枚で約560MBだった。

- `renderedImage` は保持せず、切替時にROIから作り直す（undoと同じ理由・同じ方式）。
- `imageEditStateLimit` を 8 → 3 へ。

人物マスクはAI推論が必要で作り直しが高価なため保持を続ける。2系統の重複解消（未着色のみ保持し
表示時に着色する）は未実施。

### 5.49.4 その他の上限追加

- サムネイルキャッシュにLRU上限300件（1枚約230KB。従来は無制限で、数千件のライブラリでは数百MB）。
- SAMの埋め込みキャッシュ上限を24→8（1件4MB。1画像あたりの小さいROIは通常10件未満）。

### 5.49.5 測定上の注意

`CGImage` の裏付けメモリは `phys_footprint` に計上されないため、画像保持量を合成テストで
測ることはできない（生バッファ348MBは正しく+348MBとして観測できるので、計測関数自体は正しい）。
画像保持分はコードと解像度からの算術で評価する。

## 5.50 楕円ROIによる性器の欠けと解析診断ログ（2026-07-31 v0.0.00107〜）

### 5.50.1 楕円で先端・根本が外れる

楕円は外接矩形より約21%（1 - π/4）小さく四隅を削る。検出器の枠は水平・垂直の矩形で返るため、
男性器が斜めに描かれている場合、先端と根本がちょうど対角に来て楕円から外れる
（GUI報告 2026-07-31「楕円マスク時、男性性器の先端、根本が範囲選択されない」）。

§5.46 では「SAMが対象を分離できたかで切り方を変える」ことで**マスク**の欠けに対処したが、
**ROIの範囲そのもの**（＝選択範囲）は検出枠のままだったため、枠の外にある先端・根本は
どの方式でも覆えなかった。

対処は `DetectedROIRefiner.expandGenitalEllipses`。検出器由来の性器**楕円**ROIを1.15倍へ広げる。

- 対象外: 手描き（`source == "manual"`。ユーザーの意図した範囲）、矩形・多角形（四隅を削らない）、
  乳首（`splitNippleAndAreola` で意図して縮めた大きさ）
- 画像外へはみ出す分は `clamped()` で切り詰める
- 代償: 対象の周囲を少し余分に覆う。検閲漏れを避ける方向なので許容する

### 5.50.2 解析診断ログ

GUI報告の切り分けが「手元のサンプルでは再現しない」で止まったため、報告時にログを添付できるよう
`AnalysisDiagnostics` を追加した。解析1回ごとに、ソース画像のファイル名・MD5・画素サイズ・
アプリ版数・画像種別・検出しきい値・マスク生成方式・候補カテゴリと、全ROIの内容
（カテゴリ／生成元／位置／大きさ／回転／信頼度／形状／マスク生成設定）を出力する。

プライバシー方針（`DEBUG_LOG_INVENTORY.md`「画像内容・ファイルパスは記録しない」）の例外として、
**ファイル名とMD5のみ**を残す（ユーザー要望。同一ファイルかどうかの照合に必要）。
フルパス（フォルダ構成）と画像内容は残さない。

## 5.51 学習提案（`learned-prior`）の2つの不具合（2026-07-31 v0.0.00108〜）

GUI報告 2026-07-31「下段の性器（女性）が2箇所、うち1つは範囲が大きく、もう1つは誤検知」の原因。
検出器の出力ではなく `LearningEngine.learnedProposals` の提案だった
（診断テスト `reportFinalROIsAsAssembledByApp` と `AnalysisDiagnostics` で切り分けた）。

### 5.51.1 大きさの単位の取り違え

提案の**位置**は人物枠相対のグリッド（`personGrid`）で決めるのに、**大きさ**だけ
画像相対の `meanWidth` / `meanHeight` を使っていた。アップのコマ（人物が画像の大半を占める）で
学習した大きさが、引きのコマの小さな人物にもそのまま適用され、人物枠より大きなROIが提案される。

`LearningCategoryStats` に人物相対の平均 `meanPersonRelativeWidth` / `meanPersonRelativeHeight` を
追加し、人物ごとの提案では「人物相対の平均 × その人物枠の大きさ」を使う。
旧statsファイルには該当項目が無いためOptionalとし、無い場合は人物ごとの提案を行わない
（次回の学習記録で `rebuildStats` により再構築される）。

### 5.51.2 検出器が見つけたカテゴリにも提案していた

骨格由来プライアは §5.45 で「検出器が見つけたら落とす」方針にしたが、学習提案には同じ規則が
無く、検出器が正しく出した部位の隣に提案が並んでいた。
`learnedProposals` で、検出器（`source` が `anime-censor` / `photo-censor` で始まるもの）が
そのカテゴリを1件でも出していれば提案を足さないようにした。学習提案は取りこぼし時の
フォールバックとして扱う。

### 5.51.3 切り分けの手順（今後の同種報告向け）

1. `AnalysisDiagnostics` の `analysis` 行（ヘルプ＞デバッグ＞デバッグログ）でファイル名・MD5・設定を確認する
2. 同じ画像を `Tests/SampleImages/` へ置き `reportFinalROIsAsAssembledByApp` を実行する
3. 各ROIの `src=` で由来を特定する（`anime-censor` / `pose-chest` / `pose-groin` / `face-region` / `learned-prior` / `manual`）

なお `learned-prior` はユーザーごとの学習データに依存するため、テスト用サンプルでは再現しない。
再現には `analysis` 行のROI一覧（`src=` を含む）が要る。

## 5.52 AIモデルの個別インストール運用（2026-07-31 v0.0.00109〜）

ONNXモデル8点（計451MB）をGit管理外・アプリ同梱対象外にした。
GitHubの1ファイル100MB上限（`anime_seg` 168MB / `anime_pose` 128MB）に掛かり、
66コミットが push できない状態になっていたため（`CLAUDE.md` §2.0 の「都度プッシュ」が
成立しない）。

### 5.52.1 配置と解決

- 配置先: `~/Library/Application Support/newMosaic/Models/`
- 解決: `YOLOONNXModel.cachedModelURL(resourceName:)` が「アプリバンドル内 → 上記フォルダ」の順に探す。
  この経路は `part_seg.onnx`（学習モデル形状）向けに既に存在していたものをそのまま使う。
- 導入: `scripts/install_models.sh <フォルダ>` / 確認: `scripts/install_models.sh --verify`
- 一覧・入手元・ライセンス: `Docs/MODELS.md`

### 5.52.2 影響

- クローン直後は検出機能が使えない。エラーメッセージに配置先と導入手順を出す。
- `dist/newMosaic.app` にもモデルは含まれない。別のMacで動かす場合はそのMacでの配置が必要。
  `scripts/package_macos_app.sh` は未導入時に警告する。
- アプリ自体は起動し、手動でのROI追加・モザイク処理は行える。

### 5.52.3 履歴に残る分

`git rm --cached` は今後の追跡を止めるだけで、過去のコミットに含まれるblobは残る。
リモートに既にある4モデル（`censor_detect` / `person_detect` / `photo_censor_detect` /
`domain_cls`、計114MB）は履歴に残したままとした。除去には公開済み履歴の書き換えと
force push が要るため、必要になった時点で別途判断する。

## 5.53 学習モードと設定の保守（初期化・バックアップ）（2026-07-31 v0.0.00110〜）

### 5.53.1 学習モード（既定OFF）

従来は修正結果を常に学習していた。テスト目的で描いたROIも学習され、§5.51 の誤提案の
原因になっていた。学習するかどうかをユーザーが決める方式へ変更した。

- 設定キー `Learning.Enabled`（既定OFF）。ツールバーのトグルボタンで切り替える。
- **OFFのときは記録も利用も行わない。** 利用だけ残すと、OFFにしても過去の学習由来の候補が
  出続けて止める手段が無くなる。
- 記録の入口は `recordLearningSamples()`、利用の入口は `LearningEngine.refineCandidates`。
  両方をこのフラグでゲートする。

### 5.53.2 初期化・バックアップの項目

`MaintenanceItem` に一覧を持ち、初期化ダイアログとバックアップダイアログの両方が参照する
（項目を増やすときはここへ1件足す）。

| 項目 | 実体 | 初期化の既定 | バックアップの既定 |
| --- | --- | --- | --- |
| アプリ設定 | `settings.json` | ON | ON |
| 画面レイアウト・動作状態 | 同上 | ON | ON |
| モデルの学習内容 | `~/Library/Application Support/newMosaic/Learning/` | OFF | ON |
| ライブラリ（画像とROI） | ライブラリの `index.json` | OFF | ON |

初期化で学習内容・ライブラリを既定OFFにしているのは、失うものが大きいため。
バックアップは取りこぼしを避けるため全項目を既定ONにする。

バックアップはローカルへの複製のみで外部送信はしない。ライブラリの元画像本体とAIモデルは
容量のため含めず、その旨と戻し方を `README.txt` に同梱する。

### 5.53.3 サイドパネルの縦方向の最小高さ

境界ドラッグの下限は横方向（`mainSplitView`）にしか与えておらず、縦分割では内容より小さく
できてしまい、Auto Layoutの必須制約が壊れて行やアイコンが重なっていた（GUI報告 2026-07-31）。
`NSSplitViewDelegate` の `constrainMinCoordinate` / `constrainMaxCoordinate` を縦分割へも適用し、
`fittingSize.height`（内容が要求する高さ）で止める。数値を直書きするとパネルの中身を変えた
ときに追従しないため。上限280ptを設けるのは、スクロール可能な中身を持つパネルで極端に大きな
値が返ると境界をまったく動かせなくなるため。

## 5.54 認識範囲とマスクを選択形状へ一致させる（2026-07-31 v0.0.00111〜）

GUI報告 2026-07-31:
- 矩形は範囲が大きめに認識される
- 楕円・多角形は性器より小さい範囲になり、しかもマスクが範囲の外へはみ出す
- 正しい動作は「性器を範囲内で正しく捉え、性器部がマスクされること」

### 5.54.1 拡大倍率を形状ごとに、形状が決まったあとで

v0.0.00107 の `expandGenitalEllipses` は検出直後に一律1.15倍していた。しかし形状は
`applyCandidateGenerationOutput` でユーザー設定から**後から**一括指定される。検出直後は
全ROIが既定の `.ellipse` なので、`shape == .ellipse` のガードは素通りし、矩形を選んでいても
拡大されていた（「矩形が大きめ」の原因）。

`expandGenitalROIsToCoverShape` へ改め、**形状が決まったあと**に呼ぶ。倍率は「その形状が
元の検出枠を完全に含む」最小値を幾何から求める。

| 形状 | 倍率 | 根拠 |
| --- | --- | --- |
| 矩形 | 1.0 | 四隅を削らないので拡大不要 |
| 楕円 | √2 ≒ 1.414 | 半径 (a,b) の楕円が半幅 (w,h) の矩形を含む条件 (w/a)²+(h/b)² ≤ 1 に a=kw, b=kh を代入し 2/k² ≤ 1 |
| 多角形（既定の六角形） | 1.58 | 頂点は楕円上にあり楕円より内側。辺 0.5x+0.866y=0.866 に対し枠の角 (1,1) は左辺1.366 → k ≥ 1.366/0.866 |

### 5.54.2 マスクは常に選択形状で切る（§5.46を置き換え）

§5.46 では「SAMが対象を分離できていれば矩形だけで切る」としていた。楕円で切ると対象が
欠けて検閲漏れになるためだったが、その結果「楕円・多角形を選んでいるのにマスクが範囲の外へ
はみ出す」状態になっていた。

§5.54.1 の拡大により形状が元の検出枠を包み込むようになったため、形状で切っても対象は欠けない。
`SAMSegmentEngine` は被覆率による分岐をやめ、常に `ShapeSegmentEngine.hardShapeMask` で切る。
表示している範囲とマスクが一致する方が動作として正しい。

### 5.54.3 埋め込みキャッシュの検証（テストの安定化）

`SAMSegmentEngine` の埋め込みキャッシュはプロセス共有で、対象画像が変わると全て捨てる
（アプリは1枚ずつ扱うためこれで足りる）。一方テストは並列実行されるため、他のテストが
対象画像を入れ替えると「2回目なのに再エンコードされた」と誤検出する。
キャッシュの効きを検証するテストは `SAMSegmentEngine.withIsolatedCacheForTesting()` で
専用キャッシュを持つエンジンを使う。判定は実行時間ではなく `encoderRunCount`（実行回数）で行う
（時間比較は機械の負荷で揺れる）。

診断ログの `clip=` は常に `shape` になる。`shapeConformCoverage`（0.85）は切り方の分岐には
使わなくなり、「SAMが対象を分離できているか」の測定の目安としてのみ残す。

## 5.55 デバッグログの永続化と動画プレビューの後始末（2026-08-02 v0.0.00112〜）

### 5.55.1 ログをファイルへ残す

従来のデバッグログは `OSLogStore(scope: .currentProcessIdentifier)` から直近10分を読むだけで、
**プロセス内のログしか取れず再起動で前回分が消えていた**。不具合報告は再起動後になることが
多く、肝心のログが失われていた（ユーザー要望 2026-08-02）。

`RotatingLogFile`（MosaicCore）を新設し、`~/Library/Application Support/newMosaic/Logs/` へ
1ファイル1MB・最大5世代で保存する。

    newMosaic.log      ← 現在書き込み中（最新）
    newMosaic.1.log    ← 1つ前
    ...
    newMosaic.4.log    ← 最も古い（これを超えた分は削除）

退避のタイミングは起動直後・30秒ごと・終了時（`AppDelegate.startDebugLogArchiving`）。
ファイルI/Oは主スレッドで行わない。デバッグログ画面は「保存済み＋今回起動分」を連結して表示する。

### 5.55.2 動画プレビューの後始末（クラッシュ対応）

クラッシュ報告 2026-08-02（v0.0.00110、`EXC_BAD_ACCESS` / `@objc VideoPreviewView.togglePlay()`
内の `objc_msgSend`）への対応。

プレビューウィンドウに delegate が無く、閉じるボタン（赤い×）で閉じても `closeVideoPreview()` が
呼ばれなかった。そのため次のものが残り続けていた:

- `AVPlayer` の再生と `addPeriodicTimeObserver` の登録
- `playPauseButton` / `slider` の `target`（＝`VideoPreviewView` 自身）

この状態で `VideoPreviewView` が解放されると、コントロールの `target` が解放済みメモリを指す。
その後の操作で `togglePlay()` へ入り、内部の `player` / `playPauseButton` へのメッセージ送信で
落ちる — 報告のスタックと一致する。

対処:

- `windowWillClose` で `stop()` を呼び、`videoPreviewWindow` を解放する
- `stop()` は `playerLayer.player` とコントロールの `target`/`action` も解除する（冪等）
- 主ウィンドウと同じ delegate を共有するため、`windowShouldClose`（保存確認）と
  `saveWindowFrame`（枠の保存）はウィンドウ判定で分岐する

**未確認**: 報告されたクラッシュの再現手順は不明で、上記が唯一の原因である確証は無い。
ライフサイクルの欠陥としては明確なので先に塞ぐ。再発する場合は、
§5.55.1 の保存済みログ（再起動後も残る）とあわせて操作手順を確認する。

## 5.56 補助ウィンドウの過剰解放（`isReleasedWhenClosed`）（2026-08-02 v0.0.00113〜）

クラッシュ報告 2026-08-02「詳細設定でキー割当設定後、アプリが不安定になり強制終了する。
キー割当後、再度キー割当設定画面が開けない」の原因。

### 5.56.1 原因

`NSWindow.isReleasedWhenClosed` は**既定が `true`** で、閉じるとAppKitがそのウィンドウを
release する。一方アプリ側は補助ウィンドウを `var ...Window: NSWindow?` で強参照している。
両者が組み合わさると閉じた時点で過剰解放になり、変数が解放済みメモリを指す。

補助ウィンドウの表示処理はいずれも「既に開いていれば前面へ出す」形になっている:

    if let window = advancedSettingsWindow {
        window.makeKeyAndOrderFront(nil)   // ← 解放済みへメッセージ
        return
    }

そのため一度閉じたあとに開き直そうとすると、開けない／`EXC_BAD_ACCESS` で落ちる。

### 5.56.2 クラッシュレポートの読み方（注意）

報告のスタックは frame 1 が `@objc VideoPreviewView.togglePlay()` となっていたが、**誤帰属**である。
シンボル化は直前のシンボルへ寄せるため、実際の関数と一致しないことがある。判断材料になったのは:

- 動画プレビューをまったく開いていない操作（キー割当）でも同一スタックが出た
- レジスタ `x1`（セレクタ）が `makeKeyAndOrderFront:`
- レジスタ `x19` が `MosaicWindowController.showAdvancedSettings()`

スタックのシンボル名だけで判断せず、レジスタと再現操作を突き合わせること。

### 5.56.3 対処

- 保持している補助ウィンドウ5つ（画像出力・詳細設定・テンキー割当・ショートカット一覧・
  デバッグログ）と動画プレビューに `isReleasedWhenClosed = false` を設定する
- `windowWillClose` で該当する参照を `nil` にし、次回は作り直す
  （閉じたウィンドウを使い回すと内容が古いままになるため）
- 主ウィンドウと同じdelegateを共有するので、保存確認とウィンドウ枠の保存は
  `isAuxiliaryWindow` で除外する

### 5.56.4 見落としと機械的な再発防止（v0.0.00115）

v0.0.00113 では `MosaicWindowController` が保持する補助ウィンドウ5つだけを直し、
**`AppDelegate` が保持する主ウィンドウと、動画書き出しシートを見落としていた**。
主ウィンドウは同じ原因で、「最後のウィンドウを閉じた」→終了判定→
`applicationShouldTerminate` の `if let window` で `objc_retain` して落ちた
（クラッシュ報告 2026-08-02）。

同じ原因で2度報告が出たため、目視の監査をやめて機械的に検出する。
`scripts/ci/agent_governance_guard.sh` が `main.swift` の `NSWindow(` 生成箇所すべてを走査し、
後ろ40行以内に `isReleasedWhenClosed` が無ければFAILにする。

**教訓**: 同種の欠陥を修正するときは、1箇所ずつ目視で追うのではなく、**その種類の箇所を
すべて列挙してから**直す。列挙が漏れやすい性質のものは、チェックをCIへ落とす。

## 5.57 「表示の枠」と「解析の枠」の分離（2026-08-02 v0.0.00114〜）

GUI報告 2026-08-02「矩形では正しく判定されるが、楕円・多角形で同じ性器を範囲指定しても
性器が同じ状態にマスクされない」の原因と対処。

### 5.57.1 原因: 広げた枠をそのままエンジンへ渡していた

§5.54 で性器ROIを形状ごとに広げた（楕円√2・多角形1.58）。しかし `rect` は表示・切り取りだけでなく、
マスク生成エンジンが**対象を切り出す枠**としても使われている:

- `SAMSegmentEngine`: 枠プロンプト（SAMは枠の中の物体を切り出すモデル）
- `RegionForegroundSegmentEngine`: 前景抽出のクロップ範囲

広げた枠を渡すとエンジンが別の範囲を切り出す。実測（同じ男性器・形状のみ変更、SAM被覆率）:

| 形状 | ROI幅×高 | 入力換算 | 被覆率 |
| --- | --- | --- | --- |
| 矩形 | 0.178×0.126 | 130 | 0.55 |
| 楕円 | 0.252×0.178 | 184 | 0.28 |
| 多角形 | 0.282×0.199 | 206 | 0.22 |

### 5.57.2 対処: `analysisRect`

`MosaicROI` に `analysisInsetScale`（`rect` を元の検出枠へ戻す倍率）を追加し、
`analysisRect` として参照する。

- 表示・マスクの切り取り: `rect`（形状ごとに広げたもの）
- 対象の切り出し: `analysisRect`（＝検出器が出した元の枠。形状によらず同一）

**倍率で持つ理由**: ユーザーがROIを移動・リサイズしても比率が保たれる。絶対座標で元の枠を
持つと、編集後にプロンプトだけ元の場所に取り残される。

既存データは `analysisInsetScale` が無ければ `rect` をそのまま使う（後方互換）。

### 5.57.3 検証

`swift test --filter samProducesTheSameMaskRegardlessOfROIShape` で、サンプル3枚の性器ROI10件に
ついて矩形・楕円・多角形の被覆率を比較する。現状はすべて**差 0.000**（完全一致）。

### 5.57.4 設計上の教訓

ROIの `rect` は「ユーザーに見せる範囲」と「AIに渡す範囲」を兼ねていた。前者を都合で変えると
後者が壊れる。役割が違うものは別の値として持つこと。

## 5.58 マスク形状の手描き補正（ペン）（2026-08-02 v0.0.00116〜）

自動生成したマスクが対象からずれたとき、ユーザーが塗って直せるようにする（ユーザー要望 2026-08-02）。

### 5.58.1 ストロークで保持する（ビットマップではなく）

`ManualMaskStroke` は点列・太さ・塗り/消しのフラグを持つ。座標はROIローカル（0〜1・左上原点）。

ビットマップではなくストロークにした理由:

- 保存データが小さい（ライブラリのJSONへそのまま入る）
- ROIを移動・リサイズしても補正が追従する（ROIローカル座標のため）
- 1ストローク単位で取り消せる

### 5.58.2 反映位置

`MosaicEngine.createMasks` の最後で `ManualMaskPainter.apply` を通す。生成方式（図形／対象形状／
対象形状（SAM）／学習モデル形状）に関係なく同じように効く。

- 塗り: 生成マスクとの明るい方を採る（`CIMaximumCompositing`）。塗った所は必ず対象になる。
- 消し: 消し層を反転して掛ける（`CIMultiplyCompositing`）。消した所は必ず対象外になる。

### 5.58.3 操作

ツールバーの3つ目のセグメント（筆アイコン）で「マスク修正モード」へ切り替える。

- 選択中のレイヤ上をドラッグ → 塗る
- Option(⌥)キーを押しながら → 消す
- 太さはインスペクタの「ペンの太さ」（マスク修正モードのときだけ表示）
- 1ストロークが1回の「元に戻す」単位

### 5.58.4 座標系の検証方法

このコードベースは上下反転の取り違えを繰り返している（§5.41、§5.47等）。手描き補正のテストは
座標を自前で組み立てて検証せず、**既存の `ShapeSegmentEngine.hardShapeMask` と同じ位置に出るか**で
確認する（ROIを四隅へ動かして比較）。この方式で実装のバグを1件見つけた
（1点ストロークを `fillEllipse` で描く際、背景を黒で塗ったときの塗り色が残っていて何も描かれない）。

## 5.59 マスクのキャッシュ（2026-08-02 v0.0.00117〜）

GUI報告 2026-08-02「モザイク対象の1つのモザイクを編集する毎に、アプリが一時ハングする」への対応。

### 5.59.1 原因

`applyMosaic` はモザイクの見た目を変えるたびに呼ばれるが、毎回 `createMasks` を実行していた。
既定のマスク生成方式は v0.0.00104 から「対象形状（SAM）」なので、ROIごとにONNX推論が走る。
実測ログでは1ROIあたり20〜30ms、ROIが15件あれば1回の描き直しで数百msかかり、
主スレッドで実行されるためUIが固まる。

**既定をSAMへ変えた時点で、この経路の重さが桁違いになっていた。** 変更時に描き直しの頻度と
コストの関係を確認していなかった。

### 5.59.2 対処

マスクはROIの形状・位置・生成方式・手描き補正だけで決まり、**スタイル（パターン・色・
ブロックサイズ・不透明度等）には依存しない**。`MosaicROI.maskIdentity`（マスクに影響する要素だけを
取り出した文字列）を鍵にキャッシュする。

- 鍵: 画像の同一性 ＋ 描画範囲 ＋ エンジンの型名 ＋ `maskIdentity`
- 形状しきい値の変更・マスク生成方式の切替では `invalidateMaskCache()` を呼ぶ
  （エンジンの型名で識別しているため、同じ型で設定だけ変わる場合は明示的に捨てる必要がある）
- 上限256件。超えたら全て捨てる

### 5.59.3 検証

生成回数を数える `CountingSegmentEngine` で確認する:

- スタイルだけ変えて3回描き直しても、マスク生成は初回の2件のみ
- ROIを1つ動かすと、そのROIだけ作り直す（もう1つは使い回す）
- 手描き補正を足すと、そのROIだけ作り直す

## 5.60 骨格由来の乳首プライア廃止とレイヤ表示の粒度（2026-08-02 v0.0.00118〜）

### 5.60.1 骨格由来の乳首・乳輪プライアを廃止

`SensitiveROIGenerator.chestROIs`（肩関節から乳首位置を幾何推定するプライア）を廃止した。

廃止の根拠は、同じ原因の誤検知が3度報告されたこと:

| 版 | 報告内容 |
| --- | --- |
| §5.45 | 乳首の誤検出2箇所。検出器が見つけたら落とす規則を追加 |
| §5.51 | 学習提案と並んで誤検知（別原因だが同じ画面で混在） |
| §5.60 | 男性の胸・人物の背中に乳首/乳輪。検出器は0件、実際にも乳首は写っていない |

最後の報告のログでは、誤検知6件がすべて `src=pose-chest` で、信頼度は 0.36 / 0.61 / 0.62 と
散らばっていた。**信頼度では正誤を分離できない。**

「検出器が乳首を見つけたら落とす」という規則は、検出器が0件のときにフォールバックとして残る。
今回はそのフォールバックが害になった。取りこぼしはペンによるマスク修正（§5.58）や手動ROI追加で
補えるため、プライア自体を無くす方が総合的に良い。

鼠径部のプライア（`pose-groin`、カテゴリは `.other`）は誤検知報告が無く、検出器が性器を
見つければ落ちるので残す。

### 5.60.2 カテゴリごとのグループ分け

自動検出の結果へ `roiGroupName = カテゴリの表示名` を設定する。手描き（`source == "manual"`）と、
既にグループ名があるROIは触らない（ユーザーが自分でまとめた結果を壊さないため）。

### 5.60.3 レイヤ表示の粒度と「表示だけ」の原則

レイヤ一覧のモザイク対象に、1件ごと・カテゴリグループごとの表示ON/OFFチェックを付けた。

**これは画面表示だけの設定で、画像出力には影響しない。** 既存の「表示: ROI/モザイク/人物/骨格」と
同じ扱いにしている。レイヤを隠したまま出力すると、隠した部分が無修正のまま出てしまうため
（検閲漏れ）。隠す＝出力しない、にはしない。

## 5.61 マスク追加ペンと消しゴム（2026-08-03 v0.0.00119〜）

### 5.61.1 2つのモードとOption反転

`InteractionMode` は `edit` / `marqueeSelect` / `maskPaint`（マスク追加ペン）/
`maskErase`（マスク消しゴム）。ペン系かどうかは `editsMask` で判定する。

Option(⌥)押下中は動作が反転する:

    let erasing = (interactionMode == .maskErase) != inverted

追加ペン中にOptionで一時的に消し、消しゴム中にOptionで一時的に塗れる。

### 5.61.2 レイヤ未選択時の新規レイヤ作成

マスク追加ペンで対象レイヤが無いとき、クリック位置へ新しいROIを作ってから塗る
（カテゴリ「その他」、グループ名も「その他」、`source: "manual"`）。枠の大きさは筆の太さから決める。

消しゴムでは作らない（消す対象が無いため）。

### 5.61.3 ログ消去が効かなかった原因

削除自体（`RotatingLogFile.removeAll()`）は成功していた。しかし消去時に退避位置
（`lastArchivedLogLine`）を空へ戻していたため、30秒ごとの退避処理が「今回起動分はまだ未退避」と
判断して**丸ごと書き戻していた**。`markCurrentLogAsArchived()` で退避位置を「今の最後の行」まで
進め、消した内容が復活しないようにする。

**教訓**: 「消す」機能を足すときは、その内容を**書き戻す側**の状態も一緒に進めること。

## 5.62 端のROIでクランプが逆算を壊す（2026-08-03 v0.0.00120〜）

§5.57 で「表示の枠（`rect`）」と「解析の枠（`analysisRect`）」を分け、後者を
`analysisInsetScale` による逆算で求めるようにした。しかし拡大時に `clamped()` していたため、
**画像の端にあるROIでは逆算が元の検出枠へ戻らなかった**。

倍率は形状ごとに違う（楕円√2・多角形1.58）ので、端では形状ごとに切り詰められ方が変わり、
解析枠がずれてマスクも変わる。新しいサンプル画像を追加したところ
`samProducesTheSameMaskRegardlessOfROIShape` が差 0.024 で失敗して判明した。

拡大時のクランプを廃止し、ROIが画像の外へ出ることを許す（描画・切り出しの各所で `clamped()` される）。
全10件で差 0.000 に戻った。

**教訓**: 値を「倍率で逆算する」設計にしたら、途中でクランプなどの非可逆な加工を挟まないこと。
挟むなら逆算をやめて元の値を持つ。

## 5.63 実写の人物マスク（未解決・測定結果のみ）

GUI報告 2026-08-02「各人物のマスク範囲がおかしい」。報告画像
（`EA98EC35-...`、女性2人の雑誌表紙）をサンプルへ追加して実測した。

`reportPhotoPersonMaskCoverage` の結果（人物枠に対する被覆率）:

| 画像 | Vision | SAM |
| --- | --- | --- |
| EA98EC35 人物1 | 0.65 | 0.49 |
| EA98EC35 人物2 | 0.57 | 0.72 |
| F5D9FF5D 人物1 / 人物2 | 0.49 / 0.48 | 0.49 / 0.58 |
| 7624B71B | 0.56 | 0.57 |

イラスト経路の判定（被覆率 > 0.90 でSAMへフォールバック。§5.49）は、この値域では発火しない。
またVisionとSAMのどちらが正しいかも被覆率では判別できない（優劣が画像ごとに入れ替わる）。

**現時点では、測定に基づいて修正を根拠づけられない。** 正誤の判定には人物シルエットの正解が要る。
実写経路（`StaticImageMosaicPipeline`）にイラスト経路のような品質判定が無いのは事実だが、
同じ判定を足しても今回の症状は変わらない。

## 5.64 「表示の枠」と「切り取り形状」の分離（2026-08-03 v0.0.00121〜）

§5.54 以降、性器ROIを形状ごとに広げていた（楕円√2・多角形1.58）。目的は「楕円・多角形が
四隅を削って対象の角が外れる」のを防ぐことで、これは正しい。しかし **`rect` 自体を広げていた**ため、
画面に見える選択範囲まで大きくなり、「範囲が大きすぎる」「位置がずれて見える」という報告が
繰り返し出た（2026-08-02 矩形、08-03 右下の性器）。

### 5.64.1 拡大はまだ必要か（実測）

`reportWhetherGenitalExpansionStillChangesTheMask` で、拡大あり／なしのマスクを
「拡大前の検出枠の中での被覆率」で比較した（サンプル5枚・性器ROI11件）:

    差 -0.012 〜 -0.067（平均 約 -0.037）

拡大をやめるとマスクが1.2〜6.7%失われる。つまり**楕円・多角形は実際に対象の角を削っており、
拡大は今も必要**。

### 5.64.2 対処

広げるのは**マスクを切り取る形状だけ**にする。

| 用途 | 使う枠 |
| --- | --- |
| 画面表示・選択・ハンドル操作 | `rect`（検出枠そのまま） |
| 対象の切り出し（SAM・前景抽出） | `analysisRect`（＝`rect`） |
| マスクの切り取り形状 | `maskShapeRect`（`rect` を形状ごとの倍率で広げたもの） |

マスクの被覆率は変更前と完全に同一であることを実測で確認した。

### 5.64.3 副次的な効果

`analysisInsetScale`（広げた `rect` から元の枠を倍率で逆算する仕組み）が不要になり、
§5.62 で問題になった「途中のクランプで逆算が壊れる」構造そのものが消えた。

**教訓**: ある目的（マスクの欠け防止）のために共有の値（`rect`）を書き換えると、その値の
他の用途（表示・選択・AIへの入力）すべてに影響が出る。目的ごとに別の値を持たせる方がよい。
§5.57 で「表示」と「解析」を分けたが、分け方が足りなかった。

## 5.65 複数回コードレビューで検出した整合性問題（2026-08-03 v0.0.00122〜）

ユーザー指示「全コードを問題が見つからなくなるまで複数回レビューする」に基づく静的レビュー
（6パス）で5件の問題を検出・修正した。詳細は `Docs/QC/CodeReview/QC_CodeReview_v0.0.00122.md`。

最も重要なのは、v0.0.00121で導入した `MosaicROI.maskShapeScale`（「表示の枠」と「マスクを
切り取る形状」を分離する仕組み。§5.64）が、**ROIの形状・カテゴリを検出後に手動変更する経路**を
考慮していなかったこと。`DetectedROIRefiner.expandGenitalROIsToCoverShape` は検出直後の
一括処理用で、対象外のROIをそのまま通すだけ（古い値を消さない）。インスペクタでの手動変更は
この一括処理を経由しないため、倍率が古いまま残っていた。

対処として `DetectedROIRefiner.recalculateMaskShapeScale(for:)` を追加した。こちらは
「今の形状・カテゴリへ常に合わせ直す」（対象外なら明示的に `nil` へ戻す）。
形状変更ハンドラ（`shapeControlChanged`）とカテゴリ変更ハンドラ（`onCategoryChangeRequest`）の
両方から呼ぶ。

**教訓**: 検出パイプライン用に書いた「一括変換関数」を、ユーザーの手動編集イベントハンドラから
流用しないこと。一括変換関数は典型的に「対象外は素通り」を前提にしており、単発の状態遷移
（AがBに変わった、Cに変わった）を正しく扱えない。単発イベント用には「常に現在の状態から
再計算する」関数を別に用意する。

## 5.65 SAMの部分的な検閲漏れとしきい値の較正（2026-08-03 v0.0.00123〜）

GUI報告 2026-08-03「右下性器位置誤判定」。ログの座標を照合すると検出枠の中心は動いておらず
（拡大の副作用ではない）、SAM自体の分離結果に問題があると特定した。

### 5.65.1 目視確認の方法

数値（被覆率）だけでは「対象が小さいから低い」のか「分離に失敗して低い」のか区別できない。
実際に生成されたマスクを元画像へ赤半透明で重ねてPNG書き出しし、Readツールで直接確認した。

| coverage | 見た目 |
| --- | --- |
| 0.26（報告のROI） | 亀頭部分が完全に露出。マスクは陰茎の付け根付近の細い一部のみ |
| 0.58 | 対象を綺麗に覆えている |
| 0.71 | 対象を綺麗に覆えている |

0.26は明確な検閲漏れ、0.58/0.71は正常と確認できた。

### 5.65.2 しきい値の較正

`minimumUsableCoverage`（これ未満は図形フォールバックへ倒す）は0.02のままだった。
§5.48由来の値で、当時は「完全に空のマスク」だけを弾く目的だったため、0.26のような
**部分的な検閲漏れ**を通過させてしまっていた。

確認できた失敗(0.26)と正常(0.58)の間で、安全側に倍以上の余裕を見て0.40とした。

### 5.65.3 副作用の確認

しきい値を上げると、これまで正常に動いていた他のSAM結果まで誤ってフォールバックしないか
実測した（`reportWhetherGenitalExpansionStillChangesTheMask` を流用）。
サンプル5枚・性器ROI11件のうち、フォールバックに切り替わったのは報告のあった1件のみ
（0.26→約0.69〜1.0。拡大あり／なしの差が0.000になり、両方とも図形フォールバックへ落ちたことを示す）。
他の10件（0.46〜0.71）は変化なく、SAMの精細な形状のままだった。ピンポイントな修正である。

### 5.65.4 一時診断コードの扱い

原因特定に使った「マスクをPNGへ書き出して目視確認する」コードは、確認が終わった時点で
`lowCoverageSAMMaskFallsBackToShape`（このROIで実際にフォールバックが起きることを検証する
正式なテスト）へ差し替えた。目視確認そのものは再現できないので、確認済みの結論
（このコミットの数値）だけをテストとして残す。

## 6. 品質基準

- 静止画処理時間の目標は3秒以内。
- 保存結果が元画像と同じキャンバスサイズで出力されること。
- 自動候補が不十分な場合でも、手動ROIで作業を完了できること。
- ペーストボードから取り込んだ画像は、元画像と加工後画像がライブラリに残ること。
- テスト対象は、ROI生成、マスク生成、モザイク処理、履歴保存を最優先とする。

## 7. リリース運用

- バージョン形式は `0.0.00000`。
- Build 番号はコード変更ごとに増やす。
- リリースコミットには `CHANGELOG.md` と品質ゲート結果を含める。
- リリースタグは `v<MARKETING_VERSION>`。
- リリース前に `swift test`、`swift build`、`scripts/ci/local_quality_gate.sh`、`scripts/ci/agent_governance_guard.sh` を実行する。

## 8. Markdown 文書配置

- ルート直下の Markdown は AI / CI 入口文書と `CHANGELOG.md` に限定する。
- 実装準拠の主要仕様、品質台帳、ログ台帳は `Mosaic/` 配下で管理する。
- チャット作業履歴と品質レビューは `Docs/` 配下で管理する。
