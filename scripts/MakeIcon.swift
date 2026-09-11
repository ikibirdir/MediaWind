// Draws the app icon and writes Resources/AppIcon.icns (build.sh copies it into the app).
//
//   swift scripts/MakeIcon.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Body: the standard macOS icon grid (824/1024) with a soft shadow.
    let body = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0.1, 0.11, 0.15))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bodyGradient = CGGradient(colorsSpace: nil, colors: [rgb(0.23, 0.26, 0.36), rgb(0.07, 0.08, 0.12)] as CFArray,
                                  locations: [0, 1])!
    ctx.drawLinearGradient(bodyGradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // The photo: sky, sun, two mountains.
    let photo = CGRect(x: s * 0.25, y: s * 0.29, width: s * 0.5, height: s * 0.42)
    let photoPath = CGPath(roundedRect: photo, cornerWidth: s * 0.035, cornerHeight: s * 0.035, transform: nil)
    ctx.saveGState()
    ctx.addPath(photoPath)
    ctx.clip()
    let sky = CGGradient(colorsSpace: nil, colors: [rgb(0.36, 0.62, 0.98), rgb(0.7, 0.85, 1.0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: photo.minY), options: [])
    ctx.setFillColor(rgb(1.0, 0.84, 0.32))
    ctx.fillEllipse(in: CGRect(x: photo.maxX - s * 0.16, y: photo.maxY - s * 0.15, width: s * 0.09, height: s * 0.09))
    ctx.setFillColor(rgb(0.13, 0.45, 0.38))
    ctx.move(to: CGPoint(x: photo.minX - s * 0.02, y: photo.minY))
    ctx.addLine(to: CGPoint(x: photo.minX + s * 0.17, y: photo.minY + s * 0.24))
    ctx.addLine(to: CGPoint(x: photo.minX + s * 0.34, y: photo.minY))
    ctx.fillPath()
    ctx.setFillColor(rgb(0.19, 0.58, 0.47))
    ctx.move(to: CGPoint(x: photo.minX + s * 0.16, y: photo.minY))
    ctx.addLine(to: CGPoint(x: photo.minX + s * 0.35, y: photo.minY + s * 0.18))
    ctx.addLine(to: CGPoint(x: photo.maxX + s * 0.04, y: photo.minY))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(photoPath)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.95))
    ctx.setLineWidth(max(1, s * 0.018))
    ctx.strokePath()

    // ‹ › on either side: browse the folder.
    if size >= 32 {
        ctx.setStrokeColor(rgb(1, 1, 1, 0.85))
        ctx.setLineWidth(max(1, s * 0.03))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let midY = photo.midY, arm = s * 0.045
        ctx.move(to: CGPoint(x: s * 0.19, y: midY + arm))
        ctx.addLine(to: CGPoint(x: s * 0.19 - arm, y: midY))
        ctx.addLine(to: CGPoint(x: s * 0.19, y: midY - arm))
        ctx.move(to: CGPoint(x: s * 0.81, y: midY + arm))
        ctx.addLine(to: CGPoint(x: s * 0.81 + arm, y: midY))
        ctx.addLine(to: CGPoint(x: s * 0.81, y: midY - arm))
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: drawIcon(size: pixels))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
