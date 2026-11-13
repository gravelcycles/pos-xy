// Renders the iPhone app icon's Dark and Tinted variants (iOS 18+ Home Screen appearances)
// into iOS/Assets.xcassets/AppIcon.appiconset. The default (light) icon-1024.png is left as is;
// this redraws the same design: a grid with a track from a start dot to an end pin.
//
//   swift scripts/make-icon-variants.swift
//
// Dark: transparent background (iOS supplies its dark backdrop), dimmer grid, same colours.
// Tinted: grayscale on black; iOS colours it with the user's tint.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                                 : "iOS/Assets.xcassets/AppIcon.appiconset")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gray(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: w, green: w, blue: w, alpha: a) }

enum Variant { case dark, tinted }

// Design coordinates measured from icon-1024.png (origin top-left).
let track: [(color: UInt32, tint: CGFloat, points: [CGPoint])] = [
    (0x2EB35A, 0.78, [CGPoint(x: 210, y: 800), CGPoint(x: 300, y: 680), CGPoint(x: 420, y: 700)]),
    (0x3375F0, 0.90, [CGPoint(x: 420, y: 700), CGPoint(x: 470, y: 560), CGPoint(x: 600, y: 520)]),
    (0x0EA9C0, 1.00, [CGPoint(x: 600, y: 520), CGPoint(x: 630, y: 390), CGPoint(x: 780, y: 300)]),
]

func render(_ v: Variant) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to top-left origin to match the measured coordinates.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)

    if v == .tinted {
        ctx.setFillColor(gray(0))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }

    // Grid
    ctx.setStrokeColor(v == .dark ? rgb(0x8FA8D8, 0.22) : gray(1, 0.16))
    ctx.setLineWidth(3)
    for i in 1...10 {
        let p = CGFloat(i * 96)
        ctx.move(to: CGPoint(x: p, y: 0)); ctx.addLine(to: CGPoint(x: p, y: CGFloat(size)))
        ctx.move(to: CGPoint(x: 0, y: p)); ctx.addLine(to: CGPoint(x: CGFloat(size), y: p))
    }
    ctx.strokePath()

    // Track, drawn as three coloured legs with round joins.
    ctx.setLineWidth(52)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for leg in track {
        ctx.setStrokeColor(v == .dark ? rgb(leg.color) : gray(leg.tint))
        ctx.addLines(between: leg.points)
        ctx.strokePath()
    }

    // Start dot and end pin.
    func dot(_ c: CGPoint, _ outer: CGFloat, _ inner: CGFloat, _ innerColor: CGColor) {
        ctx.setFillColor(v == .dark ? gray(0.96) : gray(1))
        ctx.fillEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        ctx.setFillColor(innerColor)
        ctx.fillEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
    }
    dot(CGPoint(x: 210, y: 800), 48, 26, v == .dark ? rgb(0x2EB35A) : gray(0.55))
    dot(CGPoint(x: 780, y: 300), 80, 46, v == .dark ? rgb(0xE53F73) : gray(0.35))

    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "couldn't write \(url.path)")
    print("wrote", url.path)
}

write(render(.dark), "icon-1024-dark.png")
write(render(.tinted), "icon-1024-tinted.png")
