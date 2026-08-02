import CoreGraphics
import Foundation

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// `imageSize`の縦横いずれかが0以下の場合はゼロ除算でNaN/Infが生じるため、
    /// 空の矩形（0,0,0,0）を返す（コードレビューで検出）。
    public init(_ rect: CGRect, imageSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else {
            self.x = 0
            self.y = 0
            self.width = 0
            self.height = 0
            return
        }
        self.x = rect.minX / imageSize.width
        self.y = rect.minY / imageSize.height
        self.width = rect.width / imageSize.width
        self.height = rect.height / imageSize.height
    }

    public func clamped() -> NormalizedRect {
        let minX = max(0, min(1, x))
        let minY = max(0, min(1, y))
        let maxX = max(minX, min(1, x + width))
        let maxY = max(minY, min(1, y + height))
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var area: Double { max(0, width) * max(0, height) }

    /// 中心を固定したまま指定倍率へ拡大した矩形を返す（クランプはしない）。
    public func expanded(scale: Double) -> NormalizedRect {
        let centerX = x + width / 2
        let centerY = y + height / 2
        let newWidth = width * scale
        let newHeight = height * scale
        return NormalizedRect(x: centerX - newWidth / 2, y: centerY - newHeight / 2, width: newWidth, height: newHeight)
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= self.x && x <= self.x + width && y >= self.y && y <= self.y + height
    }

    public func intersection(_ other: NormalizedRect) -> NormalizedRect? {
        let minX = max(x, other.x)
        let minY = max(y, other.y)
        let maxX = min(x + width, other.x + other.width)
        let maxY = min(y + height, other.y + other.height)
        guard maxX > minX, maxY > minY else { return nil }
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func iou(with other: NormalizedRect) -> Double {
        guard let overlap = intersection(other) else { return 0 }
        let union = area + other.area - overlap.area
        guard union > 0 else { return 0 }
        return overlap.area / union
    }

    public func cgRect(imageSize: CGSize, origin: CoordinateOrigin = .topLeft) -> CGRect {
        let rect = clamped()
        let width = rect.width * imageSize.width
        let height = rect.height * imageSize.height
        let x = rect.x * imageSize.width
        let y: Double
        switch origin {
        case .topLeft:
            y = rect.y * imageSize.height
        case .bottomLeft:
            y = (1 - rect.y - rect.height) * imageSize.height
        }
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}

public enum CoordinateOrigin: Sendable {
    case topLeft
    case bottomLeft
}

public enum ROIShape: String, Codable, Sendable {
    case rectangle
    case ellipse
    case polygon
}

/// 多角形ROIの頂点。ROIの矩形（rect）に対するローカル正規化座標（0〜1、左上原点）。
/// 矩形の移動・リサイズに追従して多角形全体が拡縮される。
public struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// モザイク検出対象のカテゴリ分類。
///
/// 現状の自動検出（`DetectionPipeline.swift`）はカテゴリを区別しない単一のヒューリスティックであり、
/// カテゴリごとの実形状検出はユーザー提供の参照画像を受け取った後に実装予定。
/// 現時点ではユーザーがROIへ手動で付与するラベルとしてのみ機能する。
public enum MosaicTargetCategory: String, Codable, Sendable, CaseIterable {
    case nipple
    case femaleGenital
    case maleGenital
    case other
    /// 目元（両目+眼窩上部。パーティーマスク・メガネ・グラサン等で覆う想定）
    case eyes
    /// 眼窩下〜オトガイ（医療マスク・ガスマスク・犬の鼻口等で覆う想定）
    case lowerFace
    /// 乳輪（乳首を含む色の変わった領域）。検出器の乳首枠は乳輪相当の大きさで返るため、
    /// 「乳首」を枠より小さい範囲、「乳輪」を枠そのままとして別カテゴリへ分けている。
    /// 既存の保存データとの互換のため、必ず列挙の末尾へ追加する（`allCases`の索引が
    /// 学習データ書き出しのクラス番号に対応しているため、途中挿入は既存データを壊す）。
    case areola

    public var displayName: String {
        switch self {
        case .nipple: return "乳首"
        case .femaleGenital: return "性器（女性）"
        case .maleGenital: return "性器（男性）"
        case .other: return "その他"
        case .eyes: return "目元"
        case .lowerFace: return "眼窩下〜あご"
        case .areola: return "乳輪"
        }
    }
}

/// 永続化可能なROI個別のモザイク設定。
///
/// `CGImage` は永続化対象にせず、任意パターン画像はUIが実行時に `MosaicStyle` へ渡す。
/// フラッシュパターンの種別。
public enum MosaicFlashKind: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// 集中線（白地に黒の放射線）
    case line
    /// ベタフラッシュ（黒地に白の放射）
    case beta
    /// ウニフラッシュ（両端が尖った紡錘形の線をリング状に描く）
    case uni

    public var displayName: String {
        switch self {
        case .line: return "集中線"
        case .beta: return "ベタフラッシュ"
        case .uni: return "ウニフラッシュ"
        }
    }
}

public struct MosaicROIStyle: Codable, Equatable, Hashable, Sendable {
    public struct Tint: Codable, Equatable, Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public var pattern: MosaicFillPattern
    public var opacity: Double
    public var tint: Tint?
    public var blockScale: Double
    public var edgeFeather: Double
    public var stripeWidth: Double
    public var stripeSpacing: Double
    /// ボーダー: 縦帯/横帯（`stripeRandom`がtrueのときは無視される）。
    public var stripeVertical: Bool
    /// ボーダー: 帯幅・間隔を揺らしたランダム斜めボーダーにするか。
    public var stripeRandom: Bool
    /// ボーダー: 帯を網点（漫画トーン風）で塗るか。
    public var stripeTone: Bool
    /// ボーダー: 並行揺れ（0〜1）。各線を線の中央を軸にランダムで左右へ傾ける度合い。
    public var stripeWobble: Double
    public var cloudDensity: Double
    public var cloudTone: Bool
    /// フラッシュ（集中線）: 放射の中心位置（ROIのローカル正規化座標、0〜1・左上原点）。
    /// nilはROI中心を使う。
    public var flashCenter: NormalizedPoint?
    /// フラッシュ: 種別（集中線/ベタフラッシュ/ウニフラッシュ）。
    public var flashKind: MosaicFlashKind
    /// Application Support内に保存した任意パターン画像の識別子。
    public var patternImageIdentifier: String?

    public init(
        pattern: MosaicFillPattern = .pixelate,
        opacity: Double = 1.0,
        tint: Tint? = nil,
        blockScale: Double = 28,
        edgeFeather: Double = 0,
        stripeWidth: Double = 12,
        stripeSpacing: Double = 12,
        stripeVertical: Bool = true,
        stripeRandom: Bool = false,
        stripeTone: Bool = false,
        stripeWobble: Double = 0,
        cloudDensity: Double = 0.5,
        cloudTone: Bool = false,
        flashCenter: NormalizedPoint? = nil,
        flashKind: MosaicFlashKind = .line,
        patternImageIdentifier: String? = nil
    ) {
        self.pattern = pattern
        self.opacity = opacity
        self.tint = tint
        self.blockScale = blockScale
        self.edgeFeather = edgeFeather
        self.stripeWidth = stripeWidth
        self.stripeSpacing = stripeSpacing
        self.stripeVertical = stripeVertical
        self.stripeRandom = stripeRandom
        self.stripeTone = stripeTone
        self.stripeWobble = stripeWobble
        self.cloudDensity = cloudDensity
        self.cloudTone = cloudTone
        self.flashCenter = flashCenter
        self.flashKind = flashKind
        self.patternImageIdentifier = patternImageIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case pattern, opacity, tint, blockScale, edgeFeather, stripeWidth, stripeSpacing,
             stripeVertical, stripeRandom, stripeTone, stripeWobble, cloudDensity, cloudTone,
             flashCenter, flashKind, patternImageIdentifier
    }

    /// v0.0.00080の一時形式（種別をBoolの`flashBeta`で保持）からの読み込み互換用。
    private enum LegacyCodingKeys: String, CodingKey {
        case flashBeta
    }

    /// 旧バージョン（ボーダー縦/横/ランダムを別パターンとして保持していた時代）に保存された
    /// ライブラリ/プロジェクトのJSONを読み込めるよう、`pattern`の生値を先に読み、
    /// 該当する旧パターン名なら`.border`＋`stripeVertical`/`stripeRandom`へ変換する。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawPattern = try container.decode(String.self, forKey: .pattern)
        opacity = try container.decode(Double.self, forKey: .opacity)
        tint = try container.decodeIfPresent(Tint.self, forKey: .tint)
        blockScale = try container.decode(Double.self, forKey: .blockScale)
        edgeFeather = try container.decode(Double.self, forKey: .edgeFeather)
        stripeWidth = try container.decode(Double.self, forKey: .stripeWidth)
        stripeSpacing = try container.decode(Double.self, forKey: .stripeSpacing)
        cloudDensity = try container.decode(Double.self, forKey: .cloudDensity)
        cloudTone = try container.decode(Bool.self, forKey: .cloudTone)
        stripeWobble = try container.decodeIfPresent(Double.self, forKey: .stripeWobble) ?? 0
        flashCenter = try container.decodeIfPresent(NormalizedPoint.self, forKey: .flashCenter)
        if let kind = try container.decodeIfPresent(MosaicFlashKind.self, forKey: .flashKind) {
            flashKind = kind
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            flashKind = (try legacy.decodeIfPresent(Bool.self, forKey: .flashBeta) ?? false) ? .beta : .line
        }
        patternImageIdentifier = try container.decodeIfPresent(String.self, forKey: .patternImageIdentifier)

        switch rawPattern {
        case "stripesVertical":
            pattern = .border
            stripeVertical = true
            stripeRandom = false
        case "stripesHorizontal":
            pattern = .border
            stripeVertical = false
            stripeRandom = false
        case "stripesRandom":
            pattern = .border
            stripeVertical = true
            stripeRandom = true
        default:
            pattern = MosaicFillPattern(rawValue: rawPattern) ?? .pixelate
            stripeVertical = try container.decodeIfPresent(Bool.self, forKey: .stripeVertical) ?? true
            stripeRandom = try container.decodeIfPresent(Bool.self, forKey: .stripeRandom) ?? false
        }
        stripeTone = try container.decodeIfPresent(Bool.self, forKey: .stripeTone) ?? false
    }
}

