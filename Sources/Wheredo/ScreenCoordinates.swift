import AppKit

/// ScreenCaptureKit (top-left origin) ↔ Cocoa (bottom-left origin) conversions.
///
/// macOS uses TWO global coordinate systems:
/// - ScreenCaptureKit / CoreGraphics: y grows DOWNWARD from the top-left of the
///   topmost display (what the vision model's normalized coords map into).
/// - Cocoa / AppKit (NSWindow, NSEvent): y grows UPWARD from the bottom-left.
///
/// Both share the x axis, so converting is a single flip around the total
/// desktop height. Getting this wrong puts markers on the wrong screen/edge.
enum ScreenCoordinates {
    /// Total desktop height across ALL displays — the pivot for the y-flip.
    private static var globalMaxY: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? 0
    }

    /// A screen's frame expressed in ScreenCaptureKit space (used to locate
    /// which display a captured window belongs to).
    static func sckFrame(for screen: NSScreen) -> CGRect {
        let cocoa = screen.frame
        return CGRect(
            x: cocoa.minX,
            y: globalMaxY - cocoa.maxY,
            width: cocoa.width,
            height: cocoa.height
        )
    }

    /// Flip a ScreenCaptureKit point into Cocoa space (for window placement).
    static func sckToCocoa(_ sck: CGPoint) -> CGPoint {
        CGPoint(x: sck.x, y: globalMaxY - sck.y)
    }

    /// Bounding rectangle of the whole desktop in Cocoa space.
    static func unionFrameCocoa() -> NSRect {
        NSScreen.screens.reduce(.zero) { $0.union($1.frame) }
    }
}
