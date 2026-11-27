import UIKit
import UserNotifications

/// 原生 AirPods 风格电量卡片绘制器（支持 iOS 浅色瓷白 / 深色暗曜双主题自适应）
/// 采用 CoreGraphics @3x 矢量离屏渲染，前后台蓝牙唤醒均可在数毫秒内稳定出图，不额外占用 App ID 配额。
enum AirPodsCardRenderer {
    private static let canvasSize = CGSize(width: 480, height: 276)
    private static let attachmentSubdir = "freeclip-connect-cards"

    // MARK: - 双主题同构色彩系统（遵循 taste 90%+ 中性面 + 极细描边 + 单一状态色，零廉价渐变与脏阴影）

    private struct CardPalette {
        let isDark: Bool
        let sheetBackground: UIColor
        let tileSurface: UIColor
        let tileHairline: UIColor
        let tileTopHighlight: UIColor?
        let primaryInk: UIColor
        let glyphInk: UIColor
        let mutedInk: UIColor
        let placeholderInk: UIColor
        let pillFill: UIColor
        let pillInk: UIColor
        let ringTrack: UIColor
        let accentGreen: UIColor
        let accentAmber: UIColor
        let accentRed: UIColor

        static let light = CardPalette(
            isDark: false,
            sheetBackground: UIColor(red: 244 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1.0),
            tileSurface: .white,
            tileHairline: UIColor(red: 24 / 255, green: 26 / 255, blue: 31 / 255, alpha: 0.075),
            tileTopHighlight: nil,
            primaryInk: UIColor(red: 24 / 255, green: 26 / 255, blue: 31 / 255, alpha: 1.0),
            glyphInk: UIColor(red: 42 / 255, green: 46 / 255, blue: 54 / 255, alpha: 1.0),
            mutedInk: UIColor(red: 104 / 255, green: 112 / 255, blue: 122 / 255, alpha: 1.0),
            placeholderInk: UIColor(red: 154 / 255, green: 161 / 255, blue: 170 / 255, alpha: 1.0),
            pillFill: UIColor(red: 232 / 255, green: 234 / 255, blue: 238 / 255, alpha: 1.0),
            pillInk: UIColor(red: 73 / 255, green: 80 / 255, blue: 90 / 255, alpha: 1.0),
            ringTrack: UIColor(red: 24 / 255, green: 26 / 255, blue: 31 / 255, alpha: 0.08),
            accentGreen: UIColor(red: 36 / 255, green: 179 / 255, blue: 100 / 255, alpha: 1.0),
            accentAmber: UIColor(red: 229 / 255, green: 149 / 255, blue: 26 / 255, alpha: 1.0),
            accentRed: UIColor(red: 223 / 255, green: 63 / 255, blue: 63 / 255, alpha: 1.0)
        )

        static let dark = CardPalette(
            isDark: true,
            sheetBackground: UIColor(red: 20 / 255, green: 21 / 255, blue: 24 / 255, alpha: 1.0),
            tileSurface: UIColor(red: 30 / 255, green: 32 / 255, blue: 37 / 255, alpha: 1.0),
            tileHairline: UIColor(white: 1.0, alpha: 0.085),
            tileTopHighlight: UIColor(white: 1.0, alpha: 0.045),
            primaryInk: UIColor(red: 243 / 255, green: 244 / 255, blue: 246 / 255, alpha: 1.0),
            glyphInk: UIColor(red: 226 / 255, green: 229 / 255, blue: 235 / 255, alpha: 1.0),
            mutedInk: UIColor(red: 142 / 255, green: 150 / 255, blue: 162 / 255, alpha: 1.0),
            placeholderInk: UIColor(red: 98 / 255, green: 105 / 255, blue: 116 / 255, alpha: 1.0),
            pillFill: UIColor(red: 40 / 255, green: 43 / 255, blue: 50 / 255, alpha: 1.0),
            pillInk: UIColor(red: 180 / 255, green: 188 / 255, blue: 200 / 255, alpha: 1.0),
            ringTrack: UIColor(white: 1.0, alpha: 0.11),
            accentGreen: UIColor(red: 43 / 255, green: 212 / 255, blue: 114 / 255, alpha: 1.0),
            accentAmber: UIColor(red: 242 / 255, green: 163 / 255, blue: 36 / 255, alpha: 1.0),
            accentRed: UIColor(red: 240 / 255, green: 77 / 255, blue: 77 / 255, alpha: 1.0)
        )
    }

