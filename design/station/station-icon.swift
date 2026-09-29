// Renders Station's icon (light and dark, 1024 px), its menu bar states, and a
// pulse animation. Run: swift design/station/station-icon.swift (writes next to this file).
import AppKit
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let q = CGFloat(0.5).squareRoot()

struct Look { let bg: NSColor; let line: NSColor; let pill: NSColor; let edge: NSColor }
let dark = Look(bg: NSColor(white: 0.045, alpha: 1), line: NSColor(white: 0.97, alpha: 1), pill: NSColor(white: 0.97, alpha: 1), edge: NSColor(white: 0.045, alpha: 1))
let light = Look(bg: NSColor(white: 0.965, alpha: 1), line: NSColor(white: 0.07, alpha: 1), pill: .white, edge: NSColor(white: 0.07, alpha: 1))

/// Three parallel lines at 45°, bottom left to top right, and a transfer pill across them.
/// `alphas`/`colors`: per line (top-left first). Units are the sketch's 136-unit tile.
func drawMark(_ ctx: CGContext, in r: CGRect, look: Look, square: Bool, alphas: [CGFloat] = [1, 1, 1], colors: [NSColor?] = [nil, nil, nil],
              width lw: CGFloat = 10, gap: CGFloat = 22, pillR: CGFloat = 10, pillHalf: CGFloat = 30, edgeW: CGFloat = 3, radius: CGFloat = 30) {
    let u = r.width / 136
    let c = CGPoint(x: r.midX, y: r.midY)
    let shape = CGPath(roundedRect: r, cornerWidth: radius * u, cornerHeight: radius * u, transform: nil)
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    if square { ctx.setFillColor(look.bg.cgColor); ctx.fill(r) }
    ctx.setLineWidth(lw * u)
    ctx.setLineCap(.butt)
    for (i, k) in [-1, 0, 1].enumerated() {
        // In y-up space "down-right" is (q, -q): the top-left line is k = -1.
        let o = CGPoint(x: c.x + CGFloat(k) * gap * u * q, y: c.y - CGFloat(k) * gap * u * q)
        ctx.setStrokeColor((colors[i] ?? look.line).withAlphaComponent(alphas[i]).cgColor)
        ctx.move(to: CGPoint(x: o.x - 200 * u, y: o.y - 200 * u))
        ctx.addLine(to: CGPoint(x: o.x + 200 * u, y: o.y + 200 * u))
        ctx.strokePath()
    }
    // The transfer: a capsule along the lines' normal, white with a black edge, as on the map.
    let a = CGPoint(x: c.x - pillHalf * u * q, y: c.y + pillHalf * u * q), b = CGPoint(x: c.x + pillHalf * u * q, y: c.y - pillHalf * u * q)
    let pill = CGMutablePath()
    pill.move(to: a); pill.addLine(to: b)
    let capsule = pill.copy(strokingWithWidth: pillR * 2 * u, lineCap: .round, lineJoin: .round, miterLimit: 1)
    ctx.addPath(capsule); ctx.setFillColor(look.pill.cgColor); ctx.fillPath()
    ctx.addPath(capsule); ctx.setStrokeColor(look.edge.cgColor); ctx.setLineWidth(edgeW * u); ctx.strokePath()
    ctx.restoreGState()
}

func image(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx)
    return ctx.makeImage()!
}

func png(_ img: CGImage, _ name: String) {
    let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    print("wrote \(name)")
}

func label(_ ctx: CGContext, _ s: String, _ p: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .medium) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    NSGraphicsContext.restoreGraphicsState()
}

// 1. App icons: macOS grid, an 824 px body centred in 1024, no shadow.
for (look, name) in [(dark, "station-icon-dark-1024.png"), (light, "station-icon-light-1024.png")] {
    png(image(1024, 1024) { ctx in drawMark(ctx, in: CGRect(x: 100, y: 100, width: 824, height: 824), look: look, square: true, radius: 30) }, name)
}

// 2. Side by side with Onramp's icon today.
let onramp = NSImage(contentsOf: out.deletingLastPathComponent().appendingPathComponent("icon-1024.png"))!
png(image(2100, 820) { ctx in
    ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 700, height: 820))
    ctx.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor); ctx.fill(CGRect(x: 700, y: 0, width: 700, height: 820))
    ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor); ctx.fill(CGRect(x: 1400, y: 0, width: 700, height: 820))
    if let cg = onramp.cgImage(forProposedRect: nil, context: nil, hints: nil) { ctx.draw(cg, in: CGRect(x: 60, y: 160, width: 580, height: 580)) }
    drawMark(ctx, in: CGRect(x: 760 + 58, y: 160 + 58, width: 464, height: 464), look: dark, square: true)
    drawMark(ctx, in: CGRect(x: 1460 + 58, y: 160 + 58, width: 464, height: 464), look: light, square: true)
    label(ctx, "Onramp today", CGPoint(x: 60, y: 70), size: 34, color: .white)
    label(ctx, "Station, dark", CGPoint(x: 760, y: 70), size: 34, color: .white)
    label(ctx, "Station, light", CGPoint(x: 1460, y: 70), size: 34, color: NSColor(white: 0.1, alpha: 1))
}, "station-vs-onramp.png")

