// Station icons in the isometric style: three lines passing through a sleeve (the transfer),
// drawn from 3D geometry so every edge is smooth. Run: swift design/station/iso/station-iso.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let q = CGFloat(0.5).squareRoot()

struct Look { let bg: CGColor; let fg: CGColor }
let dark = Look(bg: CGColor(gray: 0.04, alpha: 1), fg: CGColor(gray: 0.97, alpha: 1))
let light = Look(bg: CGColor(gray: 0.97, alpha: 1), fg: CGColor(gray: 0.06, alpha: 1))

/// One design, in the sketch's 136-unit tile (y down).
struct Design {
    var name: String
    var lineWidth: CGFloat = 12
    var gap: CGFloat = 25          // line spacing, across
    var halfW: CGFloat = 46        // sleeve cross-section, across the lines
    var halfH: CGFloat = 13        // sleeve cross-section, height
    var corner: CGFloat = 11
    var wall: CGFloat = 6.5        // sleeve wall thickness (the hole is this much smaller)
    var length: CGFloat = 30       // sleeve length, along the lines
    var zv = CGPoint(x: -0.62, y: -0.55) // where "up" goes on screen
    var seam: CGFloat = 3.2        // the gap between touching shapes
    var shift = CGPoint(x: 0, y: 0)
}

func render(_ d: Design, _ look: Look, size: Int, body: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1) // y down, like the sketches
    let margin = (CGFloat(size) - body) / 2, u = body / 136
    let tile = CGRect(x: margin, y: margin, width: body, height: body)
    let squircle = CGPath(roundedRect: tile, cornerWidth: 0.2237 * body, cornerHeight: 0.2237 * body, transform: nil)
    ctx.addPath(squircle); ctx.clip()
    ctx.setFillColor(look.bg); ctx.fill(tile)

    let t = CGPoint(x: q, y: -q), n = CGPoint(x: q, y: q)
    let c = CGPoint(x: tile.midX + d.shift.x * u, y: tile.midY + d.shift.y * u)
    func P(_ a: CGFloat, _ v: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: c.x + (a * t.x + v * n.x + z * d.zv.x) * u, y: c.y + (a * t.y + v * n.y + z * d.zv.y) * u)
    }
    // The portal's cross-section at `a` along the lines: an arch standing on the ground (z = 0),
    // `hh` tall, rounded at the top; open at the bottom, so the tracks run through it.
    func section(_ a: CGFloat, _ hw: CGFloat, _ hh: CGFloat, _ r: CGFloat) -> [CGPoint] {
        var pts: [CGPoint] = [P(a, hw, 0)]
        for i in 0...12 { let th = CGFloat(i) / 12 * .pi / 2; pts.append(P(a, hw - r + r * cos(th), hh - r + r * sin(th))) }
        for i in 0...12 { let th = .pi / 2 + CGFloat(i) / 12 * .pi / 2; pts.append(P(a, -hw + r + r * cos(th), hh - r + r * sin(th))) }
        pts.append(P(a, -hw, 0))
        return pts
    }
    func poly(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p }
    func hull(_ pts: [CGPoint]) -> [CGPoint] {
        let s = pts.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in s { while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }; lower.append(p) }
        for p in s.reversed() { while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }; upper.append(p) }
        return Array(lower.dropLast() + upper.dropLast())
    }
    let half = d.length / 2
    func lines(from a0: CGFloat, to a1: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for k in [-1.0, 0, 1] { p.move(to: P(a0, CGFloat(k) * d.gap, 0)); p.addLine(to: P(a1, CGFloat(k) * d.gap, 0)) }
        return p
    }
    func stroke(_ path: CGPath, _ color: CGColor, _ w: CGFloat, cap: CGLineCap = .butt) {
        ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(w * u); ctx.setLineCap(cap); ctx.setLineJoin(.round); ctx.strokePath()
    }
    func fill(_ path: CGPath, _ color: CGColor) { ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath() }

    // 1. The lines beyond the sleeve (up and right), then the sleeve's body over them.
    stroke(lines(from: half - 1, to: 200), look.fg, d.lineWidth)
    let front = section(-half, d.halfW, d.halfH, d.corner), back = section(half, d.halfW, d.halfH, d.corner)
    let bodyPath = poly(hull(front + back))
    stroke(bodyPath, look.bg, d.seam * 2)            // a seam where the lines meet it
    fill(bodyPath, look.fg)
    // 2. The front face: its edge, then the hole with the lines running into the dark.
    stroke(poly(front), look.bg, d.seam)
    let hole = poly(section(-half, d.halfW - d.wall, d.halfH - d.wall, max(2, d.corner - d.wall)))
    fill(hole, look.bg)
    ctx.saveGState(); ctx.addPath(hole); ctx.clip()
    stroke(lines(from: -half, to: half), look.fg, d.lineWidth)
    ctx.restoreGState()
    // 3. The lines in front (down and left): nearest, so last, with a seam against the face.
    let near = lines(from: -200, to: -half)
    stroke(near, look.bg, d.lineWidth + d.seam * 2)
    stroke(near, look.fg, d.lineWidth)
    return ctx.makeImage()!
}

