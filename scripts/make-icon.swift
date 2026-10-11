import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Renders the app icon: a dark tile on Apple's macOS grid (an 824 px body on the 1024 canvas, continuous corners, the
// template's shadow) with a thin gold italic N, a faint gold glow behind it and a 1 px highlight along the top edge.
// Every slot of the iconset is drawn at its own pixel size; at 16, 32 and 64 px the N is also stroked, so Cormorant's
// hairline diagonals hold instead of breaking up. It also writes the N alone as a layer for Icon Composer
// (AppIcon.icon), which draws the tile, the glass and the shadow itself, and which is what macOS 15 and 26 both show:
// the app's bundle names it (`CFBundleIconName`, scripts/bundle.sh), and actool flattens its one 1024 px layer for
// every size. The iconset's tuned small sizes therefore reach only a system older than the app's minimum (macOS 11).
// Usage: swift scripts/make-icon.swift build
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
// The font next to this script's repository, wherever it is run from: from anywhere but the repository root, a path
// relative to the current directory found nothing, Core Text fell back to a system font without a word, and the icon
// got the wrong N.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fontURL = repository.appendingPathComponent("Sources/NitidoUI/Fonts/CormorantGaramond-Italic.ttf")
var registrationError: Unmanaged<CFError>?
if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError) {
    let error = registrationError?.takeRetainedValue()
    // Registered already in this process is fine; anything else (the file missing, unreadable) is not.
    if (error.map { CFErrorGetCode($0) } ?? 0) != CTFontManagerError.alreadyRegistered.rawValue {
        fatalError("could not register \(fontURL.path): \(error.map { String(describing: $0) } ?? "unknown error")")
    }
}
let checked = CTFontCreateWithName("CormorantGaramond-Italic" as CFString, 12, nil)
guard CTFontCopyPostScriptName(checked) as String == "CormorantGaramond-Italic" else {
    fatalError("Core Text gave \(CTFontCopyPostScriptName(checked)) for Cormorant Garamond Italic: the icon would get the wrong N")
}
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let gold = rgb(0xc9a86a), goldHighlight = rgb(0xd8ba7e)

/// A rectangle with continuous (squircle-like) corners, as Apple draws its icon tiles: each corner's curve starts
/// 1.528 radii from the corner instead of 1, so the edge eases into the curve.
func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let path = CGMutablePath()
    func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.maxY - y * r) }
    func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.maxY - y * r) }
    func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.minY + y * r) }
    func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.minY + y * r) }
    // One corner: from the edge at 1.528 r to the other edge at 1.528 r. `p(a, b)` maps the corner's own coordinates.
    func corner(_ p: (CGFloat, CGFloat) -> CGPoint) {
        path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
        path.addLine(to: p(0.63149399, 0.07491100))
        path.addCurve(to: p(0.07491100, 0.63149399), control1: p(0.37282392, 0.16905899), control2: p(0.16906013, 0.37282401))
        path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840701), control2: p(0, 1.08849299))
    }
    path.move(to: tl(1.52866483, 0))
    path.addLine(to: tr(1.52866471, 0))
    corner { a, b in tr(a, b) }
    path.addLine(to: br(0, 1.52866471))
    corner { a, b in br(b, a) }
    path.addLine(to: bl(1.52866483, 0))
    corner { a, b in bl(a, b) }
    path.addLine(to: tl(0, 1.52866483))
    corner { a, b in tl(b, a) }
    path.closeSubpath()
    return path
}

/// The N's outline, its glyph `height` px tall, centred on `center`. Drawn as a path filled with the non-zero rule: the
/// variable font's contours overlap, and text drawn in clip mode cut holes where they do.
func letterN(height: CGFloat, center: CGPoint) -> CGPath {
    // The named Italic instance (weight 400), as the wordmark draws it; a glyph's outline comes at the variable font's
    // default (300) unless asked.
    let base = CTFontCreateWithName("CormorantGaramond-Italic" as CFString, 100, nil)
    let weight = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: [0x7767_6874: 400]] as CFDictionary)
    let font = CTFontCreateCopyWithAttributes(base, 100, nil, weight)
    var character: UniChar = 0x4E   // N
    var glyph: CGGlyph = 0
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), let outline = CTFontCreatePathForGlyph(font, glyph, nil) else {
        fatalError("Cormorant Garamond Italic has no N")
    }
    let box = outline.boundingBoxOfPath
    let scale = height / box.height
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -box.midX, y: -box.midY)
    return outline.copy(using: &transform)!
}

