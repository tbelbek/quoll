// Renders the Quoll app icon (1024x1024 PNG). Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824pt body centred on a 1024 canvas, ~185pt corner radius.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(color(0x0B3A4A))
ctx.fillPath()
ctx.restoreGState()

// Background gradient: deep teal (top) to indigo (bottom).
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let background = CGGradient(colorsSpace: space, colors: [color(0x1FB5A8), color(0x1B6F9C), color(0x2B3A8F)] as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Soft top highlight.
let gloss = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Magnifier: lens ring + handle drawn in one transparency layer, so they share a
// single shadow and show no seam where they meet.
let lensCenter = CGPoint(x: 452, y: 572)
let lensRadius: CGFloat = 215
let ring: CGFloat = 54
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x061B33, 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineCap(.round)
ctx.setLineWidth(92)
// The handle's round cap (radius 46) must stay inside the ring, not reach the glass.
let handleFrom = lensRadius + 22
ctx.move(to: CGPoint(x: lensCenter.x + handleFrom * cos(-.pi / 4), y: lensCenter.y + handleFrom * sin(-.pi / 4)))
ctx.addLine(to: CGPoint(x: 770, y: 254))
ctx.strokePath()
ctx.setLineWidth(ring)
ctx.addEllipse(in: CGRect(x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius,
                          width: lensRadius * 2, height: lensRadius * 2))
ctx.strokePath()
ctx.endTransparencyLayer()
ctx.restoreGState()

// Lens glass: faint fill, then three result rows (the "instant list").
ctx.saveGState()
let glass = CGRect(x: lensCenter.x - lensRadius + ring / 2, y: lensCenter.y - lensRadius + ring / 2,
                   width: (lensRadius - ring / 2) * 2, height: (lensRadius - ring / 2) * 2)
ctx.addEllipse(in: glass)
ctx.clip()
ctx.setFillColor(color(0xFFFFFF, 0.14))
ctx.fill(glass)
let rows: [(CGFloat, CGFloat, CGFloat)] = [(lensCenter.y + 78, 250, 1.0), (lensCenter.y, 200, 0.85), (lensCenter.y - 78, 228, 0.7)]
for (y, width, alpha) in rows {
    let left = lensCenter.x - 130
    ctx.setFillColor(color(0xFFFFFF, alpha))
    ctx.addPath(CGPath(roundedRect: CGRect(x: left + 52, y: y - 15, width: width - 52, height: 30),
                       cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: left, y: y - 19, width: 38, height: 38))   // file dot
}
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
