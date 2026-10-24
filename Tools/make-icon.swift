// Usage: swift Tools/make-icon.swift <out-dir>   -> writes <out-dir>/icon-1024.png
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsctx
let ctx = nsctx.cgContext
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// Background shape: 82% of canvas, radius 22.4% of shape side.
let side = S * 0.82
let box = CGRect(x: (S - side) / 2, y: (S - side) / 2, width: side, height: side)
let shape = CGPath(roundedRect: box, cornerWidth: side * 0.224, cornerHeight: side * 0.224, transform: nil)

// Background: deep navy (top) to indigo (bottom).
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x0E1038), rgb(0x2A2F8F)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])

let c = CGPoint(x: S / 2, y: S / 2)
let R = side * 0.24

// Stars: deterministic LCG, none under the planet.
var seed: UInt64 = 20240611
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0x1000000)
}
var placed = 0
while placed < 12 {
    let x = box.minX + side * 0.06 + rnd() * side * 0.88
    let y = box.minY + side * 0.06 + rnd() * side * 0.88
    let big = placed % 3 == 0
    let sr = side * (big ? 0.0072 : 0.0042)
    let op = 0.55 + rnd() * 0.35
    if hypot(x - c.x, y - c.y) < R + side * 0.06 { continue }
    ctx.setFillColor(rgb(0xFFFFFF, op))
    ctx.fillEllipse(in: CGRect(x: x - sr, y: y - sr, width: sr * 2, height: sr * 2))
    placed += 1
}
ctx.restoreGState()

// Planet.
let disk = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
func drawPlanet() {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.025), blur: side * 0.05, color: rgb(0x000000, 0.45))
    ctx.setFillColor(rgb(0x157F8A))
    ctx.fillEllipse(in: disk)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: disk); ctx.clip()
    let pg = CGGradient(colorsSpace: cs, colors: [rgb(0x2BC3B5), rgb(0x157F8A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(pg, start: CGPoint(x: c.x - R * 0.8, y: c.y + R * 0.8),
                           end: CGPoint(x: c.x + R * 0.8, y: c.y - R * 0.8), options: [])
    // Soft terminator, lower right.
    let tg = CGGradient(colorsSpace: cs, colors: [rgb(0x041a3a, 0), rgb(0x041a3a, 0.5)] as CFArray, locations: [0, 1])!
    let tc = CGPoint(x: c.x - R * 0.45, y: c.y + R * 0.45)
    ctx.drawRadialGradient(tg, startCenter: tc, startRadius: R * 0.9, endCenter: tc, endRadius: R * 1.9, options: [])
    // Faint light rim, upper left.
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.28)); ctx.setLineWidth(side * 0.008)
    ctx.addArc(center: c, radius: R - side * 0.004, startAngle: 100 * .pi / 180, endAngle: 190 * .pi / 180, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

// Ring: tilted ellipse, three storage arcs.
let tilt = 22.0 * Double.pi / 180
let rx = side * 0.44, ry = side * 0.13
let stroke = side * 0.075
func pt(_ tDeg: Double) -> CGPoint {
    let t = tDeg * .pi / 180
    let lx = Double(rx) * cos(t), ly = Double(ry) * sin(t)
    return CGPoint(x: c.x + CGFloat(lx * cos(tilt) - ly * sin(tilt)),
                   y: c.y + CGFloat(lx * sin(tilt) + ly * cos(tilt)))
}
// Parameter angle (CCW). Front (viewer side) is sin(t) < 0, i.e. 180...360.
let gap = 15.0
let parts: [(Double, CGColor)] = [(0.58, rgb(0xFFFFFF)), (0.14, rgb(0xFFC94A)), (0.28, rgb(0xFFFFFF, 0.35))]
func drawRing(front: Bool) {
    ctx.saveGState()
    var tf = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(tilt))
    let half = CGRect(x: -2000, y: front ? -2000 : -1.5, width: 4000, height: 2001.5)
    ctx.addPath(CGPath(rect: half, transform: &tf)); ctx.clip()
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(stroke)
    var pos = 165.0
    for (frac, col) in parts {
        let slot = frac * 360
        let a0 = pos + gap / 2, a1 = pos + slot - gap / 2
        ctx.setStrokeColor(col)
        ctx.move(to: pt(a0))
        var a = a0
        while a < a1 { a += 1; ctx.addLine(to: pt(min(a, a1))) }
        ctx.strokePath()
        pos += slot
    }
    ctx.restoreGState()
}
drawRing(front: false)
drawPlanet()
drawRing(front: true)

NSGraphicsContext.current = nil
let png = rep.representation(using: .png, properties: [:])!
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon-1024.png"))