    /// 在主线程安全读取当前系统外观（兼容前台与后台蓝牙唤醒场景）
    @MainActor
    static func resolveSystemDarkMode() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                let style = windowScene.traitCollection.userInterfaceStyle
                if style != .unspecified {
                    return style == .dark
                }
            }
        }
        return UIScreen.main.traitCollection.userInterfaceStyle == .dark
    }

    /// 为连接（开盖）通知生成 `UNNotificationAttachment`
    static func makeConnectAttachment(
        snapshot: FreeClipSnapshot,
        deviceName: String?,
        lowCaseThreshold: Int,
        isDarkMode: Bool
    ) -> UNNotificationAttachment? {
        let pngData = renderPNGData(
            snapshot: snapshot,
            deviceName: deviceName,
            lowCaseThreshold: lowCaseThreshold,
            isDarkMode: isDarkMode
        )
        guard !pngData.isEmpty else { return nil }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(attachmentSubdir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            cleanupStaleFiles(in: dir)

            let fileURL = dir.appendingPathComponent("card-\(UUID().uuidString).png")
            try pngData.write(to: fileURL, options: .atomic)

            // 收起态右侧方形缩略图精准对准正中央「充电盒」模块（188x188pt 1:1 正方形），下拉/长按展开完整三栏卡片
            let thumbSquare = CGRect(
                x: 146.0 / canvasSize.width,
                y: 66.0 / canvasSize.height,
                width: 188.0 / canvasSize.width,
                height: 188.0 / canvasSize.height
            )
            let options: [AnyHashable: Any] = [
                UNNotificationAttachmentOptionsThumbnailClippingRectKey: thumbSquare.dictionaryRepresentation
            ]
            return try UNNotificationAttachment(
                identifier: "freeclip-connect-card",
                url: fileURL,
                options: options
            )
        } catch {
            return nil
        }
    }

    static func renderPNGData(
        snapshot: FreeClipSnapshot,
        deviceName: String?,
        lowCaseThreshold: Int,
        isDarkMode: Bool
    ) -> Data {
        let palette: CardPalette = isDarkMode ? .dark : .light

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = true
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.pngData { ctx in
            let cg = ctx.cgContext
            let bounds = CGRect(origin: .zero, size: canvasSize)

            // 1. 面板基底（浅色瓷白 / 深色暗曜，由系统通知容器圆角自然裁切外框）
            palette.sheetBackground.setFill()
            cg.fill(bounds)

            // 2. 顶部等边距标题栏（左右留白严格对称 24pt）
            drawHeader(
                in: cg,
                palette: palette,
                snapshot: snapshot,
                deviceName: deviceName ?? "HUAWEI FreeClip 2",
                lowCaseThreshold: lowCaseThreshold
            )

            // 3. 三栏等高对称电量模块：左耳（开口向右 ⊂）· 充电盒（居中）· 右耳（开口向左 ⊃）
            let padX: CGFloat = 24
            let gap: CGFloat = 12
            let tileY: CGFloat = 66
            let tileH: CGFloat = 188
            let tileW: CGFloat = (canvasSize.width - padX * 2 - gap * 2) / 3.0 // 136pt

            let specs: [(title: String, unit: BatteryUnit, kind: UnitGlyphKind, lowThreshold: Int)] = [
                ("左耳", snapshot.earbud1, .leftClip, 15),
                ("充电盒", snapshot.caseBattery, .pebbleCase, lowCaseThreshold),
                ("右耳", snapshot.earbud2, .rightClip, 15)
            ]

            for (index, item) in specs.enumerated() {
                let x = padX + CGFloat(index) * (tileW + gap)
                let rect = CGRect(x: x, y: tileY, width: tileW, height: tileH)
                drawUnitTile(
                    in: cg,
                    palette: palette,
                    rect: rect,
                    title: item.title,
                    unit: item.unit,
                    kind: item.kind,
                    lowThreshold: item.lowThreshold
                )
            }
        }
    }

    // MARK: - 顶栏绘制

    private static func drawHeader(
        in cg: CGContext,
        palette: CardPalette,
        snapshot: FreeClipSnapshot,
        deviceName: String,
        lowCaseThreshold: Int
    ) {
        let padX: CGFloat = 24
        let centerY: CGFloat = 37

        let dotColor = snapshot.isCaseLow(threshold: lowCaseThreshold) ? palette.accentRed : palette.accentGreen
        let dotRect = CGRect(x: padX, y: centerY - 3.5, width: 7, height: 7)
        dotColor.setFill()
        cg.fillEllipse(in: dotRect)

        let badgeText = (snapshot.lidState == .open) ? "开盖 · 已连接" : "已连接"
        let badgeFont = UIFont.systemFont(ofSize: 12, weight: .medium)
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: palette.pillInk
        ]
        let badgeTextSize = (badgeText as NSString).size(withAttributes: badgeAttrs)
        let pillW = ceil(badgeTextSize.width) + 24
        let pillH: CGFloat = 26
        let pillX = canvasSize.width - padX - pillW
        let pillRect = CGRect(x: pillX, y: centerY - pillH / 2, width: pillW, height: pillH)

        let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillH / 2)
        palette.pillFill.setFill()
        pillPath.fill()

        palette.tileHairline.setStroke()
        pillPath.lineWidth = 0.75
        pillPath.stroke()

        let badgeTextOrigin = CGPoint(
            x: pillRect.midX - badgeTextSize.width / 2,
            y: pillRect.midY - badgeTextSize.height / 2
        )
        (badgeText as NSString).draw(at: badgeTextOrigin, withAttributes: badgeAttrs)

        let titleFont = UIFont.systemFont(ofSize: 17.5, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: palette.primaryInk,
            .kern: -0.3,
            .paragraphStyle: paragraph
        ]
        let titleX = dotRect.maxX + 9
        let maxTitleW = pillRect.minX - titleX - 12
        let titleSize = (deviceName as NSString).size(withAttributes: titleAttrs)
        let titleRect = CGRect(
            x: titleX,
            y: centerY - titleSize.height / 2,
            width: max(40, maxTitleW),
            height: ceil(titleSize.height)
        )
        (deviceName as NSString).draw(in: titleRect, withAttributes: titleAttrs)
    }

    // MARK: - 单项电量卡片绘制

    private enum UnitGlyphKind {
        case leftClip
        case pebbleCase
        case rightClip
    }

    private static func drawUnitTile(
        in cg: CGContext,
        palette: CardPalette,
        rect: CGRect,
        title: String,
        unit: BatteryUnit,
        kind: UnitGlyphKind,
        lowThreshold: Int
    ) {
        let tilePath = UIBezierPath(roundedRect: rect, cornerRadius: 20)
        palette.tileSurface.setFill()
        tilePath.fill()

        let strokeRect = rect.insetBy(dx: 0.5, dy: 0.5)
        let strokePath = UIBezierPath(roundedRect: strokeRect, cornerRadius: 19.5)
        palette.tileHairline.setStroke()
        strokePath.lineWidth = 1.0
        strokePath.stroke()

        // 深色模式下顶部微弱高光内边缘（参考 taste 暗色卡片规范）
        if let topHighlight = palette.tileTopHighlight {
            cg.saveGState()
            tilePath.addClip()
            topHighlight.setStroke()
            let topLine = UIBezierPath()
            topLine.move(to: CGPoint(x: rect.minX + 16, y: rect.minY + 1.0))
            topLine.addLine(to: CGPoint(x: rect.maxX - 16, y: rect.minY + 1.0))
            topLine.lineWidth = 1.0
            topLine.stroke()
            cg.restoreGState()
        }

        let ringCenter = CGPoint(x: rect.midX, y: rect.minY + 62)
        let ringRadius: CGFloat = 34
        let ringStroke: CGFloat = 6.2

        // 底轨圆环
        let trackPath = UIBezierPath(
            arcCenter: ringCenter,
            radius: ringRadius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        )
        trackPath.lineWidth = ringStroke
        palette.ringTrack.setStroke()
        trackPath.stroke()

        // 顺时针电量进度弧（12 点钟起算）
        if let level = unit.level, level > 0 {
            let clamped = min(max(level, 0), 100)
            let startAngle = -CGFloat.pi / 2
            let endAngle = startAngle + (.pi * 2) * (CGFloat(clamped) / 100.0)
            let arcPath = UIBezierPath(
                arcCenter: ringCenter,
                radius: ringRadius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: true
            )
            arcPath.lineWidth = ringStroke
            arcPath.lineCapStyle = .round
            ringColor(for: unit, lowThreshold: lowThreshold, palette: palette).setStroke()
            arcPath.stroke()
        }

        // 圆环中心定制硬件轮廓
        let iconTint = (unit.level != nil) ? palette.glyphInk : palette.placeholderInk
        switch kind {
        case .leftClip:
            // 左耳：C 形桥弓背在左，开口朝右（⊂）
            drawFreeClipEarbudGlyph(
                in: cg,
                center: ringCenter,
                opensLeft: false,
                tint: iconTint,
                cutoutColor: palette.tileSurface
            )
        case .rightClip:
            // 右耳：C 形桥弓背在右，开口朝左（⊃）
            drawFreeClipEarbudGlyph(
                in: cg,
                center: ringCenter,
                opensLeft: true,
                tint: iconTint,
                cutoutColor: palette.tileSurface
            )
        case .pebbleCase:
            let ledColor = ringColor(for: unit, lowThreshold: lowThreshold, palette: palette)
            drawFreeClipCaseGlyph(
                in: cg,
                center: ringCenter,
                tint: iconTint,
                cutoutColor: palette.tileSurface,
                ledColor: unit.level != nil ? ledColor : palette.placeholderInk
            )
        }

        // 充电闪电角标（右下 45° 弧线节点）
        if unit.level != nil && unit.isCharging {
            let angle = CGFloat.pi / 4
            let badgeCenter = CGPoint(
                x: ringCenter.x + ringRadius * cos(angle),
                y: ringCenter.y + ringRadius * sin(angle)
            )
            drawChargingBadge(in: cg, center: badgeCenter, palette: palette)
        }

        // 部件标签（13pt Medium 中性灰）
        let labelFont = UIFont.systemFont(ofSize: 13, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: palette.mutedInk
        ]
        let labelSize = (title as NSString).size(withAttributes: labelAttrs)
        let labelOrigin = CGPoint(
            x: rect.midX - labelSize.width / 2,
            y: rect.minY + 114
        )
        (title as NSString).draw(at: labelOrigin, withAttributes: labelAttrs)

        // 百分比数字（SF Pro Rounded Bold 23pt）
        let valueText = unit.shortPercent
        let valueFont = roundedFont(ofSize: 23, weight: .bold)
        let valueColor = (unit.level != nil) ? palette.primaryInk : palette.placeholderInk
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: valueColor,
            .kern: -0.4
        ]
        let valueSize = (valueText as NSString).size(withAttributes: valueAttrs)
        let valueOrigin = CGPoint(
            x: rect.midX - valueSize.width / 2,
            y: rect.minY + 136
        )
        (valueText as NSString).draw(at: valueOrigin, withAttributes: valueAttrs)
    }

    // MARK: - 定制硬件矢量剪影（左耳开口向右 ⊂ · 鹅卵石充电盒 · 右耳开口向左 ⊃）

    /// 绘制 FreeClip 2 耳夹轮廓：默认左耳（弓背在左、夹口朝右 `⊂`），`opensLeft = true` 时水平镜像为右耳（弓背在右、夹口朝左 `⊃`）
    private static func drawFreeClipEarbudGlyph(
        in cg: CGContext,
        center: CGPoint,
        opensLeft: Bool,
        tint: UIColor,
        cutoutColor: UIColor
    ) {
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        if opensLeft {
            cg.scaleBy(x: -1.0, y: 1.0)
        }
        // 视觉重心微调，使弓背与右端球豆在圆环内几何居中
        cg.translateBy(x: 0.8, y: 0.0)

        // 1. 左侧单根弹性 C 形桥弓背（连接上端舒适豆与下端聆听球，右侧留出清晰横向夹耳开口）
        let bridge = UIBezierPath()
        bridge.move(to: CGPoint(x: -2.2, y: -6.8))
        bridge.addCurve(
            to: CGPoint(x: -2.0, y: 6.8),
            controlPoint1: CGPoint(x: -12.4, y: -6.6),
            controlPoint2: CGPoint(x: -12.4, y: 6.6)
        )
        bridge.lineWidth = 2.8
        bridge.lineCapStyle = .round
        tint.setStroke()
        bridge.stroke()

        // 2. 上端舒适豆（Comfort Bean，横向微倾人体工学胶囊，右端与下方聆听球形成朝右夹口）
        cg.saveGState()
        cg.translateBy(x: 1.8, y: -6.6)
        cg.rotate(by: 0.20)
        let beanPath = UIBezierPath(
            roundedRect: CGRect(x: -6.2, y: -3.5, width: 12.4, height: 7.0),
            cornerRadius: 3.5
        )
        tint.setFill()
        beanPath.fill()
        cg.restoreGState()

        // 3. 下端聆听球（Acoustic Ball，正圆发声球体）
        let ballCenter = CGPoint(x: 2.8, y: 5.7)
        let ballRadius: CGFloat = 5.3
        tint.setFill()
        cg.fillEllipse(in: CGRect(
            x: ballCenter.x - ballRadius,
            y: ballCenter.y - ballRadius,
            width: ballRadius * 2,
            height: ballRadius * 2
        ))

        // 聆听球声学导孔微细节
        cutoutColor.setFill()
        cg.fillEllipse(in: CGRect(
            x: ballCenter.x + 0.5,
            y: ballCenter.y - 1.8,
            width: 2.1,
            height: 2.1
        ))

        cg.restoreGState()
    }

    /// 绘制 FreeClip 2 方圆鹅卵石充电盒轮廓
    private static func drawFreeClipCaseGlyph(
        in cg: CGContext,
        center: CGPoint,
        tint: UIColor,
        cutoutColor: UIColor,
        ledColor: UIColor
    ) {
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)

        let bodyRect = CGRect(x: -12.5, y: -11.5, width: 25.0, height: 23.0)
        let bodyPath = UIBezierPath(roundedRect: bodyRect, cornerRadius: 7.5)
        tint.setFill()
        bodyPath.fill()

        cutoutColor.setStroke()
        let seam = UIBezierPath()
        seam.move(to: CGPoint(x: -12.5, y: -2.5))
        seam.addLine(to: CGPoint(x: 12.5, y: -2.5))
        seam.lineWidth = 1.5
        seam.stroke()

        let lipRect = CGRect(x: -4.0, y: -3.5, width: 8.0, height: 2.0)
        cutoutColor.setFill()
        UIBezierPath(roundedRect: lipRect, cornerRadius: 1.0).fill()

        ledColor.setFill()
        cg.fillEllipse(in: CGRect(x: -1.35, y: 3.45, width: 2.7, height: 2.7))

        cg.restoreGState()
    }

    private static func drawChargingBadge(
        in cg: CGContext,
        center: CGPoint,
        palette: CardPalette
    ) {
        let outerR: CGFloat = 9.5
        let innerR: CGFloat = 7.5

        palette.tileSurface.setFill()
        cg.fillEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))

        palette.accentGreen.setFill()
        cg.fillEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))

        let bolt = UIBezierPath()
        bolt.move(to: CGPoint(x: center.x + 0.8, y: center.y - 4.3))
        bolt.addLine(to: CGPoint(x: center.x - 2.9, y: center.y + 0.5))
        bolt.addLine(to: CGPoint(x: center.x - 0.3, y: center.y + 0.5))
        bolt.addLine(to: CGPoint(x: center.x - 0.9, y: center.y + 4.3))
        bolt.addLine(to: CGPoint(x: center.x + 2.9, y: center.y - 0.5))
        bolt.addLine(to: CGPoint(x: center.x + 0.3, y: center.y - 0.5))
        bolt.close()
        UIColor.white.setFill()
        bolt.fill()
    }

    private static func ringColor(for unit: BatteryUnit, lowThreshold: Int, palette: CardPalette) -> UIColor {
        guard let level = unit.level else { return palette.ringTrack }
        if level <= lowThreshold && !unit.isCharging { return palette.accentRed }
        if level <= 40 && !unit.isCharging { return palette.accentAmber }
        return palette.accentGreen
    }

    private static func roundedFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let desc = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: desc, size: size)
        }
        return base
    }

    private static func cleanupStaleFiles(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-60)
        for url in files {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
