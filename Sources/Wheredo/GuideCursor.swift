import AppKit

/// Highest possible window level so markers stay visible above full-screen apps,
/// menus and other floating windows.
private let guideOverlayLevel = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.maximumWindow))
)

/// Clicky-style red guide cursor overlay (does not move the system pointer).
///
/// Design: ONE small borderless NSPanel per marker instead of a single
/// full-screen transparent window. Small panels are cheap, reliably composited
/// on macOS 26, work across multiple displays, and never intercept mouse events.
/// All coordinates here are COCOA space (origin bottom-left of main screen) —
/// conversion from ScreenCaptureKit space happens in Actions/ScreenCoordinates.
@MainActor
final class GuideCursor {
    static let shared = GuideCursor()

    private var panels: [MarkerPanel] = []
    private var pulseTimer: Timer?
    /// Monotonic counter: each show() gets a generation so the auto-dismiss timer
    /// of an OLD overlay can't tear down a NEWER one shown in the meantime.
    private var showGeneration = 0

    func show(at cocoaPoint: CGPoint, label: String?) {
        show(markers: [(cocoaPoint, label ?? "")])
    }

    func show(markers: [(CGPoint, String)]) {
        dismiss()
        guard Config.showGuideCursor, !markers.isEmpty else {
            print("⚠️  Guide overlay skipped (disabled or no markers).")
            return
        }

        // Accessory (menu-bar) apps can't always order windows above the active
        // app; temporarily promote to a regular app while the overlay is visible.
        AppVisibility.enableOverlayWindows()

        showGeneration += 1
        let generation = showGeneration

        for (point, label) in markers {
            let panel = MarkerPanel(cocoaPoint: point, label: label)
            panels.append(panel)
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            print("   ↳ panel frame \(panel.frame) visible=\(panel.isVisible)")
        }

        print("🔴 Guide overlay: \(panels.count) marker(s)")

        // 20 fps pulse animation. The timer is added to the .common run-loop mode
        // so it keeps firing while menus/drags block the default mode.
        pulseTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.panels.forEach { $0.pulse() }
            }
        }
        RunLoop.main.add(pulseTimer!, forMode: .common)

        // Flush AppKit window server updates before TTS / async work continues.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let duration = Config.guideCursorDuration
        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.showGeneration == generation else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        AppVisibility.restoreBackgroundMode()
    }

    /// Debug helper: show a marker at the current mouse position for 10 s.
    static func testAtMouse() {
        let loc = NSEvent.mouseLocation
        print("🧪 Test guide at mouse cocoa (\(Int(loc.x)), \(Int(loc.y)))")
        shared.show(at: loc, label: "TEST")
    }
}

// MARK: - Floating panel per marker

private final class MarkerPanel: NSPanel {
    private let markerView: MarkerView

    init(cocoaPoint: CGPoint, label: String) {
        // The panel is larger than the marker so the pulsing ring and the label
        // bubble have room to draw. `tip` is where the cursor point sits INSIDE
        // the view; the panel is positioned so that tip lands on `cocoaPoint`.
        let viewSize = NSSize(width: 240, height: 100)
        let tip = NSPoint(x: 16, y: 16)
        markerView = MarkerView(tip: tip, label: label, size: viewSize)

        // MarkerView is flipped (origin top-left), so convert: the view's tip
        // y-offset from the panel TOP is `tip.y`, hence from the bottom it is
        // (height - tip.y).
        let origin = NSPoint(
            x: cocoaPoint.x - tip.x,
            y: cocoaPoint.y - (viewSize.height - tip.y)
        )
        super.init(
            contentRect: NSRect(origin: origin, size: viewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        alphaValue = 1
        level = guideOverlayLevel
        // Click-through: the user must be able to click the control UNDER the marker.
        ignoresMouseEvents = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        // Visible on every Space and over full-screen apps; excluded from ⌘-Tab cycling.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = markerView
        markerView.needsDisplay = true
    }

    func pulse() {
        markerView.pulse()
    }
}

private final class MarkerView: NSView {
    private let tip: NSPoint
    private let label: String
    private var phase: CGFloat = 0

    init(tip: NSPoint, label: String, size: NSSize) {
        self.tip = tip
        self.label = label
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func pulse() {
        phase += 0.25
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }

        let pulse = 1.0 + 0.12 * sin(phase)

        let ring = NSBezierPath(ovalIn: NSRect(
            x: tip.x - 22 * pulse, y: tip.y - 22 * pulse,
            width: 44 * pulse, height: 44 * pulse
        ))
        NSColor.systemRed.withAlphaComponent(0.45).setStroke()
        ring.lineWidth = 4
        ring.stroke()

        drawRedCursor(tip: tip)

        if !label.isEmpty {
            drawLabel(label, near: tip)
        }
    }

    private func drawRedCursor(tip: NSPoint) {
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: tip.x - 16, y: tip.y + 24))
        path.line(to: NSPoint(x: tip.x - 6, y: tip.y + 17))
        path.line(to: NSPoint(x: tip.x - 10, y: tip.y + 30))
        path.line(to: NSPoint(x: tip.x + 3, y: tip.y + 19))
        path.line(to: NSPoint(x: tip.x - 2, y: tip.y + 15))
        path.close()

        NSColor.systemRed.setFill()
        NSColor.white.setStroke()
        path.lineWidth = 2
        path.fill()
        path.stroke()
    }

    private func drawLabel(_ text: String, near tip: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: tip.x + 18, y: tip.y + 6, width: size.width + 18, height: size.height + 12)

        NSColor.systemRed.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()

        (text as NSString).draw(
            in: NSRect(x: rect.minX + 9, y: rect.minY + 6, width: size.width, height: size.height),
            withAttributes: attrs
        )
    }
}
