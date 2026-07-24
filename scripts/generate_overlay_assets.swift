#!/usr/bin/env swift
// SNS向けかぶせ画像素材（透過PNG）の生成スクリプト。
// 実行: swift scripts/generate_overlay_assets.swift
// 出力: Sources/MosaicCore/Resources/Overlays/*.png
// すべてCoreGraphicsのベクター描画で生成する自前素材（外部素材の取り込みなし＝ライセンス問題なし）。

import AppKit

let outputDirectory = URL(fileURLWithPath: "Sources/MosaicCore/Resources/Overlays")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    return context
}

func save(_ context: CGContext, _ name: String) {
    let image = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    let data = bitmap.representation(using: .png, properties: [:])!
    try! data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    print("generated: \(name).png (\(image.width)x\(image.height))")
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func fillRounded(_ ctx: CGContext, _ rect: CGRect, _ corner: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.fillPath()
}

func fillEllipse(_ ctx: CGContext, _ rect: CGRect, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: rect)
}

// MARK: - 黒サングラス（目元）
func drawSunglassesBlack() {
    let ctx = makeContext(512, 200)
    let black = rgb(0.08, 0.08, 0.1)
    // つる（左右）
    fillRounded(ctx, CGRect(x: 0, y: 118, width: 34, height: 20), 8, rgb(0.15, 0.15, 0.18))
    fillRounded(ctx, CGRect(x: 478, y: 118, width: 34, height: 20), 8, rgb(0.15, 0.15, 0.18))
    // ブリッジ
    fillRounded(ctx, CGRect(x: 216, y: 112, width: 80, height: 24), 10, black)
    // レンズ
    fillRounded(ctx, CGRect(x: 28, y: 22, width: 194, height: 146), 52, black)
    fillRounded(ctx, CGRect(x: 290, y: 22, width: 194, height: 146), 52, black)
    // グロス（ハイライト）
    fillEllipse(ctx, CGRect(x: 58, y: 108, width: 66, height: 34), rgb(1, 1, 1, 0.22))
    fillEllipse(ctx, CGRect(x: 320, y: 108, width: 66, height: 34), rgb(1, 1, 1, 0.22))
    save(ctx, "sunglasses_black")
}

// MARK: - ハートサングラス（目元・SNS向け）
func heartPath(centerX cx: CGFloat, centerY cy: CGFloat, size s: CGFloat) -> CGPath {
    let path = CGMutablePath()
    // 下の頂点から左ローブ→右ローブへ
    path.move(to: CGPoint(x: cx, y: cy - s * 0.42))
    path.addCurve(
        to: CGPoint(x: cx - s * 0.5, y: cy + 0.12 * s),
        control1: CGPoint(x: cx - s * 0.34, y: cy - s * 0.22),
        control2: CGPoint(x: cx - s * 0.5, y: cy - s * 0.06)
    )
    path.addArc(
        center: CGPoint(x: cx - s * 0.25, y: cy + 0.14 * s),
        radius: s * 0.25,
        startAngle: .pi,
        endAngle: 0,
        clockwise: true
    )
    path.addArc(
        center: CGPoint(x: cx + s * 0.25, y: cy + 0.14 * s),
        radius: s * 0.25,
        startAngle: .pi,
        endAngle: 0,
        clockwise: true
    )
    path.addCurve(
        to: CGPoint(x: cx, y: cy - s * 0.42),
        control1: CGPoint(x: cx + s * 0.5, y: cy - s * 0.06),
        control2: CGPoint(x: cx + s * 0.34, y: cy - s * 0.22)
    )
    path.closeSubpath()
    return path
}

func drawSunglassesHeart() {
    let ctx = makeContext(512, 230)
    let pink = rgb(1.0, 0.27, 0.53)
    // ブリッジ
    fillRounded(ctx, CGRect(x: 222, y: 118, width: 68, height: 20), 9, pink)
    // つる
    fillRounded(ctx, CGRect(x: 2, y: 124, width: 30, height: 18), 8, pink)
    fillRounded(ctx, CGRect(x: 480, y: 124, width: 30, height: 18), 8, pink)
    // ハートレンズ
    ctx.setFillColor(pink)
    ctx.addPath(heartPath(centerX: 128, centerY: 108, size: 210))
    ctx.fillPath()
    ctx.addPath(heartPath(centerX: 384, centerY: 108, size: 210))
    ctx.fillPath()
    // 内側レンズ（濃色）
    ctx.setFillColor(rgb(0.72, 0.1, 0.32, 0.92))
    ctx.addPath(heartPath(centerX: 128, centerY: 108, size: 168))
    ctx.fillPath()
    ctx.addPath(heartPath(centerX: 384, centerY: 108, size: 168))
    ctx.fillPath()
    // グロス
    fillEllipse(ctx, CGRect(x: 84, y: 128, width: 46, height: 26), rgb(1, 1, 1, 0.35))
    fillEllipse(ctx, CGRect(x: 340, y: 128, width: 46, height: 26), rgb(1, 1, 1, 0.35))
    save(ctx, "sunglasses_heart")
}

