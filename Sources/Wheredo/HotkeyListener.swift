import AppKit

/// Global hotkey listener (⌘$). Two monitors are needed:
/// - global monitor: fires while OTHER apps are focused — requires the
///   Accessibility permission, silently returns nil without it.
/// - local monitor: fires when Wheredo itself is focused (no permission).
@MainActor
final class HotkeyListener {
    static let shared = HotkeyListener()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onTrigger: (() -> Void)?
    private(set) var isRunning = false

    var hasGlobalHotkey: Bool { globalMonitor != nil }

    var hotkeyDescription = "⌘$"

    /// Debounce: key-repeat or both monitors firing must not start two cycles.
    private var lastTrigger = Date.distantPast
    private let debounce: TimeInterval = 0.8

    func start(onTrigger: @escaping () -> Void) {
        stop()
        self.onTrigger = onTrigger

        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handleKeyDown(event)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if HotkeyListener.shared.handleKeyDown(event) {
                return nil
            }
            return event
        }

        isRunning = globalMonitor != nil || localMonitor != nil

        if globalMonitor == nil {
            UserFeedback.error(
                title: "Accessibility Required",
                message: """
                Wheredo needs Accessibility permission for the ⌘$ hotkey.

                System Settings → Privacy & Security → Accessibility
                → enable Wheredo (use + if missing)

                Or click "Speak now" in the menu bar (GB icon).
                """
            )
            Permissions.openPrivacySettings(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                key: "accessibility"
            )
        }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard matchesHotkey(event) else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastTrigger) >= debounce else { return true }
        lastTrigger = now
        NSSound(named: "Tink")?.play()
        onTrigger?()
        return true
    }

    /// Match "⌘$" across keyboard layouts: on French layouts "$" is a direct
    /// key, on US layouts it is Shift+4 (keyCode 21) — accept both.
    private func matchesHotkey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }

        if event.keyCode == 21, event.modifierFlags.contains(.shift) { return true }
        if event.charactersIgnoringModifiers == "$" { return true }
        if event.charactersIgnoringModifiers == "4", event.modifierFlags.contains(.shift) { return true }
        return false
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        onTrigger = nil
        isRunning = false
    }
}
