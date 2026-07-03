import AppKit

/// Temporary activation-policy switch used while the guide overlay is on screen.
///
/// Wheredo normally runs as an `.accessory` app (menu-bar only, no Dock icon).
/// In that mode macOS may refuse to bring our overlay panels above the active
/// app's windows. The workaround: promote to `.regular` + activate while markers
/// are visible, then drop back to `.accessory` when they are dismissed.
enum AppVisibility {
    private static var overlayActive = false

    /// Called by GuideCursor.show() right before ordering the marker panels front.
    static func enableOverlayWindows() {
        guard !overlayActive else { return }
        overlayActive = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called by GuideCursor.dismiss() — returns to menu-bar-only mode.
    static func restoreBackgroundMode() {
        guard overlayActive else { return }
        overlayActive = false
        NSApp.setActivationPolicy(.accessory)
    }
}
