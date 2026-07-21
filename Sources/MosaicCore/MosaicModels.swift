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

    public init(_ rect: CGRect, imageSize: CGSize) {
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

    public var displayName: String {
        switch self {
        case .nipple: return "乳首"
        case .femaleGenital: return "性器（女性）"
        case .maleGenital: return "性器（男性）"
        case .other: return "その他"
        }
    }
}

public struct MosaicROI: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var rect: NormalizedRect
    public var confidence: Double
    public var source: String
    public var shape: ROIShape
    public var category: MosaicTargetCategory

    public init(
        id: UUID = UUID(),
        rect: NormalizedRect,
        confidence: Double,
        source: String,
        shape: ROIShape = .ellipse,
        category: MosaicTargetCategory = .other
    ) {
        self.id = id
        self.rect = rect.clamped()
        self.confidence = confidence
        self.source = source
        self.shape = shape
        self.category = category
    }

    private enum CodingKeys: String, CodingKey {
        case id, rect, confidence, source, shape, category
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rect = try container.decode(NormalizedRect.self, forKey: .rect)
        confidence = try container.decode(Double.self, forKey: .confidence)
        source = try container.decode(String.self, forKey: .source)
        shape = try container.decodeIfPresent(ROIShape.self, forKey: .shape) ?? .ellipse
        category = try container.decodeIfPresent(MosaicTargetCategory.self, forKey: .category) ?? .other
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
