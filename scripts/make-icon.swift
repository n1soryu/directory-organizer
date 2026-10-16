// Draws the app icon and builds Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
// Three colored file cards (the app's destination "lanes") dropping into a white tray,
// with a sparkle, on the app's indigo-to-purple gradient.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let root = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconDir = root.appending(path: "Resources/Icon")
try FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: an 824-pt rounded square centered in 1024, with room for its shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x1A1060, 0.22))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x5B6CFF))
ctx.fillPath()
ctx.restoreGState()

// Gradient background.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let background = CGGradient(colorsSpace: space, colors: [color(0x4F7BFF), color(0x7A5CFF), color(0xA455F7)] as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Soft light from the top left.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 820), endRadius: 520, options: [])
ctx.restoreGState()

// A file card: rounded rectangle with a folded corner and two text lines.
func card(center: CGPoint, angle: CGFloat, fill: UInt32) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    let w: CGFloat = 230, h: CGFloat = 290, fold: CGFloat = 62
    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x1A1060, 0.30))
    let body = CGMutablePath()
    body.move(to: CGPoint(x: rect.minX + 28, y: rect.minY))
    body.addLine(to: CGPoint(x: rect.maxX - 28, y: rect.minY))
    body.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 28), control: CGPoint(x: rect.maxX, y: rect.minY))
    body.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
    body.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
    body.addLine(to: CGPoint(x: rect.minX + 28, y: rect.maxY))
    body.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 28), control: CGPoint(x: rect.minX, y: rect.maxY))
    body.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 28))
    body.addQuadCurve(to: CGPoint(x: rect.minX + 28, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    body.closeSubpath()
    ctx.addPath(body)
    ctx.setFillColor(color(fill))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Folded corner.
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
    corner.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY - fold + 12))
    corner.addQuadCurve(to: CGPoint(x: rect.maxX - fold + 12, y: rect.maxY - fold), control: CGPoint(x: rect.maxX - fold, y: rect.maxY - fold))
    corner.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
    corner.closeSubpath()
    ctx.addPath(corner)
    ctx.setFillColor(color(0xFFFFFF, 0.45))
    ctx.fillPath()
    // Text lines.
    ctx.setFillColor(color(0xFFFFFF, 0.75))
    for (i, width) in [130.0, 150.0, 96.0].enumerated() {
        let line = CGRect(x: rect.minX + 36, y: rect.maxY - 110 - CGFloat(i) * 40, width: CGFloat(width), height: 18)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

// Cards fanning into the tray: blue (University), green (FSAE), orange (Movies).
card(center: CGPoint(x: 395, y: 560), angle: 14, fill: 0x3D8BFF)
card(center: CGPoint(x: 629, y: 560), angle: -14, fill: 0xFF9F2E)
card(center: CGPoint(x: 512, y: 600), angle: 0, fill: 0x34C76F)

// The tray: a white box in front of the cards' lower half, with a groove for depth.
let top: CGFloat = 470, bottom: CGFloat = 250, left: CGFloat = 250, right: CGFloat = 774
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x1A1060, 0.30))
let tray = CGMutablePath()
tray.move(to: CGPoint(x: left + 18, y: top))
tray.addLine(to: CGPoint(x: right - 18, y: top))
tray.addQuadCurve(to: CGPoint(x: right, y: top - 18), control: CGPoint(x: right, y: top))
tray.addLine(to: CGPoint(x: right, y: bottom + 54))
tray.addQuadCurve(to: CGPoint(x: right - 54, y: bottom), control: CGPoint(x: right, y: bottom))
tray.addLine(to: CGPoint(x: left + 54, y: bottom))
tray.addQuadCurve(to: CGPoint(x: left, y: bottom + 54), control: CGPoint(x: left, y: bottom))
tray.addLine(to: CGPoint(x: left, y: top - 18))
tray.addQuadCurve(to: CGPoint(x: left + 18, y: top), control: CGPoint(x: left, y: top))
tray.closeSubpath()
ctx.addPath(tray)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()
// Groove: a soft lavender band near the top edge, and a handle slot.
ctx.setFillColor(color(0xE4DEFF))
ctx.addPath(CGPath(roundedRect: CGRect(x: left, y: top - 46, width: right - left, height: 10), cornerWidth: 5, cornerHeight: 5, transform: nil))
ctx.fillPath()
ctx.addPath(CGPath(roundedRect: CGRect(x: 432, y: 330, width: 160, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
ctx.fillPath()

// The sparkle: a four-pointed star, top right.
func sparkle(at c: CGPoint, radius r: CGFloat, alpha: CGFloat) {
    let star = CGMutablePath()
    let inner = r * 0.22
    star.move(to: CGPoint(x: c.x, y: c.y + r))
    star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + inner, y: c.y + inner))
    star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + inner, y: c.y - inner))
    star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - inner, y: c.y - inner))
    star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - inner, y: c.y + inner))
    ctx.addPath(star)
    ctx.setFillColor(color(0xFFFFFF, alpha))
    ctx.fillPath()
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 22, color: color(0xFFFFFF, 0.8))
sparkle(at: CGPoint(x: 770, y: 790), radius: 78, alpha: 1)
ctx.restoreGState()
sparkle(at: CGPoint(x: 680, y: 862), radius: 30, alpha: 0.85)

// Save the 1024 master and build the .icns from it.
let master = iconDir.appending(path: "AppIcon-1024.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: master)

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let sips = Process()
        sips.executableURL = URL(filePath: "/usr/bin/sips")
        sips.arguments = ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appending(path: name).path]
        sips.standardOutput = FileHandle.nullDevice
        try sips.run(); sips.waitUntilExit()
        guard sips.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("sips failed for \(name)\n".utf8))
            exit(1)
        }
    }
}
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote Resources/AppIcon.icns and Resources/Icon/AppIcon-1024.png")
