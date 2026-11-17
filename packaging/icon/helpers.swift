import CoreGraphics
import Foundation

// Shared drawing helpers for the icon.

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

/// Apple-style continuous-corner squircle (superellipse) path inset in `rect`.
/// `n` controls corner roundness; ~5 matches the macOS app-icon silhouette.
func squirclePath(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2/n), ct)
        let y = cy + b * copysign(pow(abs(st), 2/n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Fill the given `path` with a linear gradient.
func fillLinearGradient(
    _ ctx: CGContext, path: CGPath,
    colors: [CGColor], locations: [CGFloat],
    start: CGPoint, end: CGPoint
) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations) else {
        ctx.restoreGState(); return
    }
    ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Classic teardrop (blood drop) path centered horizontally at `cx`, tip at `tipY`,
/// bottom bulb of radius `r` whose center sits at `cy`.
func dropPath(cx: CGFloat, tipY: CGFloat, bulbCenterY cy: CGFloat, r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx, y: tipY))
    path.addCurve(
        to: CGPoint(x: cx + r, y: cy),
        control1: CGPoint(x: cx + r * 0.55, y: tipY + (cy - tipY) * 0.45),
        control2: CGPoint(x: cx + r, y: cy - r * 0.7)
    )
    path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
    path.addCurve(
        to: CGPoint(x: cx, y: tipY),
        control1: CGPoint(x: cx - r, y: cy - r * 0.7),
        control2: CGPoint(x: cx - r * 0.55, y: tipY + (cy - tipY) * 0.45)
    )
    path.closeSubpath()
    return path
}
