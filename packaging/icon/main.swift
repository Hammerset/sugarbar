import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Headless render harness for the Sugarbar app icon.
// drawicon.swift supplies `func drawIcon(_ ctx: CGContext, _ S: CGFloat)`.
// Coordinate system handed to drawIcon: origin top-left, y increases downward,
// canvas is S x S points (== pixels at this render size).

func makeContext(_ size: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create context") }
    return ctx
}

func writePNG(_ ctx: CGContext, to path: String) {
    guard let img = ctx.makeImage() else { fatalError("no image") }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("no destination") }
    CGImageDestinationAddImage(dest, img, nil)
    if !CGImageDestinationFinalize(dest) { fatalError("could not write png") }
}

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon.png"
let size = args.count > 2 ? (Int(args[2]) ?? 1024) : 1024

let ctx = makeContext(size)
let S = CGFloat(size)
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
// Flip to top-left origin (y-down) design coordinates.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)
drawIcon(ctx, S)
writePNG(ctx, to: outPath)
