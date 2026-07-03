import AppKit

/// Menu bar icons for Wheredo status (template images — adapt to light/dark menu bar).
enum MenuBarIcon {
    /// Standard menu-bar glyph box (matches SF Symbol footprint).
    private static let logicalSize: CGFloat = 18
    private static let inset: CGFloat = 1.5

    static func image(for status: MenuBarController.Status) -> NSImage {
        switch status {
        case .ready:
            return brandedIcon(accent: false)
        case .listening:
            return symbol("mic.fill", fallback: brandedIcon(accent: true))
        case .busy:
            return symbol("ellipsis.circle.fill", fallback: brandedIcon(accent: true))
        case .needAccessibility:
            return symbol("lock.fill", fallback: brandedIcon(accent: true))
        case .error:
            return symbol("exclamationmark.circle.fill", fallback: brandedIcon(accent: true))
        }
    }

    /// Alternate frame for listening pulse animation.
    static func listeningPulseFrame() -> NSImage {
        symbol("mic.circle.fill", fallback: brandedIcon(accent: true))
    }

    private static func symbol(_ name: String, fallback: NSImage) -> NSImage {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Wheredo") {
            img.isTemplate = true
            return img
        }
        return fallback
    }

    /// Minimal pointer + target dot — fills the full 18×18 pt template box.
    private static func brandedIcon(accent: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: logicalSize, height: logicalSize))
        image.lockFocus()

        NSColor.black.setFill()
        NSColor.black.setStroke()

        // Drawable area — same padding Apple uses around SF Symbols.
        let box = NSRect(
            x: inset,
            y: inset,
            width: logicalSize - inset * 2,
            height: logicalSize - inset * 2
        )
        let s = box.width

        // Normalized (0–1) within box; Y=1 is the visual top (AppKit Y grows up).
        func pt(_ nx: CGFloat, _ ny: CGFloat) -> NSPoint {
            NSPoint(x: box.minX + nx * s, y: box.minY + ny * s)
        }

        let tip = pt(0.06, 0.94)
        let inner = pt(0.46, 0.40)
        let tail = pt(0.14, 0.06)
        let notch = pt(0.60, 0.30)

        let pointer = NSBezierPath()
        pointer.move(to: tip)
        pointer.line(to: inner)
        pointer.line(to: tail)
        pointer.close()
        pointer.fill()

        let notchPath = NSBezierPath()
        notchPath.move(to: inner)
        notchPath.line(to: notch)
        notchPath.line(to: tail)
        notchPath.close()
        notchPath.fill()

        let dotR = s * 0.11
        let dotCenter = NSPoint(x: tip.x + s * 0.07, y: tip.y - s * 0.07)
        NSBezierPath(ovalIn: NSRect(
            x: dotCenter.x - dotR,
            y: dotCenter.y - dotR,
            width: dotR * 2,
            height: dotR * 2
        )).fill()

        if accent {
            let ring = NSBezierPath(ovalIn: NSRect(
                x: dotCenter.x - dotR * 1.7,
                y: dotCenter.y - dotR * 1.7,
                width: dotR * 3.4,
                height: dotR * 3.4
            ))
            ring.lineWidth = 1.0
            ring.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
