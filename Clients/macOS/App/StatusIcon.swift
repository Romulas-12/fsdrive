import AppKit

/// Menu bar icons: the hexagon of the Finder sidebar with a mark for each state. SF Symbols has a
/// plain hexagon but no variants with these marks, so they are drawn here as template
/// images (macOS tints them for light and dark menu bars).
enum StatusIcon: CaseIterable {
    case synced
    case syncing
    case error
    case offline
    case signedOut

    var image: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityLabel
        return image
    }

    var accessibilityLabel: String {
        switch self {
        case .synced: return "FSDrive: синхронізовано"
        case .syncing: return "FSDrive: синхронізація"
        case .error: return "FSDrive: помилка"
        case .offline: return "FSDrive: сервер недоступний"
        case .signedOut: return "FSDrive: не підключено"
        }
    }

    private func draw(in rect: NSRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let shape = Self.hexagon(center: center, radius: 7.8)
        shape.lineWidth = 1.5
        NSColor.black.set()
        switch self {
        case .synced:
            shape.stroke()
        case .syncing:
            shape.stroke()
            glyph("arrow.triangle.2.circlepath", size: 7.5, weight: .bold, at: center)
        case .error:
            shape.stroke()
            glyph("exclamationmark", size: 8.5, weight: .heavy, at: center)
        case .offline:
            shape.stroke()
            // A slash with a gap around it, like icloud.slash.
            let slash = NSBezierPath()
            slash.move(to: CGPoint(x: rect.minX + 2.5, y: rect.maxY - 2))
            slash.line(to: CGPoint(x: rect.maxX - 2.5, y: rect.minY + 2))
            slash.lineCapStyle = .round
            slash.lineWidth = 3.5
            NSGraphicsContext.current?.compositingOperation = .clear
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            slash.lineWidth = 1.5
            slash.stroke()
        case .signedOut:
            // Same hexagon, faded: the menu bar keeps the template's alpha.
            NSColor.black.withAlphaComponent(0.45).set()
            shape.stroke()
        }
    }

    private func glyph(_ name: String, size: CGFloat, weight: NSFont.Weight, at center: CGPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = symbol.size
        symbol.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    }

    /// Pointy-top hexagon, the shape of the SF Symbol in the Finder sidebar.
    static func hexagon(center: CGPoint, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for i in 0..<6 {
            let angle = CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 3
            let p = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}
