import CoreGraphics
import CryptoKit
import Foundation

/// 自動検出（解析）の診断記録。
///
/// GUI報告の切り分けを推測ではなく事実で行うために、**どの画像に対して・どの設定で・
/// 何が出たか**を1回の解析ごとに残す（ユーザー要望 2026-07-31）。
/// ヘルプ＞デバッグ＞デバッグログから書き出して共有できる。
///
/// 記録するのは次のみで、画像そのものやフルパスは残さない:
/// - ソース画像の**ファイル名**（フォルダ構成は残さない）とMD5、画素サイズ
/// - 解析設定（画像種別・検出しきい値・マスク生成方式・候補カテゴリ）
/// - 各ROIのカテゴリ・生成元・位置・大きさ・回転・信頼度・マスク生成設定（継承/個別）
public enum AnalysisDiagnostics {
    /// 画像同一性の照合用ハッシュ。暗号用途ではなく「同じファイルか」の確認にのみ使う。
    public static func md5Hex(of data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// ファイルのMD5。読み込めない場合は nil。
    public static func md5Hex(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return md5Hex(of: data)
    }

    /// 解析1回分のヘッダ行。
    public static func header(
        appVersion: String,
        fileName: String,
        md5: String?,
        imageSize: CGSize,
        domain: String,
        confidenceThreshold: Double,
        maskEngine: String,
        enabledCategories: [MosaicTargetCategory]
    ) -> String {
        let categories = enabledCategories.map(\.rawValue).sorted().joined(separator: ",")
        return String(
            format: "analysis v=%@ file=%@ md5=%@ size=%dx%d domain=%@ threshold=%.2f maskEngine=%@ categories=[%@]",
            appVersion, fileName, md5 ?? "unavailable",
            Int(imageSize.width), Int(imageSize.height),
            domain, confidenceThreshold, maskEngine, categories
        )
    }

    /// ROI1件分の行。マスク生成設定は個別指定があればその値、無ければ `inherit`。
    public static func line(for roi: MosaicROI, index: Int) -> String {
        let engine = roi.maskEngine ?? "inherit"
        let threshold = roi.maskThreshold.map { String(format: "%.2f", $0) } ?? "inherit"
        return String(
            format: "  roi[%02d] %@ src=%@ x=%.4f y=%.4f w=%.4f h=%.4f rot=%.0f conf=%.2f shape=%@ maskEngine=%@ maskThreshold=%@",
            index, roi.category.rawValue, roi.source,
            roi.rect.x, roi.rect.y, roi.rect.width, roi.rect.height,
            roi.rotation, roi.confidence, String(describing: roi.shape),
            engine, threshold
        )
    }

    /// 解析1回分の全行（ヘッダ＋ROI）。
    public static func report(
        appVersion: String,
        fileName: String,
        md5: String?,
        imageSize: CGSize,
        domain: String,
        confidenceThreshold: Double,
        maskEngine: String,
        enabledCategories: [MosaicTargetCategory],
        rois: [MosaicROI]
    ) -> [String] {
        var lines = [header(
            appVersion: appVersion, fileName: fileName, md5: md5, imageSize: imageSize,
            domain: domain, confidenceThreshold: confidenceThreshold,
            maskEngine: maskEngine, enabledCategories: enabledCategories
        )]
        lines.append("  roiCount=\(rois.count)")
        for (index, roi) in rois.enumerated() {
            lines.append(line(for: roi, index: index))
        }
        return lines
    }
}