public struct MosaicROI: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var rect: NormalizedRect
    public var confidence: Double
    public var source: String
    public var shape: ROIShape
    public var category: MosaicTargetCategory
    /// 回転角（度。時計回り、矩形中心基準。0=回転なし）
    public var rotation: Double
    /// 多角形ROIの頂点（shape == .polygon のとき使用。nilなら既定の六角形）
    public var polygonPoints: [NormalizedPoint]?
    /// nilの場合は画面全体のモザイク設定を使用する。
    public var style: MosaicROIStyle?
    /// レイヤパネルのROI選択リスト上でのグループ名。同じ値のROIが1つのグループにまとまる。
    /// nilは未グループ化（フラット表示）。
    public var roiGroupName: String?
    /// このROI個別のマスク生成方式（`SegmentEngineKind`のrawValue）。nilはインスペクタの全体設定を継承する。
    /// 「個別」ONで設定を変更したとき、選択中レイヤにだけ書き込まれる（他レイヤのマスクを変えないため）。
    public var maskEngine: String?
    /// このROI個別の形状しきい値。nilは全体設定を継承する。
    public var maskThreshold: Double?
    /// マスク形状の手描き補正（ペンで塗った／消したストローク）。
    ///
    /// 自動生成したマスクが対象からずれたときに、ユーザーが直せるようにするためのもの。
    /// 座標はROIローカル（0〜1）なので、ROIを移動・リサイズしても補正が追従する。
    /// 空なら補正なし（生成したマスクをそのまま使う）。
    public var manualMaskStrokes: [ManualMaskStroke] = []

    /// `rect` を「解析に使う枠」へ戻すための縮小倍率。nilは `rect` をそのまま使う。
    ///
    /// 楕円・多角形は四隅を削るため、`DetectedROIRefiner.expandGenitalROIsToCoverShape` が
    /// ROIを広げて対象を包み込ませている。しかし `rect` はマスク生成エンジンが
    /// **対象を切り出す枠**（SAMのプロンプト枠・前景抽出のクロップ）としても使われるため、
    /// 広げたままだとエンジンが別物を切り出してしまう。
    /// 実測（GUI報告 2026-08-02、同じ男性器で形状だけ変えた場合）:
    ///
    ///     矩形   枠0.178x0.126 → SAM被覆率0.55
    ///     楕円   枠0.252x0.178 → SAM被覆率0.28  ← 対象を捉えられていない
    ///     多角形 枠0.282x0.199 → SAM被覆率0.22
    ///
    /// そこで「表示・マスクの切り取りに使う枠（`rect`）」と「解析に使う枠（`analysisRect`）」を
    /// 分ける。倍率で持つのは、ユーザーがROIを移動・リサイズしても比率が保たれるようにするため。
    public var analysisInsetScale: Double?

    /// マスク生成に影響する要素だけを取り出した識別子。
    ///
    /// マスクはROIの形状・位置・生成方式・手描き補正だけで決まり、モザイクの見た目
    /// （パターン・色・ブロックサイズ等）には依存しない。キャッシュのキーに使うことで、
    /// スタイルを変えるたびにAI推論をやり直さずに済む
    /// （GUI報告 2026-08-02「モザイクを編集する毎にアプリが一時ハングする」）。
    public var maskIdentity: String {
        var parts = [
            String(format: "%.6f,%.6f,%.6f,%.6f", rect.x, rect.y, rect.width, rect.height),
            String(describing: shape),
            String(format: "%.3f", rotation),
            maskEngine ?? "-",
            maskThreshold.map { String(format: "%.3f", $0) } ?? "-",
            analysisInsetScale.map { String(format: "%.4f", $0) } ?? "-"
        ]
        if let polygonPoints {
            parts.append(polygonPoints.map { String(format: "%.4f:%.4f", $0.x, $0.y) }.joined(separator: ";"))
        }
        for stroke in manualMaskStrokes {
            parts.append(String(
                format: "s%@%.3f:%@",
                stroke.isAdditive ? "+" : "-", stroke.width,
                stroke.points.map { String(format: "%.4f_%.4f", $0.x, $0.y) }.joined(separator: ",")
            ))
        }
        return parts.joined(separator: "|")
    }

    /// マスク生成エンジンが対象を切り出すのに使う枠。
    /// `analysisInsetScale` があれば `rect` をその倍率で縮めたもの、無ければ `rect` そのもの。
    public var analysisRect: NormalizedRect {
        guard let scale = analysisInsetScale, scale > 0, scale != 1 else { return rect }
        return rect.expanded(scale: scale).clamped()
    }

    /// 多角形の既定形状（矩形に内接する六角形。上頂点から時計回り）
    public static let defaultPolygonPoints: [NormalizedPoint] = (0..<6).map { index in
        let angle = -Double.pi / 2 + Double(index) * .pi / 3
        return NormalizedPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))
    }

    public init(
        id: UUID = UUID(),
        rect: NormalizedRect,
        confidence: Double,
        source: String,
        shape: ROIShape = .ellipse,
        category: MosaicTargetCategory = .other,
        rotation: Double = 0,
        polygonPoints: [NormalizedPoint]? = nil,
        style: MosaicROIStyle? = nil,
        roiGroupName: String? = nil,
        maskEngine: String? = nil,
        maskThreshold: Double? = nil,
        analysisInsetScale: Double? = nil,
        manualMaskStrokes: [ManualMaskStroke] = []
    ) {
        self.id = id
        self.rect = rect.clamped()
        self.confidence = confidence
        self.source = source
        self.shape = shape
        self.category = category
        self.rotation = rotation
        self.polygonPoints = polygonPoints
        self.style = style
        self.roiGroupName = roiGroupName
        self.maskEngine = maskEngine
        self.maskThreshold = maskThreshold
        self.analysisInsetScale = analysisInsetScale
        self.manualMaskStrokes = manualMaskStrokes
    }

    private enum CodingKeys: String, CodingKey {
        case id, rect, confidence, source, shape, category, rotation, polygonPoints, style, roiGroupName
        case maskEngine, maskThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rect = try container.decode(NormalizedRect.self, forKey: .rect)
        confidence = try container.decode(Double.self, forKey: .confidence)
        source = try container.decode(String.self, forKey: .source)
        shape = try container.decodeIfPresent(ROIShape.self, forKey: .shape) ?? .ellipse
        category = try container.decodeIfPresent(MosaicTargetCategory.self, forKey: .category) ?? .other
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        polygonPoints = try container.decodeIfPresent([NormalizedPoint].self, forKey: .polygonPoints)
        style = try container.decodeIfPresent(MosaicROIStyle.self, forKey: .style)
        roiGroupName = try container.decodeIfPresent(String.self, forKey: .roiGroupName)
        // 旧ライブラリJSONには個別マスク設定が無いため、欠落時はnil（全体設定を継承）とする
        maskEngine = try container.decodeIfPresent(String.self, forKey: .maskEngine)
        maskThreshold = try container.decodeIfPresent(Double.self, forKey: .maskThreshold)
    }
}