// 3. Menu bar: the three lines are Stoplight's lights (red failing, yellow running, green passing),
// each lit when any PR is in that state; the transfer pill is your agents (pulses while one works,
// orange when one is waiting on you).
let dim: CGFloat = 0.3
let red = NSColor.systemRed, yellow = NSColor.systemYellow, green = NSColor.systemGreen
struct State { let name: String; let note: String; let lit: [Bool]; let pill: CGFloat; let waiting: Bool }
let states: [State] = [
    State(name: "No PRs", note: "all dim", lit: [false, false, false], pill: 1, waiting: false),
    State(name: "All green", note: "green lit", lit: [false, false, true], pill: 1, waiting: false),
    State(name: "Checks running", note: "yellow pulses", lit: [false, true, true], pill: 1, waiting: false),
    State(name: "Something failing", note: "red lit", lit: [true, true, true], pill: 1, waiting: false),
    State(name: "Agent working", note: "pill pulses", lit: [false, false, true], pill: 0.45, waiting: false),
    State(name: "Agent needs you", note: "pill turns orange", lit: [true, false, true], pill: 1, waiting: true),
]
/// The menu bar version: thicker, fewer units per point, so it holds at 18 pt.
func glyph(_ ctx: CGContext, _ r: CGRect, _ st: State, ink: NSColor, bar: NSColor, yellowAlpha: CGFloat? = nil) {
    let colors: [NSColor] = [red, yellow, green]
    let alphas = st.lit.enumerated().map { i, on in i == 1 && on ? (yellowAlpha ?? 1) : (on ? 1 : dim) }
    let offs = st.lit.enumerated().map { i, on in on ? colors[i] : ink }
    let pillColor = st.waiting ? NSColor.systemOrange : ink.withAlphaComponent(st.pill)
    let look = Look(bg: .clear, line: ink, pill: pillColor, edge: bar)
    drawMark(ctx, in: r, look: look, square: false, alphas: alphas, colors: offs, width: 14, gap: 36, pillR: 12, pillHalf: 40, edgeW: 9, radius: 36)
}
let cellW = 330
png(image(cellW * states.count, 760) { ctx in
    for (row, (bar, ink, text)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black, NSColor(white: 0.1, alpha: 1)),
                                    (NSColor(white: 0.16, alpha: 1), NSColor.white, NSColor(white: 0.92, alpha: 1))].enumerated() {
        let y0 = CGFloat(row == 0 ? 380 : 0)
        ctx.setFillColor(bar.cgColor); ctx.fill(CGRect(x: 0, y: y0, width: CGFloat(cellW * states.count), height: 380))
        for (i, s) in states.enumerated() {
            let x0 = CGFloat(i * cellW)
            glyph(ctx, CGRect(x: x0 + 85, y: y0 + 150, width: 160, height: 160), s, ink: ink, bar: bar)   // 9x, to see it
            glyph(ctx, CGRect(x: x0 + 85, y: y0 + 108, width: 18, height: 18), s, ink: ink, bar: bar)     // actual size (1x)
            glyph(ctx, CGRect(x: x0 + 115, y: y0 + 99, width: 36, height: 36), s, ink: ink, bar: bar)     // actual size (2x, retina)
            label(ctx, s.name, CGPoint(x: x0 + 30, y: y0 + 50), size: 26, color: text, weight: .semibold)
            label(ctx, s.note, CGPoint(x: x0 + 30, y: y0 + 18), size: 21, color: text.withAlphaComponent(0.6))
        }
    }
}, "station-menubar-states.png")

// 4. The pulses, as they'd move: yellow while checks run, then the pill while an agent works. 3x size.
let frames = 36
let gif = CGImageDestinationCreateWithURL(out.appendingPathComponent("station-menubar-pulse.gif") as CFURL, UTType.gif.identifier as CFString, frames * 2, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for pass in 0..<2 {
    for f in 0..<frames {
        let t = CGFloat(f) / CGFloat(frames)
        let a = dim + (1 - dim) * (0.5 - 0.5 * cos(2 * .pi * t)) // ease in and out, once per 1.2 s
        let st = pass == 0 ? State(name: "", note: "", lit: [false, true, true], pill: 1, waiting: false)
                           : State(name: "", note: "", lit: [false, false, true], pill: max(0.35, a), waiting: false)
        let frame = image(360, 120) { ctx in
            ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 180, height: 120))
            ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor); ctx.fill(CGRect(x: 180, y: 0, width: 180, height: 120))
            glyph(ctx, CGRect(x: 63, y: 33, width: 54, height: 54), st, ink: .black, bar: NSColor(white: 0.93, alpha: 1), yellowAlpha: pass == 0 ? a : nil)
            glyph(ctx, CGRect(x: 243, y: 33, width: 54, height: 54), st, ink: .white, bar: NSColor(white: 0.16, alpha: 1), yellowAlpha: pass == 0 ? a : nil)
        }
        CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.2 / Double(frames)]] as CFDictionary)
    }
}
CGImageDestinationFinalize(gif)
print("wrote station-menubar-pulse.gif")
