// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824pt tile centered in 1024 with a soft drop shadow
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.11, green: 0.10, blue: 0.32, alpha: 1).cgColor,
        NSColor(srgbRed: 0.33, green: 0.20, blue: 0.85, alpha: 1).cgColor,
        NSColor(srgbRed: 0.78, green: 0.36, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])

    // soft glow behind the bubble
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 560 * s, y: 600 * s), startRadius: 0,
                           endCenter: CGPoint(x: 560 * s, y: 600 * s), endRadius: 420 * s, options: [])

    // top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    ctx.restoreGState()

    // back bubble (translucent) and front bubble (white), floating with a shadow
    func bubble(_ rect: CGRect, tailLeft: Bool) -> CGPath {
        let body = CGPath(roundedRect: rect, cornerWidth: rect.height * 0.42, cornerHeight: rect.height * 0.42, transform: nil)
        let p = CGMutablePath()
        // tail starts inside the bubble body so it merges cleanly, then sweeps down to a rounded tip
        let tx = tailLeft ? rect.minX + rect.width * 0.32 : rect.maxX - rect.width * 0.32
        let dir: CGFloat = tailLeft ? -1 : 1
        let tip = CGPoint(x: tx + dir * 70 * s, y: rect.minY - 58 * s)
        p.move(to: CGPoint(x: tx - 50 * s, y: rect.minY + 50 * s))
        p.addLine(to: CGPoint(x: tx + 50 * s, y: rect.minY + 50 * s))
        p.addQuadCurve(to: tip, control: CGPoint(x: tx + 40 * s, y: rect.minY - 20 * s))
        p.addQuadCurve(to: CGPoint(x: tx - 50 * s, y: rect.minY + 50 * s), control: CGPoint(x: tx - 30 * s, y: rect.minY - 10 * s))
        p.closeSubpath()
        return body.union(p)
    }

    let back = bubble(CGRect(x: 380 * s, y: 520 * s, width: 400 * s, height: 250 * s), tailLeft: false)
    ctx.addPath(back)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.38).cgColor)
    ctx.fillPath()

    let frontRect = CGRect(x: 230 * s, y: 330 * s, width: 450 * s, height: 280 * s)
    let front = bubble(frontRect, tailLeft: true)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 40 * s, color: NSColor(srgbRed: 0.08, green: 0.03, blue: 0.25, alpha: 0.55).cgColor)
    ctx.addPath(front)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // three "typing" dots in the front bubble
    let dotColor = NSColor(srgbRed: 0.36, green: 0.24, blue: 0.86, alpha: 1).cgColor
    for i in 0..<3 {
        let r: CGFloat = 30 * s
        let cx = frontRect.midX + CGFloat(i - 1) * 100 * s
        ctx.setFillColor(dotColor)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: frontRect.midY - r, width: r * 2, height: r * 2))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/icon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print("Wrote Resources/AppIcon.icns and docs/icon.png")