/// 骨格関節の正準名。Vision固有のキー文字列に依存しないよう独自enumで保持する。
public enum PoseJointName: String, Codable, Sendable {
    case nose, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case root
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle

    /// ボーン描画用の接続定義（骨格検出レイヤの線分表示に使用）。
    public static let boneConnections: [(PoseJointName, PoseJointName)] = [
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root),
        (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]
}

/// 検出した関節1点。座標は画像正規化（左上原点）。
public struct PoseJoint: Codable, Equatable, Sendable {
    public var name: PoseJointName
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(name: PoseJointName, x: Double, y: Double, confidence: Double) {
        self.name = name
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

public struct PoseHint: Codable, Equatable, Sendable {
    public var bodyBounds: NormalizedRect
    public var lowerBodyBounds: NormalizedRect
    public var joints: [PoseJoint]

    public init(bodyBounds: NormalizedRect, lowerBodyBounds: NormalizedRect, joints: [PoseJoint] = []) {
        self.bodyBounds = bodyBounds
        self.lowerBodyBounds = lowerBodyBounds
        self.joints = joints
    }

    private enum CodingKeys: String, CodingKey {
        case bodyBounds, lowerBodyBounds, joints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bodyBounds = try container.decode(NormalizedRect.self, forKey: .bodyBounds)
        lowerBodyBounds = try container.decode(NormalizedRect.self, forKey: .lowerBodyBounds)
        joints = try container.decodeIfPresent([PoseJoint].self, forKey: .joints) ?? []
    }

    public func joint(_ name: PoseJointName, minConfidence: Double = 0.15) -> PoseJoint? {
        joints.first { $0.name == name && $0.confidence >= minConfidence }
    }
}

public struct MosaicHistoryEntry: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var imageName: String
    public var imagePixelWidth: Int
    public var imagePixelHeight: Int
    public var rois: [MosaicROI]
    public var algorithmVersion: String

    public init(
        createdAt: Date = Date(),
        imageName: String,
        imagePixelWidth: Int,
        imagePixelHeight: Int,
        rois: [MosaicROI],
        algorithmVersion: String = "mvp-heuristic-1"
    ) {
        self.createdAt = createdAt
        self.imageName = imageName
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.rois = rois
        self.algorithmVersion = algorithmVersion
    }
}
