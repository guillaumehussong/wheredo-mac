import Foundation
import ScreenCaptureKit
import CoreGraphics

/// Metadata for the last screen capture (maps vision coords → screen position).
struct CaptureContext {
    /// Region captured, in ScreenCaptureKit coords (origin top-left of primary display).
    let bounds: CGRect
    let source: Source

    enum Source {
        case window
        case display
    }

    /// Normalized vision point (0–1000, top-left of captured image) → global SCK point.
    func pointInScreenSpace(_ p: UIAction.Point) -> CGPoint {
        CGPoint(
            x: bounds.minX + (p.x / 1000.0) * bounds.width,
            y: bounds.minY + (p.y / 1000.0) * bounds.height
        )
    }
}

struct CaptureResult {
    let image: CGImage
    let context: CaptureContext
}

/// Last capture context for coordinate mapping (set on each capture).
enum CaptureState {
    static var lastContext: CaptureContext?
}
