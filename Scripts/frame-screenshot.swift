// Composes README images from raw panel snapshots (see Scripts/screenshots.sh).
// Usage:
//   swift Scripts/frame-screenshot.swift banner <raw.png> <out.png> <title> <tagline> <hotkey>
//   swift Scripts/frame-screenshot.swift pair <light.png> <dark.png> <out.png>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let args = Array(CommandLine.arguments.dropFirst())

func canvas(_ w: Int, _ h: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a).cgColor
}

func background(_ ctx: CGContext, _ rect: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(18, 16, 52), rgb(64, 40, 170), rgb(190, 92, 240)] as CFArray,
                       locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    // soft light blobs
    for (x, y, r, a) in [(0.78, 0.75, 0.45, 0.22), (0.15, 0.15, 0.35, 0.12)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        let c = CGPoint(x: rect.width * x, y: rect.height * y)
        let blob = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgb(255, 255, 255, a), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(blob, startCenter: c, startRadius: 0, endCenter: c, endRadius: rect.width * r, options: [])
    }
}

/// Draws the panel snapshot as a floating window: backdrop, content, close button, border, shadow.
func window(_ ctx: CGContext, raw: NSImage, origin: CGPoint, dark: Bool) {
    let size = raw.size  // raw image is @2x pixels; draw at pixel size
    let rect = CGRect(origin: origin, size: size)
    let path = CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -40), blur: 90, color: rgb(10, 5, 40, 0.55))
    ctx.addPath(path)
    ctx.setFillColor(dark ? rgb(32, 31, 38) : rgb(246, 245, 250))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let ns = NSGraphicsContext.current!
    ns.imageInterpolation = .high
    raw.draw(in: rect)
    // close button, where the real one sits
    let close = CGRect(x: rect.minX + 28, y: rect.maxY - 58, width: 26, height: 26)
    ctx.setFillColor(rgb(255, 95, 87))
    ctx.fillEllipse(in: close)
    ctx.setStrokeColor(rgb(0, 0, 0, 0.12))
    ctx.setLineWidth(1.5)
    ctx.strokeEllipse(in: close)
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(dark ? rgb(255, 255, 255, 0.14) : rgb(0, 0, 0, 0.10))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: CGPoint, kern: CGFloat = 0) -> CGSize {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    str.draw(at: p)
    return str.size()
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

switch args.first {
case "banner":
    let raw = NSImage(contentsOfFile: args[1])!
    let raw2x = NSImage(size: NSSize(width: raw.representations[0].pixelsWide, height: raw.representations[0].pixelsHigh))
    raw2x.addRepresentation(raw.representations[0])
    let icon = NSImage(contentsOf: root.appendingPathComponent("docs/icon.png"))!
    let (w, h) = (2400, 1500)
    let rep = canvas(w, h) { ctx in
        background(ctx, CGRect(x: 0, y: 0, width: w, height: h))
        // left column
        icon.draw(in: CGRect(x: 150, y: 860, width: 300, height: 300))
        _ = text(args[3], size: 150, weight: .bold, color: .white, at: CGPoint(x: 175, y: 640), kern: -2)
        let tagline = args[4].components(separatedBy: "\\n")
        for (i, line) in tagline.enumerated() {
            _ = text(line, size: 56, weight: .medium, color: NSColor.white.withAlphaComponent(0.82),
                     at: CGPoint(x: 180, y: 540 - CGFloat(i) * 76))
        }
        // keycap pill
        let pillY: CGFloat = 540 - CGFloat(tagline.count) * 76 - 70
        let label = NSAttributedString(string: args[5], attributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let pill = CGRect(x: 180, y: pillY, width: label.size().width + 64, height: 84)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(rgb(255, 255, 255, 0.16))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.35))
        ctx.setLineWidth(2)
        ctx.strokePath()
        label.draw(at: CGPoint(x: pill.minX + 32, y: pill.minY + 16))
        // window on the right
        window(ctx, raw: raw2x, origin: CGPoint(x: CGFloat(w) - raw2x.size.width - 170, y: (CGFloat(h) - raw2x.size.height) / 2), dark: false)
    }
    write(rep, args[2])

case "pair":
    func load(_ p: String) -> NSImage {
        let r = NSImage(contentsOfFile: p)!.representations[0]
        let img = NSImage(size: NSSize(width: r.pixelsWide, height: r.pixelsHigh))
        img.addRepresentation(r)
        return img
    }
    let light = load(args[1]), dark = load(args[2])
    let gap: CGFloat = 120, pad: CGFloat = 160
    let w = Int(light.size.width * 2 + gap + pad * 2), h = Int(light.size.height + pad * 2)
    let rep = canvas(w, h) { ctx in
        background(ctx, CGRect(x: 0, y: 0, width: w, height: h))
        window(ctx, raw: light, origin: CGPoint(x: pad, y: pad), dark: false)
        window(ctx, raw: dark, origin: CGPoint(x: pad + light.size.width + gap, y: pad), dark: true)
    }
    write(rep, args[3])

default:
    print("usage: banner <raw> <out> <title> <tagline> <hotkey> | pair <light> <dark> <out>")
}
