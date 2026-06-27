import CoreGraphics

// Sugarbar app icon: an isometric white sugar cube on a calm blue squircle,
// with a small, discreet blood drop nestled at the cube's front-right base.
func drawIcon(_ ctx: CGContext, _ S: CGFloat) {
    let margin = S * 0.0977
    let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let sq = squirclePath(in: rect)

    // Calm blue background: light airy blue, slightly deeper toward the bottom.
    fillLinearGradient(ctx, path: sq,
        colors: [rgb(214, 233, 250), rgb(150, 192, 236), rgb(108, 158, 218)],
        locations: [0, 0.55, 1],
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY))

    // Soft inner glow at upper-center so the white cube has airy space to sit in.
    fillRadialGradient(ctx, path: sq,
        colors: [rgb(255, 255, 255, 0.45), rgb(255, 255, 255, 0)],
        locations: [0, 1],
        center: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.30),
        radius: rect.width * 0.62)

    // Subtle top sheen along the squircle's upper edge for a glossy app-icon feel.
    fillLinearGradient(ctx, path: sq,
        colors: [rgb(255, 255, 255, 0.30), rgb(255, 255, 255, 0)],
        locations: [0, 1],
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.22))

    drawCube(ctx, S, rect)
}

private func drawCube(_ ctx: CGContext, _ S: CGFloat, _ rect: CGRect) {
    let cx = rect.midX
    let cy = rect.midY - S * 0.004

    let w = S * 0.212          // horizontal reach to left/right corners
    let topH = S * 0.122       // vertical half-height of the top diamond
    let sideH = S * 0.242      // height of the vertical side faces

    let topCenter = CGPoint(x: cx, y: cy - sideH * 0.5)

    let tTop   = CGPoint(x: topCenter.x,     y: topCenter.y - topH)
    let tRight = CGPoint(x: topCenter.x + w,  y: topCenter.y)
    let tBot   = CGPoint(x: topCenter.x,     y: topCenter.y + topH)
    let tLeft  = CGPoint(x: topCenter.x - w,  y: topCenter.y)

    let bRight = CGPoint(x: tRight.x, y: tRight.y + sideH)
    let bBot   = CGPoint(x: tBot.x,   y: tBot.y + sideH)
    let bLeft  = CGPoint(x: tLeft.x,  y: tLeft.y + sideH)

    let cubeR = S * 0.022
    let cornerR = S * 0.012

    // Contact shadow on the floor (negative dy convention => falls downward on screen).
    ctx.saveGState()
    let shadowPath = CGMutablePath()
    let shCx = cx
    let shCy = bBot.y + S * 0.014
    shadowPath.addEllipse(in: CGRect(x: shCx - w * 1.0, y: shCy - S * 0.040,
                                     width: w * 2.0, height: S * 0.085))
    ctx.addPath(shadowPath)
    ctx.clip()
    fillRadialGradient(ctx, path: shadowPath,
        colors: [rgb(34, 62, 102, 0.46), rgb(34, 62, 102, 0)],
        locations: [0, 1],
        center: CGPoint(x: shCx, y: shCy),
        radius: w * 1.1)
    ctx.restoreGState()

    let leftFace = roundedPolygon([tLeft, tBot, bBot, bLeft], radius: cornerR)
    fillLinearGradient(ctx, path: leftFace,
        colors: [rgb(225, 235, 246), rgb(198, 214, 233)],
        locations: [0, 1],
        start: CGPoint(x: tLeft.x, y: tLeft.y),
        end: CGPoint(x: bBot.x, y: bBot.y))

    let rightFace = roundedPolygon([tBot, tRight, bRight, bBot], radius: cornerR)
    fillLinearGradient(ctx, path: rightFace,
        colors: [rgb(197, 213, 233), rgb(156, 180, 211)],
        locations: [0, 1],
        start: CGPoint(x: tBot.x, y: tBot.y),
        end: CGPoint(x: bRight.x, y: bRight.y))

    let topFace = roundedPolygon([tTop, tRight, tBot, tLeft], radius: cubeR)
    fillLinearGradient(ctx, path: topFace,
        colors: [rgb(255, 255, 255), rgb(241, 247, 253)],
        locations: [0, 1],
        start: CGPoint(x: tTop.x, y: tTop.y),
        end: CGPoint(x: tBot.x, y: tBot.y))
    fillRadialGradient(ctx, path: topFace,
        colors: [rgb(255, 255, 255, 0.9), rgb(255, 255, 255, 0)],
        locations: [0, 1],
        center: CGPoint(x: topCenter.x, y: topCenter.y - topH * 0.35),
        radius: w * 0.85)

    // Crisp front vertical edge keeps the 3D legible at small sizes.
    ctx.setLineWidth(max(S * 0.0016, 0.6))
    ctx.setStrokeColor(rgb(120, 150, 188, 0.45))
    let edge = CGMutablePath()
    edge.move(to: tBot); edge.addLine(to: bBot)
    ctx.addPath(edge)
    ctx.strokePath()

    ctx.setLineWidth(max(S * 0.0022, 0.8))
    ctx.setStrokeColor(rgb(255, 255, 255, 0.7))
    let rim = CGMutablePath()
    rim.move(to: tLeft); rim.addLine(to: tTop)
    ctx.addPath(rim)
    ctx.strokePath()

    drawDrop(ctx, S, cubeRightBottom: bRight, cubeFrontBottom: bBot)
}

private func drawDrop(_ ctx: CGContext, _ S: CGFloat,
                      cubeRightBottom: CGPoint, cubeFrontBottom: CGPoint) {
    let dr = S * 0.050
    let dcx = cubeFrontBottom.x + (cubeRightBottom.x - cubeFrontBottom.x) * 0.58
    let bulbCy = cubeFrontBottom.y + S * 0.034
    let tipY = bulbCy - dr * 2.05
    let drop = dropPath(cx: dcx, tipY: tipY, bulbCenterY: bulbCy, r: dr)

    ctx.saveGState()
    let ds = CGMutablePath()
    ds.addEllipse(in: CGRect(x: dcx - dr * 0.95, y: bulbCy + dr * 0.45,
                             width: dr * 1.9, height: dr * 0.7))
    ctx.addPath(ds)
    ctx.clip()
    fillRadialGradient(ctx, path: ds,
        colors: [rgb(90, 20, 30, 0.30), rgb(90, 20, 30, 0)],
        locations: [0, 1],
        center: CGPoint(x: dcx, y: bulbCy + dr * 0.55),
        radius: dr * 1.1)
    ctx.restoreGState()

    fillLinearGradient(ctx, path: drop,
        colors: [rgb(206, 58, 70), rgb(168, 32, 46)],
        locations: [0, 1],
        start: CGPoint(x: dcx, y: tipY),
        end: CGPoint(x: dcx, y: bulbCy + dr))

    let hl = CGMutablePath()
    let hlcx = dcx - dr * 0.32
    let hlcy = bulbCy - dr * 0.30
    hl.addEllipse(in: CGRect(x: hlcx - dr * 0.30, y: hlcy - dr * 0.40,
                             width: dr * 0.55, height: dr * 0.72))
    ctx.saveGState()
    ctx.addPath(hl)
    ctx.clip()
    fillRadialGradient(ctx, path: hl,
        colors: [rgb(255, 235, 238, 0.85), rgb(255, 235, 238, 0)],
        locations: [0, 1],
        center: CGPoint(x: hlcx, y: hlcy),
        radius: dr * 0.5)
    ctx.restoreGState()
}
