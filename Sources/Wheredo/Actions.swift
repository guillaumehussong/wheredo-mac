import Foundation
import AppKit
import CoreGraphics

/// Screen pointing, guide cursor overlay, and optional confirmed clicks.
enum Actions {
    /// Show red guide cursor(s) without moving the system pointer.
    ///
    /// Coordinate chain, from model output to pixels on screen:
    ///   normalized (0–1000 on the screenshot)
    ///     → CaptureContext.pointInScreenSpace: SCK pixels (accounts for which
    ///       window/display was captured and any scaling)
    ///     → ScreenCoordinates.sckToCocoa: Cocoa point for the overlay panel.
    static func showGuide(for actions: [UIAction], context: CaptureContext?) async {
        guard Config.showGuideCursor else { return }
        let ctx = context ?? CaptureState.lastContext
        guard let ctx else { return }

        var markers: [(CGPoint, String)] = []
        for action in actions {
            guard let p = action.point else { continue }
            let sck = ctx.pointInScreenSpace(p)
            let cocoa = ScreenCoordinates.sckToCocoa(sck)
            markers.append((cocoa, action.label ?? ""))
        }
        guard !markers.isEmpty else {
            if !actions.isEmpty {
                print("⚠️  Vision returned \(actions.count) action(s) but no valid point coordinates.")
            }
            return
        }

        let guideMarkers = markers
        await MainActor.run {
            GuideCursor.shared.show(markers: guideMarkers)
        }
        for (point, label) in guideMarkers {
            print("🔴 Guide cursor: \(label.isEmpty ? "target" : label) at cocoa (\(Int(point.x)), \(Int(point.y)))")
        }
    }

    static func dismissGuide() async {
        await MainActor.run { GuideCursor.shared.dismiss() }
    }

    /// Map normalized point to Cocoa screen pixels (for CGEvent clicks).
    static func toPixels(_ p: UIAction.Point, context: CaptureContext?) -> CGPoint {
        if let ctx = context ?? CaptureState.lastContext {
            let sck = ctx.pointInScreenSpace(p)
            return sckToCocoa(sck)
        }
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let x = frame.minX + (p.x / 1000.0) * frame.width
        let y = frame.maxY - (p.y / 1000.0) * frame.height
        return CGPoint(x: x, y: y)
    }

    static func confirmAndClick(at point: CGPoint, label: String?) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Grok wants to click"
            alert.informativeText = "Action: \(label ?? "click") at (\(Int(point.x)), \(Int(point.y)))\n\nAllow click?"
            alert.addButton(withTitle: "Click")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    /// Perform a real mouse click via CGEvent. Only ever called after the user
    /// approved it in confirmAndClick — Wheredo never clicks silently.
    static func click(at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        print("✓ Click at (\(Int(point.x)), \(Int(point.y)))")
    }

    private static func sckToCocoa(_ sck: CGPoint) -> CGPoint {
        ScreenCoordinates.sckToCocoa(sck)
    }
}