// MARK: - パーティーマスク（目元・マスカレード）
func drawPartyMask() {
    let ctx = makeContext(512, 250)
    let purple = rgb(0.42, 0.18, 0.62)
    let gold = rgb(0.93, 0.76, 0.25)
    // マスク本体（上辺に山を持つ帯）
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 16, y: 120))
    body.addQuadCurve(to: CGPoint(x: 256, y: 214), control: CGPoint(x: 96, y: 224))
    body.addQuadCurve(to: CGPoint(x: 496, y: 120), control: CGPoint(x: 416, y: 224))
    body.addQuadCurve(to: CGPoint(x: 256, y: 44), control: CGPoint(x: 420, y: 26))
    body.addQuadCurve(to: CGPoint(x: 16, y: 120), control: CGPoint(x: 92, y: 26))
    body.closeSubpath()
    ctx.setFillColor(purple)
    ctx.addPath(body)
    ctx.fillPath()
    // 金の縁取り
    ctx.setStrokeColor(gold)
    ctx.setLineWidth(9)
    ctx.addPath(body)
    ctx.strokePath()
    // 目穴（透明に抜く）
    ctx.setBlendMode(.clear)
    fillEllipse(ctx, CGRect(x: 96, y: 96, width: 122, height: 62), rgb(0, 0, 0, 1))
    fillEllipse(ctx, CGRect(x: 294, y: 96, width: 122, height: 62), rgb(0, 0, 0, 1))
    ctx.setBlendMode(.normal)
    // 目穴の金縁
    ctx.setStrokeColor(gold)
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: CGRect(x: 96, y: 96, width: 122, height: 62))
    ctx.strokeEllipse(in: CGRect(x: 294, y: 96, width: 122, height: 62))
    // 頂点の飾り
    fillEllipse(ctx, CGRect(x: 244, y: 196, width: 24, height: 24), gold)
    save(ctx, "party_mask")
}

// MARK: - 医療マスク（眼窩下）
func drawMedicalMask() {
    let ctx = makeContext(512, 340)
    let maskColor = rgb(0.86, 0.92, 0.97)
    let pleat = rgb(0.68, 0.78, 0.87)
    // 耳ひも
    ctx.setStrokeColor(rgb(0.8, 0.86, 0.92))
    ctx.setLineWidth(12)
    let leftLoop = CGMutablePath()
    leftLoop.move(to: CGPoint(x: 92, y: 252))
    leftLoop.addQuadCurve(to: CGPoint(x: 92, y: 96), control: CGPoint(x: 6, y: 174))
    ctx.addPath(leftLoop)
    ctx.strokePath()
    let rightLoop = CGMutablePath()
    rightLoop.move(to: CGPoint(x: 420, y: 252))
    rightLoop.addQuadCurve(to: CGPoint(x: 420, y: 96), control: CGPoint(x: 506, y: 174))
    ctx.addPath(rightLoop)
    ctx.strokePath()
    // マスク本体（下すぼまりの台形風）
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 76, y: 262))
    body.addQuadCurve(to: CGPoint(x: 436, y: 262), control: CGPoint(x: 256, y: 296))
    body.addQuadCurve(to: CGPoint(x: 398, y: 74), control: CGPoint(x: 452, y: 150))
    body.addQuadCurve(to: CGPoint(x: 114, y: 74), control: CGPoint(x: 256, y: 26))
    body.addQuadCurve(to: CGPoint(x: 76, y: 262), control: CGPoint(x: 60, y: 150))
    body.closeSubpath()
    ctx.setFillColor(maskColor)
    ctx.addPath(body)
    ctx.fillPath()
    // プリーツ（ひだ）
    ctx.setStrokeColor(pleat)
    ctx.setLineWidth(8)
    for y: CGFloat in [214, 168, 122] {
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 112, y: y))
        line.addQuadCurve(to: CGPoint(x: 400, y: y), control: CGPoint(x: 256, y: y + 22))
        ctx.addPath(line)
        ctx.strokePath()
    }
    save(ctx, "medical_mask")
}

