import Foundation
import AppKit

/// macOS registers TCC (Privacy) entries only when the app is launched via Launch Services (`open`),
/// not when the binary is exec'd from Terminal.
enum AppLaunch {
    static let viaOpenFlag = "--launched-via-open"

    static var wasLaunchedViaOpen: Bool {
        CommandLine.arguments.contains(viaOpenFlag)
    }

    /// Re-launch this app bundle through `/usr/bin/open` and wait until it exits.
    @discardableResult
    static func relaunchViaOpen(extraArgs: [String]) -> Int32 {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else {
            print("❌ Not running from a .app bundle.")
            return 1
        }

        print("↻ Relaunching via Launch Services (required to appear in Privacy settings)…")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-W", "-n", "-a", bundle, "--args"] + extraArgs + [viaOpenFlag]

        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            print("❌ Failed to relaunch: \(error)")
            return 1
        }
    }
}
