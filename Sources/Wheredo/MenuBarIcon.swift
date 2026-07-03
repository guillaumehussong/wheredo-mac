import AppKit

/// Menu bar icons — native SF Symbols only, so the badge looks exactly like
/// the neighboring system icons and adapts to light/dark menu bars.
/// The state change is unmissable because the whole glyph changes:
///   ready → pointer, listening → mic, busy → animated dots.
enum MenuBarIcon {
    private static let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)

    static func image(for status: MenuBarController.Status) -> NSImage {
        switch status {
        case .ready:
            return symbol("cursorarrow", fallback: "cursorarrow.click")
        case .listening:
            return symbol("mic.fill", fallback: "mic")
        case .busy:
            return symbol("ellipsis.circle.fill", fallback: "hourglass")
        case .needAccessibility:
            return symbol("lock.fill", fallback: "lock")
        case .error:
            return symbol("exclamationmark.triangle.fill", fallback: "exclamationmark.circle")
        }
    }

    /// Alternate frame for the listening pulse (mic outline ↔ filled).
    static func listeningPulseFrame() -> NSImage {
        symbol("mic", fallback: "mic.fill")
    }

    /// Alternate frame for the busy pulse (dots outline ↔ filled).
    static func busyPulseFrame() -> NSImage {
        symbol("ellipsis.circle", fallback: "hourglass")
    }

    private static func symbol(_ name: String, fallback: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Wheredo")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "Wheredo")
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Wheredo")!
        let sized = img.withSymbolConfiguration(config) ?? img
        sized.isTemplate = true
        return sized
    }
}
