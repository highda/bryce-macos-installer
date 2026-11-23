// Draws the app icon (original artwork: a dusk sky, fractal mountains, water
// and a chrome sphere) and writes an .iconset for iconutil.
//
//   swift vm/icon/make-icon.swift OUT.iconset
//
// Deterministic: the same picture on every build, no image files needed.
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
let S: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

/// Small deterministic random generator (so the mountains never change).
struct LCG {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
}

/// A fractal ridge line (midpoint displacement) across [x0, x1].
func ridge(seed: UInt64, x0: CGFloat, x1: CGFloat, base: CGFloat, rough: CGFloat,
           peaks: [(CGFloat, CGFloat)]) -> [CGPoint] {
    var rng = LCG(state: seed)
    let n = 256
    var h = [CGFloat](repeating: 0, count: n + 1)
    var step = n, amp = rough
    while step > 1 {
        let half = step / 2
        var i = 0
        while i < n {
            h[i + half] = (h[i] + h[i + step]) / 2 + (rng.next() - 0.5) * amp
            i += step
        }
        step = half
        amp *= 0.62
    }
    return (0...n).map { i in
        let t = CGFloat(i) / CGFloat(n)
        var y = base + h[i]
        for (px, ph) in peaks {                       // shape the main summits
            let d = (t - px) / 0.09
            y += ph * exp(-d * d)
        }
        return CGPoint(x: x0 + (x1 - x0) * t, y: y)
    }
}

func draw(_ ctx: CGContext) {
    // macOS icon grid: 824 x 824 rounded square centred on 1024.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x1a2350)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let horizon: CGFloat = 400                         // y of the water line (origin bottom-left)

    // Sky.
    ctx.drawLinearGradient(gradient([
        (0.00, rgb(0xf9d9a6)), (0.10, rgb(0xf2a865)), (0.30, rgb(0xc8706b)),
        (0.55, rgb(0x5b4f8f)), (0.80, rgb(0x27306e)), (1.00, rgb(0x141a45)),
    ]), start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 924), options: [])

    // Sun glow on the horizon.
    let sun = CGPoint(x: 640, y: horizon + 40)
    ctx.drawRadialGradient(gradient([(0, rgb(0xfff4d6, 1)), (0.12, rgb(0xffe2a3, 0.9)), (1, rgb(0xf6b26b, 0))]),
                           startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 330, options: [])

    // Far mountains (hazy) and near mountains (rocky).
    func fillRidge(_ pts: [CGPoint], _ g: CGGradient, top: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 100, y: horizon - 2))
        pts.forEach { p.addLine(to: $0) }
        p.addLine(to: CGPoint(x: 924, y: horizon - 2))
        p.closeSubpath()
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: horizon),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    let far = ridge(seed: 7, x0: 100, x1: 924, base: horizon + 90, rough: 170,
                    peaks: [(0.16, 90), (0.58, 60), (0.88, 120)])
    fillRidge(far, gradient([(0, rgb(0x8a74a8)), (1, rgb(0xc08a8a))]), top: horizon + 300)
    let near = ridge(seed: 23, x0: 100, x1: 924, base: horizon + 40, rough: 260,
                     peaks: [(0.28, 210), (0.40, 150), (0.66, 50)])
    fillRidge(near, gradient([(0, rgb(0xe8c29a)), (0.25, rgb(0xb8744a)), (0.6, rgb(0x6b3d33)), (1, rgb(0x2e2230))]),
              top: horizon + 380)
    // Sunlit edge along the near ridge.
    let edge = CGMutablePath()
    edge.addLines(between: near)
    ctx.addPath(edge); ctx.setStrokeColor(rgb(0xffd7a0, 0.55)); ctx.setLineWidth(4); ctx.strokePath()

    // Water: the sky reflected, darker, with light streaks.
    ctx.drawLinearGradient(gradient([(0, rgb(0x0e2a3f)), (0.6, rgb(0x2c4f6e)), (1, rgb(0xb88270))]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: horizon), options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0xffe3b0, 0.55)), (1, rgb(0xffe3b0, 0))]),
                           startCenter: CGPoint(x: 640, y: horizon - 10), startRadius: 0,
                           endCenter: CGPoint(x: 640, y: horizon - 10), endRadius: 260, options: [])
    var rng = LCG(state: 99)
    for i in 0..<9 {                                  // broken glints, fading with distance
        let y = horizon - 14 - CGFloat(i * i) * 3.2 - CGFloat(i) * 9
        for _ in 0..<3 {
            let w = (90 - CGFloat(i) * 6) * (0.4 + rng.next() * 0.6)
            let x = 640 + (rng.next() - 0.5) * (150 + CGFloat(i) * 12)
            ctx.setFillColor(rgb(0xffe6bd, 0.22 - CGFloat(i) * 0.02))
            ctx.fill(CGRect(x: x - w / 2, y: y, width: w, height: 2.5 + CGFloat(i) * 0.25))
        }
    }

    // Chrome sphere resting on the water, with its reflection.
    let c = CGPoint(x: 330, y: 300), r: CGFloat = 118
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r * 0.95, y: c.y - r - 26, width: r * 1.9, height: 30))
    ctx.setFillColor(rgb(0x000000, 0.35)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
    ctx.drawLinearGradient(gradient([
        (0.00, rgb(0x14183a)), (0.42, rgb(0x6f7fb8)), (0.50, rgb(0xf3c58f)),
        (0.56, rgb(0x5b3a3a)), (1.00, rgb(0x0b1020)),
    ]), start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0xffffff, 0)), (0.75, rgb(0x000000, 0)), (1, rgb(0x000000, 0.55))]),
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    let hl = CGPoint(x: c.x - r * 0.38, y: c.y + r * 0.42)
    ctx.drawRadialGradient(gradient([(0, rgb(0xffffff, 0.95)), (1, rgb(0xffffff, 0))]),
                           startCenter: hl, startRadius: 0, endCenter: hl, endRadius: r * 0.42, options: [])
    ctx.restoreGState()

    // Soft vignette and a fine inner rim.
    let mid = CGPoint(x: 512, y: 512)
    ctx.drawRadialGradient(gradient([(0.65, rgb(0x000000, 0)), (1, rgb(0x000000, 0.35))]),
                           startCenter: mid, startRadius: 0, endCenter: mid, endRadius: 600, options: [])
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xffffff, 0.12)); ctx.setLineWidth(2); ctx.strokePath()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    draw(ctx)
    return ctx.makeImage()!
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    let rep = NSBitmapImageRep(cgImage: render(pt * scale))
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}
print("wrote \(outDir.path)")
