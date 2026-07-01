import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Captures a single frame of the frontmost window (or the main display as fallback).
enum ScreenCapture {
    static func captureFrontmost() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetWindow: SCWindow? = {
            if let pid = frontApp?.processIdentifier {
                return content.windows.first(where: { $0.owningApplication?.processID == pid })
            }
            return content.windows.first
        }()

        if let window = targetWindow {
            return try await capture(window: window)
        }
        // Fallback: main display
        guard let display = content.displays.first else { throw CaptureError.noContent }
        return try await capture(display: display)
    }

    private static func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        config.capturesShadowsOnly = false
        config.scalesToFit = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func capture(display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width * 2
        config.height = display.height * 2
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Frontmost app metadata injected into the vision prompt.
    static func frontmostContext() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "unknown"
        let bundle = app?.bundleIdentifier ?? "unknown"
        let mainDisplay = NSScreen.main?.frame ?? .zero
        return "App active: \(name) (bundle \(bundle)). Résolution écran principal: \(Int(mainDisplay.width))x\(Int(mainDisplay.height))."
    }

    static func jpegBase64(_ image: CGImage, quality: CGFloat = 0.8) throws -> String {
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
    case noContent, encodeFailed
}
