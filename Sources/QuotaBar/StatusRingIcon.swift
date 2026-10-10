import AppKit
import CoreGraphics

/// 菜单栏三环图标：与 Dock 应用图标（scripts/make-icon.swift）同参数的活动环表盘，
/// 保证两个图标视觉一致。单色 template 版由系统按菜单栏明暗自动着色。
enum StatusRingIcon {
    /// 与应用图标一致的三环几何参数（相对边长比例）。
    private static let radii: [CGFloat] = [0.336, 0.234, 0.132]
    private static let ringFractions: [CGFloat] = [0.86, 0.72, 0.58]
    private static let lineWidth: CGFloat = 0.088
    private static let dotRadius: CGFloat = 0.042

    static func image(size: CGFloat, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(size * lineWidth)
        ctx.setLineCap(.round)

        let center = CGPoint(x: size / 2, y: size / 2)
        for (index, radius) in radii.enumerated() {
            let r = size * radius
            // 轨道底环（低透明度），保持表盘层次。
            ctx.setStrokeColor(color.withAlphaComponent(0.18).cgColor)
            ctx.strokeEllipse(
                in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            )
            ctx.setStrokeColor(color.cgColor)
            let start = CGFloat.pi / 2
            let end = start - ringFractions[index] * 2 * .pi
            ctx.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: true)
            ctx.strokePath()
        }
        let dot = size * dotRadius
        ctx.fillEllipse(
            in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)
        )
        image.unlockFocus()
        return image
    }
}
