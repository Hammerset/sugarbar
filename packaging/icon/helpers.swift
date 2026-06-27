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

/// Fill `path` with a radial gradient.
func fillRadialGradient(
    _ ctx: CGContext, path: CGPath,
    colors: [CGColor], locations: [CGFloat],
    center: CGPoint, radius: CGFloat
) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations) else {
        ctx.restoreGState(); return
    }
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Rounded-corner path through the given polygon corners (each corner rounded by `r`).
func roundedPolygon(_ pts: [CGPoint], radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = pts.count
    guard n >= 3 else { return path }
    for i in 0..<n {
        let prev = pts[(i + n - 1) % n]
        let curr = pts[i]
        let next = pts[(i + 1) % n]
        let v1 = CGPoint(x: curr.x - prev.x, y: curr.y - prev.y)
        let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
        let len1 = max(hypot(v1.x, v1.y), 0.0001)
        let len2 = max(hypot(v2.x, v2.y), 0.0001)
        let r1 = min(r, len1 / 2), r2 = min(r, len2 / 2)
        let p1 = CGPoint(x: curr.x - v1.x / len1 * r1, y: curr.y - v1.y / len1 * r1)
        let p2 = CGPoint(x: curr.x + v2.x / len2 * r2, y: curr.y + v2.y / len2 * r2)
        if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
        path.addQuadCurve(to: p2, control: curr)
    }
    path.closeSubpath()
    return path
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
