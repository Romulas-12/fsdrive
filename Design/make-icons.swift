// Icons for every platform from one master image (Design/AppIcon.png).
//
//   swift Design/make-icons.swift master SOURCE OUT.png   cut the rounded tile out of an
//                                                          image with a solid background
//   swift Design/make-icons.swift iconset MASTER OUTDIR   macOS .iconset for iconutil
//   swift Design/make-icons.swift qnap MASTER OUTDIR      QNAP App Center icons
import AppKit

func load(_ path: String) -> NSBitmapImageRep {
    guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
        fatalError("cannot read \(path)")
    }
    return rep
}

func save(_ size: Int, to path: String, draw: (CGRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// Bounds of the coloured tile: scans in from each edge along the middle lines until
/// the background colour ends.
func tileBounds(_ rep: NSBitmapImageRep) -> CGRect {
    let bg = rep.colorAt(x: 2, y: 2)!
    func isBackground(_ x: Int, _ y: Int) -> Bool {
        let c = rep.colorAt(x: x, y: y)!
        return abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) < 0.15
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var l = 0, r = w - 1, t = 0, b = h - 1
    while l < w / 2 && isBackground(l, h / 2) { l += 1 }
    while r > w / 2 && isBackground(r, h / 2) { r -= 1 }
    while t < h / 2 && isBackground(w / 2, t) { t += 1 }
    while b > h / 2 && isBackground(w / 2, b) { b -= 1 }
    return CGRect(x: l, y: t, width: r - l + 1, height: b - t + 1)  // top-left origin
}

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("usage: make-icons.swift master|iconset|qnap INPUT OUTPUT") }
let (mode, input, output) = (args[1], args[2], args[3])

switch mode {
case "master":
    // 1024×1024, tile edge to edge, transparent corners. A few pixels are trimmed so
    // the anti-aliased rim of the old background does not show as a dark outline.
    let rep = load(input)
    let tile = tileBounds(rep).insetBy(dx: 4, dy: 4)
    let source = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    source.addRepresentation(rep)
    save(1024, to: output) { canvas in
        let radius = canvas.width * 0.2237  // macOS icon corner radius
        NSBezierPath(roundedRect: canvas, xRadius: radius, yRadius: radius).addClip()
        // NSImage draws with a bottom-left origin; convert the top-left tile rect.
        let from = NSRect(x: tile.minX, y: CGFloat(rep.pixelsHigh) - tile.maxY, width: tile.width, height: tile.height)
        source.draw(in: canvas, from: from, operation: .copy, fraction: 1)
    }

case "iconset":
    // macOS grid: the tile is 824/1024 of the canvas, with a soft shadow below it.
    let master = NSImage(contentsOfFile: input)!
    try! FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let size = base * scale
            save(size, to: "\(output)/icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png") { canvas in
                let s = canvas.width
                let tile = NSRect(x: s * 100 / 1024, y: s * 110 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                shadow.shadowBlurRadius = s * 12 / 1024
                shadow.shadowOffset = NSSize(width: 0, height: -s * 8 / 1024)
                shadow.set()
                master.draw(in: tile)
            }
        }
    }

case "qnap":
    // App Center: 64 and 80 px colour icons, plus a grey one for the disabled state.
    let master = NSImage(contentsOfFile: input)!
    try! FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    for (name, size) in [("FSDrive.png", 64), ("FSDrive_80.png", 80)] {
        save(size, to: "\(output)/\(name)") { canvas in master.draw(in: canvas.insetBy(dx: 2, dy: 2)) }
    }
    save(64, to: "\(output)/FSDrive_gray.png") { canvas in
        master.draw(in: canvas.insetBy(dx: 2, dy: 2))
        NSColor(white: 0.5, alpha: 1).set()
        canvas.fill(using: .color)  // keep luminance, drop colour
    }

default:
    fatalError("unknown mode \(mode)")
}
