import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreVideo
import AppKit

/// Captures a single frame of the frontmost window (or the main display as fallback).
///
/// Capture strategy, in order of preference:
///   1. ScreenCaptureKit window capture (sharp, isolated frontmost window)
///   2. ScreenCaptureKit display capture (if no window matched)
///   3. Legacy CGWindowList capture (only when SCK throws the -3801 TCC error
///      even though System Settings shows the permission ON — a macOS 26 bug)
///
/// Every successful capture stores a CaptureContext (bounds + source) so the
/// vision model's normalized coordinates can later be mapped back to real pixels.
enum ScreenCapture {
    /// Touching CGMainDisplayID forces CoreGraphics to connect to the window
    /// server — without this, some SCK calls fail in CLI-launched processes.
    private static func ensureCoreGraphicsInitialized() {
        _ = CGMainDisplayID()
    }

    /// True when ScreenCaptureKit can query content (trust this over CGPreflight on macOS 26).
    @MainActor
    static func verifyAccess() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// Diagnostics file readable after `open`-launched runs (no stdout there).
    static var diagnosticsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Wheredo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("capture-diagnostics.txt")
    }

    static func writeDiagnostics(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? "[\(stamp)]\n\(text)\n".write(to: diagnosticsURL, atomically: true, encoding: .utf8)
        print(text)
    }

    /// Verify capture works (independent of System Settings UI on macOS 26).
    @MainActor
    static func testCapture() async -> Bool {
        ensureCoreGraphicsInitialized()
        var report = "CGPreflightScreenCaptureAccess: \(CGPreflightScreenCaptureAccess())\n"

        // Strict SCK test first — no fallback, so we know the real TCC state.
        var sckOK = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            report += "SCShareableContent: OK (\(content.displays.count) displays, \(content.windows.count) windows)\n"
            if let display = content.displays.first {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = screenshotConfig(width: 320, height: 200)
                _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                report += "SCScreenshotManager: OK — ScreenCaptureKit fully working\n"
                sckOK = true
            }
        } catch {
            report += "ScreenCaptureKit FAILED: \(error)\n"
        }

        do {
            let result = try await captureFrontmost()
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("wheredo-test.jpg")
            if let dest = CGImageDestinationCreateWithURL(path as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, result.image, nil)
                _ = CGImageDestinationFinalize(dest)
                report += "Capture saved: \(path.path) (\(result.image.width)x\(result.image.height), source=\(result.context.source))\n"
                NSWorkspace.shared.open(path)
            }
            report += sckOK ? "VERDICT: OK\n" : "VERDICT: DEGRADED (legacy fallback only — windows may be missing)\n"
            writeDiagnostics(report)
            return sckOK
        } catch {
            report += "captureFrontmost FAILED: \(error)\nVERDICT: BLOCKED\n"
            writeDiagnostics(report)
            printScreenCaptureHelp()
            return false
        }
    }

    /// Setup flow — triggers ScreenCaptureKit (registers Wheredo in System Settings on macOS 26+).
    @MainActor
    static func setupAccess() async -> Bool {
        ensureCoreGraphicsInitialized()

        print("   Step A: CoreGraphics permission request…")
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            print("   CGRequestScreenCaptureAccess → \(granted ? "granted" : "denied")")
        }

        print("   Step B: ScreenCaptureKit query…")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            print("   SCShareableContent OK — \(content.displays.count) display(s)")

            if let display = content.displays.first {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = screenshotConfig(width: 64, height: 64)
                _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                print("   Test capture OK")
            }
            return true
        } catch {
            print("   ScreenCaptureKit error: \(error.localizedDescription)")
            printScreenCaptureHelp()
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
            Permissions.openPrivacySettings(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                key: "screen"
            )
            return false
        }
    }

    static func printScreenCaptureHelp() {
        print("""
        Screen Recording help:
          1. System Settings → Screen & System Audio Recording → Wheredo ON
          2. If already ON: toggle OFF then ON (refreshes macOS permission)
          3. Quit Wheredo completely, relaunch from Spotlight
          4. Path: \(Bundle.main.bundlePath)
        """)
    }

    static let stalePermissionMessage = """
    macOS has not applied the Screen Recording grant to this build.

    Fix (one time):
    1. System Settings → Screen & System Audio Recording
    2. Remove Wheredo with the − button, then re-add with + (⌘⇧G → ~/Applications/Wheredo.app)
    3. Toggle it ON, quit Wheredo (G icon → Quit), reopen from Spotlight
    """

    /// Main entry point used by the assistant pipeline.
    /// Retries transient -3801 permission errors (they sometimes clear within a
    /// second on macOS 26), then falls back to legacy capture before giving up.
    @MainActor
    static func captureFrontmost() async throws -> CaptureResult {
        ensureCoreGraphicsInitialized()

        for attempt in 1...3 {
            do {
                return try await captureFrontmostImpl()
            } catch {
                if isScreenCapturePermissionError(error), attempt < 3 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                if isScreenCapturePermissionError(error), let legacy = captureLegacyFrontmost() {
                    UserFeedback.log("📸 Screen capture: using legacy fallback (SCK blocked by macOS)")
                    return legacy
                }
                if isScreenCapturePermissionError(error) {
                    throw CaptureError.permissionDenied
                }
                throw error
            }
        }
        throw CaptureError.permissionDenied
    }

    /// Legacy capture when ScreenCaptureKit returns -3801 despite Settings showing ON (macOS 26 quirk).
    /// Window-level only: on macOS 26 display-level CG capture returns the wallpaper without
    /// any windows, which would silently feed a useless screenshot to vision.
    private static func captureLegacyFrontmost() -> CaptureResult? {
        captureLegacyWindow()
    }

    private static func captureLegacyWindow() -> CaptureResult? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = list.filter { info in
            (info[kCGWindowOwnerPID as String] as? Int32) == front
            && (info[kCGWindowLayer as String] as? Int) == 0
            && (info[kCGWindowIsOnscreen as String] as? Bool) != false
        }

        guard let win = candidates.first,
              let windowID = win[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = win[kCGWindowBounds as String] as? [String: CGFloat]
        else { return nil }

        let rect = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )

        guard rect.width > 10, rect.height > 10,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution])
        else { return nil }

        let sckBounds = legacyBoundsToSCK(rect)
        let ctx = CaptureContext(bounds: sckBounds, source: .window)
        CaptureState.lastContext = ctx
        return CaptureResult(image: image, context: ctx)
    }

    /// CGWindow bounds are top-left origin; convert to SCK space.
    private static func legacyBoundsToSCK(_ cgWindowRect: CGRect) -> CGRect {
        let globalMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? cgWindowRect.maxY
        return CGRect(
            x: cgWindowRect.minX,
            y: globalMaxY - cgWindowRect.maxY,
            width: cgWindowRect.width,
            height: cgWindowRect.height
        )
    }

    @MainActor
    private static func captureFrontmostImpl() async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let scale = Config.captureScale

        // Prefer the frontmost app's window: a tight capture gives the vision
        // model higher effective resolution than a full-display screenshot.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetWindow: SCWindow? = {
            if let pid = frontApp?.processIdentifier {
                return content.windows.first(where: { $0.owningApplication?.processID == pid })
            }
            return content.windows.first
        }()

        if let window = targetWindow {
            do {
                let image = try await capture(window: window, scale: scale)
                let ctx = CaptureContext(bounds: window.frame, source: .window)
                CaptureState.lastContext = ctx
                return CaptureResult(image: image, context: ctx)
            } catch {
                if isScreenCapturePermissionError(error) { throw CaptureError.permissionDenied }
                guard let display = content.displays.first else { throw error }
                return try await captureDisplay(display, scale: scale)
            }
        }
        guard let display = content.displays.first else { throw CaptureError.noContent }
        return try await captureDisplay(display, scale: scale)
    }

    private static func isScreenCapturePermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", ns.code == -3801 { return true }
        if ns.localizedDescription.lowercased().contains("permission") { return true }
        return false
    }

    private static func captureDisplay(_ display: SCDisplay, scale: Int) async throws -> CaptureResult {
        let image = try await capture(display: display, scale: scale)
        let bounds = displayFrameSCK(display)
        let ctx = CaptureContext(bounds: bounds, source: .display)
        CaptureState.lastContext = ctx
        return CaptureResult(image: image, context: ctx)
    }

    /// SCDisplay → CGRect in SCK top-left screen space.
    private static func displayFrameSCK(_ display: SCDisplay) -> CGRect {
        for screen in NSScreen.screens {
            if screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display.displayID {
                return ScreenCoordinates.sckFrame(for: screen)
            }
        }
        return CGRect(x: 0, y: 0, width: display.width, height: display.height)
    }

    private static func screenshotConfig(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(width, 1)
        config.height = max(height, 1)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        return config
    }

    private static func capture(window: SCWindow, scale: Int) async throws -> CGImage {
        ensureCoreGraphicsInitialized()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = screenshotConfig(
            width: Int(window.frame.width) * scale,
            height: Int(window.frame.height) * scale
        )
        config.capturesShadowsOnly = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func capture(display: SCDisplay, scale: Int) async throws -> CGImage {
        ensureCoreGraphicsInitialized()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = screenshotConfig(width: display.width * scale, height: display.height * scale)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Human-readable context injected into the vision system prompt
    /// (tells the model WHICH app it is looking at).
    static func frontmostContext() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "unknown"
        let bundle = app?.bundleIdentifier ?? "unknown"
        if let bounds = CaptureState.lastContext?.bounds {
            return "Active app: \(name) (bundle \(bundle)). Captured region: \(Int(bounds.width))x\(Int(bounds.height)) px at (\(Int(bounds.minX)), \(Int(bounds.minY))."
        }
        let mainDisplay = NSScreen.main?.frame ?? .zero
        return "Active app: \(name) (bundle \(bundle)). Main display: \(Int(mainDisplay.width))x\(Int(mainDisplay.height))."
    }

    /// Encode the capture as base64 JPEG for the vision API. Quality is kept low
    /// (VISION_JPEG_QUALITY, default 0.6) — smaller payload = faster upload,
    /// and UI text remains perfectly legible to the model.
    static func jpegBase64(_ image: CGImage) throws -> String {
        let quality = Config.visionJpegQuality
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            throw CaptureError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.encodeFailed }
        return mutableData.base64EncodedString()
    }
}

enum CaptureError: Error {
    case noContent, encodeFailed, permissionDenied
}
