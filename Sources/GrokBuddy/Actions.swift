import Foundation
import AppKit
import CoreGraphics

/// Converts normalized (0–1000) coords to screen pixels, moves the cursor with an
/// animated overlay, and performs a CGEvent click ONLY after explicit confirmation.
enum Actions {
    static func mainScreenFrame() -> CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Normalized (0–1000, top-left origin) → screen pixels (bottom-left origin, CG coords).
    static func toPixels(_ p: UIAction.Point) -> CGPoint {
        let frame = mainScreenFrame()
        let x = frame.minX + (p.x / 1000.0) * frame.width
        let y = frame.minY + frame.height - (p.y / 1000.0) * frame.height
        return CGPoint(x: x, y: y)
    }

    /// Animated move + a brief highlight circle, no click.
    static func pointAt(_ p: UIAction.Point, label: String?) async {
        let target = toPixels(p)
        let start = CGEvent(source: nil)?.location ?? target

        let steps = 18
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            let x = start.x + (target.x - start.x) * eased
            let y = start.y + (target.y - start.y) * eased
            moveCursor(CGPoint(x: x, y: y))
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
        moveCursor(target)
        print("👉 Pointage: \(label ?? "zone") à (\(Int(target.x)), \(Int(target.y)))")
        flashOverlay(at: target)
    }

    /// Confirm via a blocking NSAlert, then click if approved.
    static func confirmAndClick(at point: CGPoint, label: String?) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Grok veut cliquer"
            alert.informativeText = "Action: \(label ?? "clic") à (\(Int(point.x)), \(Int(point.y)))\n\nAutoriser le clic ?"
            alert.addButton(withTitle: "Cliquer")
            alert.addButton(withTitle: "Annuler")
            alert.alertStyle = .warning
            let resp = alert.runModal()
            return resp == .alertFirstButtonReturn
        }
    }

    static func click(at point: CGPoint) {
        moveCursor(point)
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        print("✓ Clic effectué à (\(Int(point.x)), \(Int(point.y)))")
    }

    private static func moveCursor(_ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Brief screen-localized highlight (transient overlay window). Best-effort; non-fatal.
    private static func flashOverlay(at point: CGPoint) {
        DispatchQueue.main.async {
            let size: CGFloat = 44
            let panel = NSPanel(
                contentRect: NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            view.layer = CALayer()
            view.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.45).cgColor
            view.layer?.cornerRadius = size / 2
            panel.contentView = view
            panel.orderFrontRegardless()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                panel.orderOut(nil)
            }
        }
    }
}
