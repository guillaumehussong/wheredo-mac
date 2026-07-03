import Foundation
import AppKit
import AVFoundation
import ApplicationServices

/// Walks through all permission prompts so Wheredo appears in System Settings.
enum PermissionSetup {
    @MainActor
    static func run() async {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            print("""
            ❌ Install and run from Wheredo.app:

              ./scripts/install-app.sh
              open -a Wheredo --args --setup-permissions
            """)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        print("""
        ━━━ Wheredo permission setup ━━━
        App: \(Bundle.main.bundlePath)
        ID:  \(Bundle.main.bundleIdentifier ?? "?")
        PID: \(ProcessInfo.processInfo.processIdentifier)
        Via open: \(AppLaunch.wasLaunchedViaOpen ? "yes ✓" : "no — relaunching…")
        """)

        if !AppLaunch.wasLaunchedViaOpen {
            _ = AppLaunch.relaunchViaOpen(extraArgs: ["--setup-permissions"])
            return
        }

        resetMicrophoneTCCIfNeeded()

        print("\n1/3 Microphone…")
        let micOK = await MicAccess.setup()
        print(micOK ? "   ✓ Microphone OK" : "   ✗ Microphone — allow in the dialog or System Settings")

        print("\n2/3 Screen Recording…")
        let screenOK = await ScreenCapture.setupAccess()
        print(screenOK ? "   ✓ Screen Recording OK" : "   ✗ Screen Recording — allow dialog or add via + in System Settings")

        print("\n3/3 Accessibility (global hotkey ⌘$)…")
        promptAccessibility()
        try? await Task.sleep(nanoseconds: 500_000_000)
        HotkeyListener.shared.start { }
        let axOK = AXIsProcessTrusted() && HotkeyListener.shared.hasGlobalHotkey
        HotkeyListener.shared.stop()
        print(axOK
            ? "   ✓ Accessibility OK"
            : "   ✗ Accessibility — System Settings → Accessibility → + → Wheredo")

        // Keep run loop alive so macOS commits TCC + UI updates.
        print("\nWaiting 3 s for System Settings to register Wheredo…")
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        print("""

        ━━━ Check System Settings ━━━
        Wheredo should now appear in Privacy & Security → Microphone / Screen Recording.
        Screen Recording on macOS 26: if missing, click + → Applications → Wheredo.
        Accessibility: click + → Applications → Wheredo if needed.

        Launch normally: ./run.sh
        """)

        openAllPrivacyPanes()
    }

    private static func resetMicrophoneTCCIfNeeded() {
        guard CommandLine.arguments.contains("--reset-mic") else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "app.wheredo.mac"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Microphone", bundleID]
        try? proc.run()
        proc.waitUntilExit()
        print("   (reset Microphone TCC for \(bundleID))")
    }

    /// Screen capture only — does not reset microphone.
    @MainActor
    static func runScreenCaptureOnly() async {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        print("━━━ Wheredo — Screen Recording setup only ━━━")
        let ok = await ScreenCapture.setupAccess()
        print(ok ? "✓ Done" : "✗ Add Wheredo manually (see below)")
        let appPath = Bundle.main.bundlePath
        print("""
        Manual add (macOS 26 often requires this):
          1. System Settings → Screen & System Audio Recording → +
          2. Press ⌘⇧G and paste: \(appPath)
          3. Enable the toggle for Wheredo
        """)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
        Permissions.openPrivacySettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            key: "screen-only"
        )
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    private static func promptAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    private static func openAllPrivacyPanes() {
        let panes = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for (i, url) in panes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                Permissions.openPrivacySettings(url, key: "setup-\(i)")
            }
        }
    }
}
