import AppKit
import CoreText

// Renders a 1024 px icon: dark rounded square, thin gold italic N. Usage: swift scripts/make-icon.swift build
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let fontURL = URL(fileURLWithPath: "Sources/NitidoUI/Fonts/CormorantGaramond-Italic.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let ctx = NSGraphicsContext.current!.cgContext
    let path = CGPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06), cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil)
    ctx.addPath(path); ctx.clip()
    let colors = [CGColor(srgbRed: 14 / 255, green: 16 / 255, blue: 21 / 255, alpha: 1), CGColor(srgbRed: 8 / 255, green: 9 / 255, blue: 12 / 255, alpha: 1)] as CFArray
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: size * 0.5, y: size * 0.62), startRadius: 0, endCenter: CGPoint(x: size * 0.5, y: size * 0.5), endRadius: size * 0.7, options: [])
    let font = NSFont(name: "CormorantGaramond-Italic", size: size * 0.72) ?? NSFont.systemFont(ofSize: size * 0.72)
    let text = NSAttributedString(string: "N", attributes: [.font: font, .foregroundColor: NSColor.white])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY)
    ctx.setTextDrawingMode(.clip)
    CTLineDraw(line, ctx)
    let gold = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 201 / 255, green: 168 / 255, blue: 106 / 255, alpha: 1), CGColor(srgbRed: 216 / 255, green: 186 / 255, blue: 126 / 255, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gold, start: CGPoint(x: size * 0.3, y: size * 0.2), end: CGPoint(x: size * 0.7, y: size * 0.8), options: [])
    ctx.restoreGState()
    return true
}
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "\(outDir)/icon-1024.png"))
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    let task = Process(); task.launchPath = "/usr/bin/sips"
    task.arguments = ["-z", "\(px)", "\(px)", "\(outDir)/icon-1024.png", "--out", "\(iconset)/icon_\(name).png"]
    task.launch(); task.waitUntilExit()
}
let util = Process(); util.launchPath = "/usr/bin/iconutil"; util.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
util.launch(); util.waitUntilExit()
print("wrote \(outDir)/AppIcon.icns")
