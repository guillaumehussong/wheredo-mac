import AppKit

/// Wide menu-bar badge (2× standard icon width): pointer mark + status panel.
/// Users should instantly see ready → listening → busy when pressing ⌘$.
enum MenuBarIcon {
    static let height: CGFloat = 18
    static let halfWidth: CGFloat = 18
    static var width: CGFloat { halfWidth * 2 }

    static func image(for status: MenuBarController.Status) -> NSImage {
        switch status {
        case .ready: return wideIcon(.ready)
        case .listening: return wideIcon(.listening)
        case .busy: return wideIcon(.busy)
        case .needAccessibility: return wideIcon(.locked)
        case .error: return wideIcon(.error)
        }
    }

    /// Alternate frame for listening pulse animation.
    static func listeningPulseFrame() -> NSImage {
        wideIcon(.listeningPulse)
    }

    /// Alternate frame for busy pulse animation.
    static func busyPulseFrame() -> NSImage {
        wideIcon(.busyPulse)
    }

    private enum Panel {
        case ready, listening, listeningPulse, busy, busyPulse, error, locked
    }

    private static func wideIcon(_ panel: Panel) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let left = NSRect(x: 0, y: 0, width: halfWidth, height: height)
        let right = NSRect(x: halfWidth, y: 0, width: halfWidth, height: height)

        drawPointer(in: left)
        drawDivider(at: halfWidth)
        drawStatusPanel(panel, in: right)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Left: brand mark

    private static func drawPointer(in rect: NSRect) {
        NSColor.black.setFill()
        let inset: CGFloat = 1.5
        let box = rect.insetBy(dx: inset, dy: inset)
        let s = min(box.width, box.height)

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
            x: dotCenter.x - dotR, y: dotCenter.y - dotR,
            width: dotR * 2, height: dotR * 2
        )).fill()
    }

    private static func drawDivider(at x: CGFloat) {
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: 3))
        line.line(to: NSPoint(x: x, y: height - 3))
        line.lineWidth = 0.5
        line.stroke()
    }

    // MARK: - Right: status panel

    private static func drawStatusPanel(_ panel: Panel, in rect: NSRect) {
        NSColor.black.setFill()
        NSColor.black.setStroke()

        switch panel {
        case .ready:
            // Idle ring — calm, waiting for ⌘$
            drawRing(in: rect, radius: 4.5, filled: false)

        case .listening:
            drawMic(in: rect, scale: 1.0, waves: false)

        case .listeningPulse:
            // Brighter pulse frame: larger mic + sound waves
            drawMic(in: rect, scale: 1.15, waves: true)

        case .busy:
            drawThinkingDots(in: rect, highlight: 1)

        case .busyPulse:
            drawThinkingDots(in: rect, highlight: 2)

        case .error:
            drawExclamation(in: rect)

        case .locked:
            drawLock(in: rect)
        }
    }

    private static func drawRing(in rect: NSRect, radius: CGFloat, filled: Bool) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let r = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        if filled {
            r.fill()
        } else {
            r.lineWidth = 1.4
            r.stroke()
        }
    }

    private static func drawMic(in rect: NSRect, scale: CGFloat, waves: Bool) {
        let cx = rect.midX
        let cy = rect.midY
        let s = scale

        // Mic capsule
        let capW: CGFloat = 5 * s
        let capH: CGFloat = 8 * s
        let cap = NSBezierPath(roundedRect: NSRect(
            x: cx - capW / 2, y: cy + 0.5,
            width: capW, height: capH
        ), xRadius: capW / 2, yRadius: capW / 2)
        cap.fill()

        // Mic stem + base
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: cx, y: cy + 0.5))
        stem.line(to: NSPoint(x: cx, y: cy - 4 * s))
        stem.lineWidth = 1.4
        stem.stroke()

        let base = NSBezierPath()
        base.move(to: NSPoint(x: cx - 4 * s, y: cy - 4 * s))
        base.line(to: NSPoint(x: cx + 4 * s, y: cy - 4 * s))
        base.lineWidth = 1.4
        base.stroke()

        if waves {
            for (i, offset) in [(6.5, 0.0), (8.5, 0.4)] {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: NSPoint(x: cx, y: cy + capH * 0.4),
                    radius: i * s * 0.55,
                    startAngle: 120 + offset,
                    endAngle: 60 - offset,
                    clockwise: true
                )
                arc.lineWidth = 1.2
                arc.stroke()
            }
        }
    }

    private static func drawThinkingDots(in rect: NSRect, highlight: Int) {
        let cx = rect.midX
        let cy = rect.midY
        let spacing: CGFloat = 5.5
        let r: CGFloat = 2.2

        for (i, dx) in [(-1), (0), (1)].enumerated() {
            let x = cx + CGFloat(dx) * spacing
            let active = (i + 1) == highlight
            let radius = active ? r * 1.35 : r
            NSBezierPath(ovalIn: NSRect(
                x: x - radius, y: cy - radius,
                width: radius * 2, height: radius * 2
            )).fill()
        }
    }

    private static func drawExclamation(in rect: NSRect) {
        let cx = rect.midX
        let cy = rect.midY
        NSBezierPath(rect: NSRect(x: cx - 1.2, y: cy + 0.5, width: 2.4, height: 6.5)).fill()
        NSBezierPath(ovalIn: NSRect(x: cx - 1.6, y: cy - 4.5, width: 3.2, height: 3.2)).fill()
    }

    private static func drawLock(in rect: NSRect) {
        let cx = rect.midX
        let cy = rect.midY
        // Shackle
        let shackle = NSBezierPath()
        shackle.appendArc(
            withCenter: NSPoint(x: cx, y: cy + 3),
            radius: 3.5,
            startAngle: 0,
            endAngle: 180,
            clockwise: true
        )
        shackle.lineWidth = 1.4
        shackle.stroke()
        // Body
        NSBezierPath(rect: NSRect(x: cx - 4, y: cy - 4, width: 8, height: 6)).fill()
    }
}
