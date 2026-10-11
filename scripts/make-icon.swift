// Renders the app icon at every macOS size and packs it into assets/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let barHeights: [CGFloat] = [0.22, 0.42, 0.68, 0.42, 0.22]

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Apple's icon grid: 824/1024 body with a continuous-corner radius of ~185/1024.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.2245
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: deep indigo at the bottom to violet at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.10, green: 0.07, blue: 0.30, alpha: 1).cgColor,
        NSColor(srgbRed: 0.31, green: 0.27, blue: 0.90, alpha: 1).cgColor,
        NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY),
                           end: CGPoint(x: body.maxX, y: body.maxY), options: [])

    // Soft glow behind the waveform.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor.white.withAlphaComponent(0.28).cgColor,
                                   NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.midY), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: body.width * 0.45, options: [])

    // Top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [NSColor.white.withAlphaComponent(0.16).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY), options: [])
    ctx.restoreGState()

    // Waveform bars.
    let barWidth = body.width * 0.085
    let gap = body.width * 0.06
    let total = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
    var x = body.midX - total / 2
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.02,
                  color: NSColor(srgbRed: 0.08, green: 0.04, blue: 0.25, alpha: 0.45).cgColor)
    for h in barHeights {
        let height = body.height * h
        let bar = CGRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        x += barWidth + gap
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: assets.appendingPathComponent("icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote assets/AppIcon.icns and assets/icon.png" : "iconutil failed")