/// Draws the N centred in `tile`, 0.64 of its height: gold gradient fill, and at 64 px and under a stroke of
/// `size × 0.014` so the hairlines hold.
func drawN(in ctx: CGContext, tile: CGRect, size: CGFloat) {
    let path = letterN(height: tile.height * 0.64, center: CGPoint(x: tile.midX, y: tile.midY))
    ctx.saveGState()
    if size <= 64 {
        // A solid mid gold: a gradient is invisible at this size, and the stroke must match the fill.
        let mid = rgb(0xd0b174)
        ctx.addPath(path); ctx.setFillColor(mid); ctx.fillPath(using: .winding)
        ctx.addPath(path); ctx.setStrokeColor(mid); ctx.setLineWidth(size * 0.014); ctx.setLineJoin(.round); ctx.strokePath()
    } else {
        ctx.addPath(path); ctx.clip(using: .winding)
        let g = CGGradient(colorsSpace: sRGB, colors: [gold, goldHighlight] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: tile.minX + tile.width * 0.3, y: tile.minY + tile.height * 0.2),
                               end: CGPoint(x: tile.minX + tile.width * 0.7, y: tile.minY + tile.height * 0.8),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
}

/// The whole icon at `px` pixels square.
func renderIcon(px: Int) -> CGImage {
    let size = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let unit = size / 1024
    // Apple's grid: the body is 824 of 1024, centred, a little above centre to leave the shadow room below.
    let body = CGRect(x: 100 * unit, y: 100 * unit + 10 * unit, width: 824 * unit, height: 824 * unit)
    let shape = continuousRect(body, radius: 185.4 * unit)
    // The template's shadow, under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit, color: rgb(0x000000, 0.30))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x08090c)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: sRGB, colors: [rgb(0x15171e), rgb(0x08090c)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: body.midX, y: body.minY + body.height * 0.66), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: body.width * 0.75, options: [.drawsAfterEndLocation])
    // A faint gold glow behind the N.
    let glow = CGGradient(colorsSpace: sRGB, colors: [rgb(0xc9a86a, 0.08), rgb(0xc9a86a, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.midY), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: size * 0.42, options: [])
    drawN(in: ctx, tile: body, size: size)
    // A 1 px highlight along the top edge, inside the tile, fading out down the sides.
    ctx.addPath(shape); ctx.setLineWidth(max(1, 2 * unit)); ctx.replacePathWithStrokedPath(); ctx.clip()
    let rim = CGGradient(colorsSpace: sRGB, colors: [rgb(0xffffff, 0.07), rgb(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.maxY - body.height * 0.3), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// The N alone on a transparent 1024 canvas, sized for Icon Composer's grid: the layer the system lays on its glass.
func renderLetterLayer() -> CGImage {
    let px = 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawN(in: ctx, tile: CGRect(x: 100, y: 100, width: 824, height: 824), size: 1024)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(path)") }
}

let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
writePNG(renderIcon(px: 1024), to: "\(outDir)/icon-1024.png")
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    writePNG(renderIcon(px: px), to: "\(iconset)/icon_\(name).png")
}
let util = Process(); util.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); util.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try util.run(); util.waitUntilExit()
guard util.terminationStatus == 0 else { fatalError("iconutil could not make \(outDir)/AppIcon.icns (status \(util.terminationStatus))") }
print("wrote \(outDir)/AppIcon.icns")

// Icon Composer's format: the tile's fill, and the N as its own layer, which macOS 26 lays on its own glass and shadow.
let composer = "\(outDir)/AppIcon.icon"
try? FileManager.default.createDirectory(atPath: "\(composer)/Assets", withIntermediateDirectories: true)
writePNG(renderLetterLayer(), to: "\(composer)/Assets/N.png")
let manifest = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.08235,0.09020,0.11765,1.00000",
      "srgb:0.03137,0.03529,0.04706,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : true,
          "image-name" : "N.png",
          "name" : "N"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : true,
        "value" : 0.4
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

"""
try manifest.write(toFile: "\(composer)/icon.json", atomically: true, encoding: .utf8)
print("wrote \(composer)")
