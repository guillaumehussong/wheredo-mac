import Foundation
import AppKit

/// One full Wheredo cycle: voice question → screen capture → vision → voice answer.
///
/// Pipeline timeline (typical, with SPEAK_FILLER=true):
///   0.0 s  user stops talking → STT transcription returned
///   0.0 s  filler audio starts ("Let me take a look…")      ┐ run in
///   0.1 s  screenshot captured                              │ parallel
///   ~5 s   vision model returns answer + pointer coords     ┘
///   ~5 s   filler finished → answer is spoken, red guide cursor appears
enum Assistant {
    static var defaultVoice: String { Config.ttsVoice }

    static func runCycle(
        voice: String = Config.ttsVoice,
        useVoice: Bool = true,
        speak: Bool = true,
        question: String? = nil
    ) async {
        await MainActor.run { MenuBarController.shared.setStatus(.busy) }
        defer {
            Task { @MainActor in MenuBarController.shared.setStatus(.ready) }
        }

        do {
            if OAuth.load() == nil {
                _ = try await OAuth.login()
            }

            // Per-step stopwatch: every pipeline stage logs its duration so slow
            // steps (network, model) are visible in wheredo.log.
            var t = Date()
            func lap(_ label: String) {
                UserFeedback.log(String(format: "   ⏱ %@: %.1fs", label, Date().timeIntervalSince(t)))
                t = Date()
            }

            let userQuestion: String
            if useVoice {
                await MainActor.run { MenuBarController.shared.setStatus(.listening) }
                NSSound(named: "Tink")?.play()
                userQuestion = try await Voice.ask(voice: voice)
                await MainActor.run { MenuBarController.shared.setStatus(.busy) }
                UserFeedback.log("🗣 You: \(userQuestion)")
                lap("voice + transcription")
            } else if let question, !question.isEmpty {
                userQuestion = question
                t = Date()
            } else {
                UserFeedback.log(WheredoCLI.usage)
                return
            }

            await Actions.dismissGuide()

            // Clicky-style: speak "let me take a look…" while capture + vision run in parallel.
            let fillerTask: Task<Void, Never>? = (speak && useVoice)
                ? Task { await Filler.speak() }
                : nil

            // Capture the screen and refresh the OAuth token concurrently —
            // both are needed before the vision call.
            UserFeedback.log("📸 Capturing screen…")
            async let captureTask = ScreenCapture.captureFrontmost()
            async let tokenTask = OAuth.accessToken()
            let capture = try await captureTask
            _ = try await tokenTask
            let b64 = try ScreenCapture.jpegBase64(capture.image)
            lap("capture")

            UserFeedback.log("👁 Analyzing…")
            let appCtx = ScreenCapture.frontmostContext()
            let result = try await Vision.analyze(imageBase64: b64, question: userQuestion, appContext: appCtx)
            UserFeedback.log("💬 Grok: \(result.spokenAnswer)")
            lap("vision (\(XAI.visionModel))")

            // Never talk over the filler.
            if let fillerTask { await fillerTask.value }

            // Show the red guide cursor before speaking so the user can already
            // see WHERE to click while hearing the explanation.
            if !result.actions.isEmpty {
                await Actions.showGuide(for: result.actions, context: capture.context)
            }

            if speak {
                UserFeedback.log("🔊 Playing response…")
                do {
                    try await Voice.speak(result.spokenAnswer, voice: voice)
                    lap("speech (\(Config.ttsEngine))")
                } catch {
                    UserFeedback.error(title: "Voice unavailable", message: "\(error)")
                }
            }

            // Re-show after speech: TTS playback can outlive the overlay timer,
            // so refresh the markers once the answer has finished playing.
            if !result.actions.isEmpty {
                await Actions.showGuide(for: result.actions, context: capture.context)
            }

            // Optional auto-click: only when the model set click=true, and always
            // behind a user confirmation dialog (never click silently).
            for action in result.actions where action.click == true {
                guard let p = action.point else { continue }
                let target = Actions.toPixels(p, context: capture.context)
                let ok = await Actions.confirmAndClick(at: target, label: action.label)
                if ok { Actions.click(at: target) }
            }
        } catch let e as OAuthError {
            switch e {
            case .notLoggedIn:
                UserFeedback.error(
                    title: "Not logged in",
                    message: "Run from Terminal once: ~/Applications/Wheredo.app/Contents/MacOS/Wheredo --login"
                )
            default:
                UserFeedback.error(title: "OAuth error", message: "\(e)")
            }
        } catch CaptureError.permissionDenied {
            UserFeedback.error(title: "Screen Recording", message: ScreenCapture.stalePermissionMessage)
        } catch let ns as NSError where ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            UserFeedback.error(title: "Screen Recording", message: ScreenCapture.stalePermissionMessage)
        } catch VoiceError.micDenied {
            UserFeedback.error(
                title: "Microphone",
                message: "Enable Wheredo in System Settings → Privacy → Microphone."
            )
        } catch VoiceError.noAudioDetected {
            UserFeedback.error(title: "No audio", message: VoiceError.noAudioDetected.description)
        } catch VoiceError.timeout {
            UserFeedback.error(title: "Timeout", message: VoiceError.timeout.description)
        } catch let e as VoiceError {
            UserFeedback.error(title: "Voice error", message: e.description)
        } catch {
            UserFeedback.error(title: "Error", message: "\(error)")
        }
    }
}

/// Resident menu-bar mode: installs the status item + global hotkey (⌘$) and
/// runs the AppKit event loop forever. Each hotkey press triggers one
/// Assistant.runCycle; concurrent presses are rejected while a cycle is running.
@MainActor
final class ListenMode {
    static let shared = ListenMode()

    /// True while a question/answer cycle is in flight (prevents overlapping cycles).
    private var busy = false

    func run(voice: String = Assistant.defaultVoice) async -> Never {
        UserFeedback.log("""
        ━━━ Wheredo active ━━━
        Look for the **G** icon in the menu bar (top right, near Cursor icons).
        Press ⌘$ to speak, or click the icon → Speak now.
        """)

        MenuBarController.shared.install { [weak self] in
            self?.triggerCycle(voice: voice)
        }

        // Pre-generate the Grok-voice filler audio so it plays instantly on first use.
        Task.detached { await Filler.warmCache() }

        HotkeyListener.shared.start { [weak self] in
            self?.triggerCycle(voice: voice)
        }

        if !HotkeyListener.shared.hasGlobalHotkey {
            MenuBarController.shared.setStatus(.needAccessibility)
        }

        NSApplication.shared.run()
        fatalError("NSApplication.run returned")
    }

    private func triggerCycle(voice: String) {
        guard !busy else {
            UserFeedback.log("⏳ Wheredo is busy…")
            NSSound(named: "Basso")?.play()
            return
        }
        busy = true
        Task { @MainActor in
            defer {
                self.busy = false
                MenuBarController.shared.setStatus(.ready)
                UserFeedback.log("⌘$ — ready for another question.")
            }
            await Assistant.runCycle(voice: voice, useVoice: true, speak: true)
        }
    }
}
