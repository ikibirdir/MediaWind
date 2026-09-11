// Generates test images for PhotoViewer. Run through scripts/make-testdata.sh.
//
//   swift scripts/MakeTestData.swift <output-folder> [count]     the regular test folder
//   swift scripts/MakeTestData.swift --large <output-folder> [n]  n files (APFS clones) for speed tests
//
// Only ever writes inside <output-folder>.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(hue: CGFloat, saturation s: CGFloat, brightness v: CGFloat, alpha: CGFloat = 1) -> CGColor {
    let h = (hue - floor(hue)) * 6
    let i = Int(h) % 6
    let f = h - floor(h)
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    let (r, g, b): (CGFloat, CGFloat, CGFloat) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return CGColor(colorSpace: sRGB, components: [r, g, b, alpha])!
}

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func drawText(_ ctx: CGContext, _ text: String, size: CGFloat, center: CGPoint,
              color: CGColor = CGColor(gray: 1, alpha: 1)) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: center.x - bounds.width / 2 - bounds.minX,
                               y: center.y - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, ctx)
}

/// Draws an upright test picture into (0, 0, width, height) of the current CTM.
func drawPicture(_ ctx: CGContext, width: Int, height: Int, number: String, caption: String, hue: CGFloat) {
    let w = CGFloat(width), h = CGFloat(height), m = min(w, h)
    let gradient = CGGradient(colorsSpace: sRGB,
                              colors: [rgb(hue: hue, saturation: 0.55, brightness: 0.95),
                                       rgb(hue: hue + 0.12, saturation: 0.85, brightness: 0.35)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])

    // A fine grid so zooming in shows real detail.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(max(1, m / 1000))
    let step = max(8, m / 40)
    var x: CGFloat = 0
    while x < w { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)); x += step }
    var y: CGFloat = 0
    while y < h { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); y += step }
    ctx.strokePath()

    ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
    ctx.fillEllipse(in: CGRect(x: w / 2 - m * 0.3, y: h / 2 - m * 0.3, width: m * 0.6, height: m * 0.6))

    drawText(ctx, number, size: m * 0.28, center: CGPoint(x: w / 2, y: h / 2))
    drawText(ctx, caption, size: m * 0.045, center: CGPoint(x: w / 2, y: h * 0.18))
    drawText(ctx, "▲ TOP", size: m * 0.05, center: CGPoint(x: w / 2, y: h - m * 0.06))
    drawText(ctx, "L", size: m * 0.06, center: CGPoint(x: m * 0.06, y: h / 2))
    drawText(ctx, "R", size: m * 0.06, center: CGPoint(x: w - m * 0.06, y: h / 2))
}

func write(_ images: [CGImage], to url: URL, type: UTType, properties: [CFString: Any] = [:],
           fileProperties: [CFString: Any] = [:], embedThumbnail: Bool = false) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil) else {
        fatalError("Can't create \(type.identifier) destination for \(url.lastPathComponent)")
    }
    if !fileProperties.isEmpty { CGImageDestinationSetProperties(dest, fileProperties as CFDictionary) }
    var props = properties
    props[kCGImageDestinationLossyCompressionQuality] = 0.85
    if embedThumbnail { props[kCGImageDestinationEmbedThumbnail] = true }
    for image in images { CGImageDestinationAddImage(dest, image, props as CFDictionary) }
    guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write \(url.lastPathComponent)") }
}