// MARK: - 犬の鼻口（眼窩下・SNSフィルタ風）
func drawDogNose() {
    let ctx = makeContext(512, 400)
    let fur = rgb(0.83, 0.62, 0.4)
    let lightFur = rgb(0.96, 0.88, 0.74)
    let dark = rgb(0.2, 0.12, 0.08)
    // マズル（口吻）
    fillEllipse(ctx, CGRect(x: 76, y: 36, width: 360, height: 300), fur)
    fillEllipse(ctx, CGRect(x: 126, y: 52, width: 260, height: 220), lightFur)
    // 鼻
    let nose = CGMutablePath()
    nose.move(to: CGPoint(x: 196, y: 292))
    nose.addQuadCurve(to: CGPoint(x: 316, y: 292), control: CGPoint(x: 256, y: 326))
    nose.addQuadCurve(to: CGPoint(x: 256, y: 208), control: CGPoint(x: 322, y: 218))
    nose.addQuadCurve(to: CGPoint(x: 196, y: 292), control: CGPoint(x: 190, y: 218))
    nose.closeSubpath()
    ctx.setFillColor(dark)
    ctx.addPath(nose)
    ctx.fillPath()
    fillEllipse(ctx, CGRect(x: 218, y: 272, width: 30, height: 18), rgb(1, 1, 1, 0.3))
    // 人中（鼻下の縦線）と口
    ctx.setStrokeColor(dark)
    ctx.setLineWidth(9)
    ctx.move(to: CGPoint(x: 256, y: 208))
    ctx.addLine(to: CGPoint(x: 256, y: 150))
    ctx.strokePath()
    let mouth = CGMutablePath()
    mouth.move(to: CGPoint(x: 168, y: 150))
    mouth.addQuadCurve(to: CGPoint(x: 256, y: 118), control: CGPoint(x: 196, y: 112))
    mouth.addQuadCurve(to: CGPoint(x: 344, y: 150), control: CGPoint(x: 316, y: 112))
    ctx.addPath(mouth)
    ctx.strokePath()
    // 舌
    fillRounded(ctx, CGRect(x: 222, y: 18, width: 68, height: 96), 32, rgb(0.96, 0.5, 0.56))
    ctx.setStrokeColor(rgb(0.85, 0.32, 0.42))
    ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: 256, y: 30))
    ctx.addLine(to: CGPoint(x: 256, y: 92))
    ctx.strokePath()
    save(ctx, "dog_nose")
}

// MARK: - ガスマスク（眼窩下・呼吸器部）
func drawGasMask() {
    let ctx = makeContext(512, 400)
    let body = rgb(0.2, 0.22, 0.24)
    let metal = rgb(0.45, 0.48, 0.5)
    // ストラップ
    ctx.setStrokeColor(rgb(0.3, 0.32, 0.34))
    ctx.setLineWidth(20)
    ctx.move(to: CGPoint(x: 120, y: 330))
    ctx.addLine(to: CGPoint(x: 6, y: 386))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 392, y: 330))
    ctx.addLine(to: CGPoint(x: 506, y: 386))
    ctx.strokePath()
    // 本体（下すぼまりの面体）
    let face = CGMutablePath()
    face.move(to: CGPoint(x: 110, y: 350))
    face.addQuadCurve(to: CGPoint(x: 402, y: 350), control: CGPoint(x: 256, y: 396))
    face.addQuadCurve(to: CGPoint(x: 330, y: 60), control: CGPoint(x: 428, y: 130))
    face.addQuadCurve(to: CGPoint(x: 182, y: 60), control: CGPoint(x: 256, y: 16))
    face.addQuadCurve(to: CGPoint(x: 110, y: 350), control: CGPoint(x: 84, y: 130))
    face.closeSubpath()
    ctx.setFillColor(body)
    ctx.addPath(face)
    ctx.fillPath()
    // 側面フィルター（左右の円形カートリッジ）
    for cx: CGFloat in [96, 416] {
        fillEllipse(ctx, CGRect(x: cx - 62, y: 96, width: 124, height: 124), metal)
        fillEllipse(ctx, CGRect(x: cx - 46, y: 112, width: 92, height: 92), rgb(0.3, 0.33, 0.35))
        // スリット
        ctx.setStrokeColor(rgb(0.55, 0.58, 0.6))
        ctx.setLineWidth(6)
        for offset: CGFloat in [-20, 0, 20] {
            ctx.move(to: CGPoint(x: cx - 26, y: 158 + offset))
            ctx.addLine(to: CGPoint(x: cx + 26, y: 158 + offset))
            ctx.strokePath()
        }
    }
    // 中央バルブ
    fillEllipse(ctx, CGRect(x: 216, y: 60, width: 80, height: 80), metal)
    fillEllipse(ctx, CGRect(x: 230, y: 74, width: 52, height: 52), rgb(0.32, 0.35, 0.37))
    save(ctx, "gas_mask")
}

drawSunglassesBlack()
drawSunglassesHeart()
drawPartyMask()
drawMedicalMask()
drawDogNose()
drawGasMask()
print("done")
