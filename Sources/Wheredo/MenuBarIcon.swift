import AppKit

/// Menu bar icons for Wheredo status (template images — adapt to light/dark menu bar).
enum MenuBarIcon {
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

    /// Minimal pointer + target dot — same mark as the desktop app icon.
    private static func brandedIcon(accent: Bool) -> NSImage {
        let scale: CGFloat = 2
        let size = NSSize(width: 18 * scale, height: 18 * scale)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setFill()
        NSColor.black.setStroke()

        let s = size.width
        let tip = NSPoint(x: s * 0.28, y: s * 0.74) // flipped Y (AppKit origin bottom-left)
        let inner = NSPoint(x: s * 0.39, y: s * 0.48)
        let tail = NSPoint(x: s * 0.32, y: s * 0.40)
        let notch = NSPoint(x: s * 0.48, y: s * 0.52)

        // Pointer body
        let pointer = NSBezierPath()
        pointer.move(to: tip)
        pointer.line(to: inner)
        pointer.line(to: tail)
        pointer.close()
        pointer.fill()

        // Inner notch (classic cursor shape)
        let notchPath = NSBezierPath()
        notchPath.move(to: inner)
        notchPath.line(to: notch)
        notchPath.line(to: tail)
        notchPath.close()
        notchPath.fill()

        // Target dot at the tip
        let dotR = s * 0.075
        let dotCenter = NSPoint(x: tip.x + s * 0.055, y: tip.y - s * 0.055)
        NSBezierPath(ovalIn: NSRect(
            x: dotCenter.x - dotR,
            y: dotCenter.y - dotR,
            width: dotR * 2,
            height: dotR * 2
        )).fill()

        // Accent: second ring around dot when active
        if accent {
            let ring = NSBezierPath(ovalIn: NSRect(
                x: dotCenter.x - dotR * 1.8,
                y: dotCenter.y - dotR * 1.8,
                width: dotR * 3.6,
                height: dotR * 3.6
            ))
            ring.lineWidth = 0.8 * scale
            ring.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