func setModificationDate(_ url: URL, index: Int) {
    // Deterministic but shuffled, so "Date Modified" order differs from name order.
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let date = base.addingTimeInterval(TimeInterval((index * 7919) % 997) * 3600)
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

struct Variant { let ext: String; let type: UTType; let width: Int; let height: Int }

let variants: [Variant] = [
    Variant(ext: "png", type: .png, width: 1200, height: 800),
    Variant(ext: "heic", type: .heic, width: 4032, height: 3024),
    Variant(ext: "tiff", type: .tiff, width: 800, height: 600),
    Variant(ext: "jpg", type: .jpeg, width: 3000, height: 4000),
    Variant(ext: "jpg", type: .jpeg, width: 320, height: 240),
    Variant(ext: "jpg", type: .jpeg, width: 6000, height: 4000),
    Variant(ext: "bmp", type: .bmp, width: 640, height: 480),
    Variant(ext: "jpg", type: .jpeg, width: 1920, height: 1080),
    Variant(ext: "jpg", type: .jpeg, width: 2400, height: 1600),
    Variant(ext: "jpeg", type: .jpeg, width: 4000, height: 3000),
]

/// Slots filled by special files instead of a numbered picture.
/// 5, 6, 100, 101, 102 are videos made by make-testdata.sh with ffmpeg.
let reservedSlots: Set<Int> = [5, 6, 7, 8, 9, 11, 100, 101, 102]

func makeStandardFolder(_ out: URL, count: Int) {
    for index in 1...count where !reservedSlots.contains(index) {
        let v = variants[index % variants.count]
        let name = "IMG_\(index).\(v.ext)"
        let ctx = makeContext(v.width, v.height)
        drawPicture(ctx, width: v.width, height: v.height, number: "\(index)",
                    caption: "\(name)  \(v.width)×\(v.height)", hue: CGFloat(index % 36) / 36)
        let url = out.appendingPathComponent(name)
        write([ctx.makeImage()!], to: url, type: v.type,
              embedThumbnail: v.type == .jpeg || v.type == .heic)
        setModificationDate(url, index: index)
        if index % 25 == 0 { print("  \(index)/\(count)") }
    }

    // Animated GIF.
    var frames: [CGImage] = []
    for f in 0..<24 {
        let ctx = makeContext(480, 360)
        drawPicture(ctx, width: 480, height: 360, number: "7", caption: "IMG_7_animated.gif  frame \(f + 1)/24",
                    hue: CGFloat(f) / 24)
        let angle = CGFloat(f) / 24 * 2 * .pi
        ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 240 + cos(angle) * 130 - 18, y: 180 + sin(angle) * 130 - 18, width: 36, height: 36))
        frames.append(ctx.makeImage()!)
    }
    write(frames, to: out.appendingPathComponent("IMG_7_animated.gif"), type: .gif,
          properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]],
          fileProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]])

    // EXIF orientation 6 ("rotate 90° clockwise to display"): the pixels are stored rotated
    // 90° counter-clockwise, so the picture is only upright if the viewer honors the tag.
    for (name, type) in [("IMG_8_exif-rotated.jpg", UTType.jpeg), ("IMG_9_exif-rotated.heic", UTType.heic)] {
        let uprightWidth = 1800, uprightHeight = 2400
        let ctx = makeContext(uprightHeight, uprightWidth)
        ctx.translateBy(x: CGFloat(uprightHeight), y: 0)
        ctx.rotate(by: .pi / 2)
        drawPicture(ctx, width: uprightWidth, height: uprightHeight, number: "✓",
                    caption: "\(name): upright = EXIF orientation honored", hue: 0.33)
        write([ctx.makeImage()!], to: out.appendingPathComponent(name), type: type,
              properties: [kCGImagePropertyOrientation: 6], embedThumbnail: true)
    }

    // A file with an image extension that isn't an image.
    var garbage = Data(count: 4096)
    for i in 0..<garbage.count { garbage[i] = UInt8((i * 31 + 7) % 251) }
    try! garbage.write(to: out.appendingPathComponent("IMG_11_broken.jpg"))
}

func makeLargeFolder(_ out: URL, count: Int) {
    let sources = 50
    var sourceURLs: [URL] = []
    let tmp = out.appendingPathComponent(".sources", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    for s in 0..<sources {
        let ctx = makeContext(1600, 1200)
        drawPicture(ctx, width: 1600, height: 1200, number: "#\(s + 1)", caption: "one of \(sources) source images",
                    hue: CGFloat(s) / CGFloat(sources))
        let url = tmp.appendingPathComponent("source_\(s).jpg")
        write([ctx.makeImage()!], to: url, type: .jpeg, embedThumbnail: true)
        sourceURLs.append(url)
    }
    for i in 1...count {
        let dest = out.appendingPathComponent("IMG_\(i).jpg")
        try? FileManager.default.removeItem(at: dest)
        // copyItem clones on APFS, so this takes almost no disk space.
        try! FileManager.default.copyItem(at: sourceURLs[(i - 1) % sources], to: dest)
        setModificationDate(dest, index: i)
    }
    try? FileManager.default.removeItem(at: tmp)
}

var args = Array(CommandLine.arguments.dropFirst())
let large = args.first == "--large"
if large { args.removeFirst() }
guard let outPath = args.first else {
    print("usage: MakeTestData.swift [--large] <output-folder> [count]")
    exit(1)
}
let out = URL(fileURLWithPath: outPath, isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let count = args.count > 1 ? Int(args[1]) ?? 0 : 0

if large {
    makeLargeFolder(out, count: count > 0 ? count : 5000)
} else {
    makeStandardFolder(out, count: count > 0 ? count : 300)
}
print("Done: \(out.path)")
