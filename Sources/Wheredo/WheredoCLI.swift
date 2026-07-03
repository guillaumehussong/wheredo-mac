import Foundation
import AppKit

/// Wheredo — Phase 0 spike.
@main
struct WheredoCLI {
    static func main() async {
        Config.load()
        Runtime.printLaunchInfo()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let args = CommandLine.arguments.dropFirst()
        var positional: [String] = []
        var useVoice = false
        var speak = true
        var listenMode = false
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--listen": listenMode = true
            case "--voice": useVoice = true
            case "--no-speak": speak = false
            case "--test-guide":
                await runGuideTest()
                return
            case "--setup-permissions":
                await PermissionSetup.run()
                return
            case "--setup-screen-capture":
                if !AppLaunch.wasLaunchedViaOpen {
                    _ = AppLaunch.relaunchViaOpen(extraArgs: ["--setup-screen-capture"])
                    return
                }
                await PermissionSetup.runScreenCaptureOnly()
                return
            case "--test-capture":
                if !AppLaunch.wasLaunchedViaOpen {
                    _ = AppLaunch.relaunchViaOpen(extraArgs: ["--test-capture"])
                    return
                }
                let ok = await ScreenCapture.testCapture()
                print(ok ? "Screen capture OK." : "Screen capture blocked — add Wheredo via + in System Settings.")
                return
            case "--models":
                await listModels()
                return
            case "--logout":
                OAuth.clear(); print("Logged out."); return
            case "--login":
                do {
                    _ = try await OAuth.login()
                    print("✓ Connected.")
                } catch {
                    print("OAuth error: \(error)")
                }
                return
            case "-h", "--help":
                print(usage); return
            default: positional.append(a)
            }
        }
        let question = positional.joined(separator: " ")

        if listenMode || (question.isEmpty && !useVoice) {
            await ListenMode.shared.run()
        }

        await Assistant.runCycle(
            voice: Config.ttsVoice,
            useVoice: useVoice || question.isEmpty,
            speak: speak,
            question: question.isEmpty ? nil : question
        )
    }

    static let usage = """
    Wheredo (Phase 0)

      ./run.sh                                    # recommended (stable permissions)
      ~/Applications/Wheredo.app/Contents/MacOS/Wheredo

      open -a Wheredo --args --setup-screen-capture
                                                  # screen recording only (if missing from list)

      swift run Wheredo                         # dev only — won't appear in Privacy
      swift run Wheredo --listen
      swift run Wheredo "your question"
      swift run Wheredo --login / --logout
      swift run Wheredo --test-guide

    First time:
      ./scripts/install-app.sh
      # or: open -a Wheredo --args --setup-permissions
    Config: copy .env.example to .env
    """

    static func listModels() async {
        do {
            let token = try await OAuth.accessToken()
            let (data, resp) = try await HTTP.getJSON("\(XAI.apiBase)/models", bearer: token)
            guard resp.statusCode == 200 else {
                print("Models API \(resp.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                print(String(data: data, encoding: .utf8) ?? "unparseable response")
                return
            }
            print("Available models (set VISION_MODEL in .env):")
            for m in models {
                if let id = m["id"] as? String { print("  • \(id)") }
            }
            print("\nCurrent: \(XAI.visionModel)")
        } catch {
            print("Could not list models: \(error)")
        }
    }

    @MainActor
    static func runGuideTest() {
        print("🧪 Guide overlay test — red TEST marker at your mouse for 10 seconds.")
        GuideCursor.testAtMouse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            GuideCursor.shared.dismiss()
            print("Done. If nothing appeared, overlay is blocked by macOS.")
            NSApp.terminate(nil)
        }
        NSApplication.shared.run()
    }
}
