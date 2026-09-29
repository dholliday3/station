// Builds the app icon set and the light/dark Dock images from design/station's 1024 px renders.
// Run: swift scripts/make-app-icon.swift   (after swift design/station/station-icon.swift)
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let design = root.appendingPathComponent("design/station")
let assets = root.appendingPathComponent("Station/Assets.xcassets")

func load(_ name: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(design.appendingPathComponent(name) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
func write(_ img: CGImage, size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
}

// The app's own icon (Finder, the app switcher before launch): the dark one.
let dark = load("station-icon-dark-1024.png"), light = load("station-icon-light-1024.png")
let set = assets.appendingPathComponent("AppIcon.appiconset")
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for s in scales { write(dark, size: pt * s, to: set.appendingPathComponent(s == 1 ? "icon_\(pt).png" : "icon_\(pt)@2x.png")) }
}
// Dock images for the Automatic / Light / Dark choice.
for (img, name) in [(dark, "StationIconDark"), (light, "StationIconLight")] {
    let dir = assets.appendingPathComponent("\(name).imageset")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    write(img, size: 1024, to: dir.appendingPathComponent("\(name).png"))
    let contents = #"{"images":[{"filename":"\#(name).png","idiom":"mac"}],"info":{"author":"xcode","version":1}}"#
    try? contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
print("wrote AppIcon.appiconset, StationIconDark, StationIconLight")
