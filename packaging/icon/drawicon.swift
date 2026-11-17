import CoreGraphics

enum Appearance: String {
    case light, dark, tinted
}

// Sugarbar app icon: a white drop on navy, with the in-range band and a glucose trace running through it.
// `fullBleed` fills the whole canvas (iOS masks it itself); otherwise it draws the inset macOS squircle.
func drawIcon(_ ctx: CGContext, _ S: CGFloat, appearance: Appearance = .light, fullBleed: Bool = false) {
    let margin = fullBleed ? 0 : S * 0.0977
    let r = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let tile: CGPath = fullBleed ? CGPath(rect: r, transform: nil) : squirclePath(in: r)
    // Below ~64 px the thin trace and pale band blur into the drop, so small renders get bolder strokes.
    let small = r.width < 64

    let background: [CGColor]
    let dropColor: CGColor
    let bandColor: CGColor
    let traceColor: CGColor
    switch appearance {
    case .light:
        background = [rgb(38, 70, 110), rgb(18, 38, 66)]
        dropColor = rgb(250, 251, 253)
        bandColor = small ? rgb(52, 199, 89) : rgb(52, 199, 89, 0.40)
        traceColor = rgb(18, 38, 66)
    case .dark:
        background = [rgb(26, 30, 38), rgb(10, 12, 16)]
        dropColor = rgb(240, 242, 246)
        bandColor = small ? rgb(48, 209, 88) : rgb(48, 209, 88, 0.45)
        traceColor = rgb(14, 18, 26)
    case .tinted:
        background = [rgb(0, 0, 0), rgb(0, 0, 0)]
        dropColor = rgb(255, 255, 255)
        bandColor = rgb(150, 150, 150)
        traceColor = rgb(40, 40, 40)
    }

    fillLinearGradient(ctx, path: tile, colors: background, locations: [0, 1],
        start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY))

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }

    let drop = dropPath(cx: r.midX, tipY: r.minY + r.height * 0.14,
                        bulbCenterY: r.minY + r.height * 0.60, r: r.width * 0.26)
    ctx.addPath(drop)
    ctx.setFillColor(dropColor)
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(drop)
    ctx.clip()
    ctx.setFillColor(bandColor)
    ctx.fill(CGRect(x: r.minX, y: r.minY + r.height * 0.51, width: r.width, height: r.height * 0.16))

    let trace = CGMutablePath()
    trace.move(to: p(0.22, 0.42))
    trace.addCurve(to: p(0.48, 0.64), control1: p(0.32, 0.42), control2: p(0.38, 0.64))
    trace.addCurve(to: p(0.80, 0.57), control1: p(0.58, 0.64), control2: p(0.66, 0.57))
    ctx.addPath(trace)
    ctx.setLineWidth(r.width * (small ? 0.10 : 0.06))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(traceColor)
    ctx.strokePath()
    ctx.restoreGState()
}