func png(_ img: CGImage, _ name: String) {
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
}

let designs = [
    Design(name: "portal", halfW: 46, halfH: 36, corner: 18, wall: 11, length: 20, zv: CGPoint(x: 0.3, y: -0.9), shift: CGPoint(x: 4, y: 11)),
    Design(name: "portal-deep", halfW: 46, halfH: 34, corner: 18, wall: 11, length: 32, zv: CGPoint(x: 0.28, y: -0.9), shift: CGPoint(x: 7, y: 11)),
    Design(name: "canopy", lineWidth: 11, halfW: 47, halfH: 28, corner: 9, wall: 10, length: 40, zv: CGPoint(x: 0.3, y: -0.9), shift: CGPoint(x: 4, y: 9)),
]
for d in designs {
    for (look, tag) in [(dark, "dark"), (light, "light")] {
        png(render(d, look, size: 1024, body: 824), "iso-\(d.name)-\(tag)-1024.png")
    }
}
// A sheet: the outsourced pair, then each design dark and light, plus each at 32 px (how the Dock/Finder list shows it).
let names = designs.map(\.name)
let W = 2 * 300 + 40, rows = names.count + 1
let sheet = CGContext(data: nil, width: W * 2, height: rows * 340 * 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.scaleBy(x: 2, y: 2)
sheet.setFillColor(CGColor(gray: 0.55, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: W, height: rows * 340))
func load(_ n: String) -> CGImage { let s = CGImageSourceCreateWithURL(out.appendingPathComponent(n) as CFURL, nil)!; return CGImageSourceCreateImageAtIndex(s, 0, nil)! }
let outsourced = ["../station-icon-dark-art-1024.png", "../station-icon-light-art-1024.png"]
for (r, pair) in ([outsourced] + names.map { ["iso-\($0)-dark-1024.png", "iso-\($0)-light-1024.png"] }).enumerated() {
    let y = CGFloat((rows - 1 - r) * 340)
    for (i, n) in pair.enumerated() {
        let img = load(n)
        sheet.interpolationQuality = .high
        let inset: CGFloat = r == 0 ? 36 : 0 // the outsourced files are full-bleed: show them on the same grid
        sheet.draw(img, in: CGRect(x: 20 + CGFloat(i) * 300 + inset, y: y + 20 + inset, width: 260 - 2 * inset, height: 260 - 2 * inset))
        sheet.draw(img, in: CGRect(x: 20 + CGFloat(i) * 300 + 114, y: y + 290, width: 32, height: 32))
    }
}
png(sheet.makeImage()!, "iso-sheet.png")
print("wrote", designs.count * 2, "icons and iso-sheet.png")
