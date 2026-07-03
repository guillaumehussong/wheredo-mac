import Foundation
import AppKit

/// macOS ties TCC permissions to a stable signed app bundle — not `.build/` binaries.
enum Runtime {
    static func printLaunchInfo() {
        let exec = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "(none)"
        let isStableApp = exec.contains(".app/Contents/MacOS/")

        if isStableApp {
            print("Wheredo (\(bundleID)) — \(Bundle.main.bundlePath)")
        } else {
            print("""
            ⚠️  Not running from Wheredo.app — won't appear in Privacy settings.
               Install: ./scripts/install-app.sh
               Setup:   ~/Applications/Wheredo.app/Contents/MacOS/Wheredo --setup-permissions
            """)
        }
    }
}

enum Permissions {
    private static var openedSettings: Set<String> = []

    static func openPrivacySettings(_ urlString: String, key: String) {
        guard !openedSettings.contains(key) else { return }
        openedSettings.insert(key)
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
