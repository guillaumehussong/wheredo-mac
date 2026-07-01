import Foundation
import AppKit

/// GrokBuddy — Phase 0 spike.
///
/// Flow: login (if needed) → capture screen → ask vision (grok-4.3) → speak answer (Grok Voice)
///       → point cursor → confirm → click.
///
/// Modes:
///   swift run GrokBuddy "Comment je floute ce clip dans CapCut ?" [--voice] [--no-speak]
///   - sans --voice : la question vient de l'argument texte (test vision + clic sans micro)
///   - avec --voice  : la question vient du micro (Grok Voice realtime STT)
///
/// Build: swift build
/// Run:   swift run GrokBuddy "ta question" --voice
@main
struct GrokBuddyCLI {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        var positional: [String] = []
        var useVoice = false
        var speak = true
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--voice": useVoice = true
            case "--no-speak": speak = false
            case "--logout":
                OAuth.clear(); print("Déconnecté."); return
            case "--login":
                _ = try await OAuth.login(); print("✓ Connecté."); return
            case "-h", "--help":
                print(usage); return
            default: positional.append(a)
            }
        }
        let question = positional.joined(separator: " ")

        do {
            if OAuth.load() == nil {
                _ = try await OAuth.login()
            }
            let token = try await OAuth.accessToken()
            _ = token

            let voice = "glow"

            // 1. Question (texte ou micro)
            let userQuestion: String
            if useVoice {
                userQuestion = try await Voice.ask(
                    instructions: "Tu es un tuteur Mac. Réponds brièvement.",
                    voice: voice
                )
                print("🗣 Toi: \(userQuestion)")
            } else {
                guard !question.isEmpty else { print(usage); return }
                userQuestion = question
            }

            // 2. Capture écran de l'app frontmost
            print("📸 Capture de l'écran…")
            let image = try await ScreenCapture.captureFrontmost()
            let b64 = try ScreenCapture.jpegBase64(image)

            // 3. Vision grok-4.3
            print("👁 Analyse Grok…")
            let ctx = ScreenCapture.frontmostContext()
            let result = try await Vision.analyze(imageBase64: b64, question: userQuestion, appContext: ctx)
            print("💬 Grok: \(result.spokenAnswer)")
            if !result.actions.isEmpty {
                for a in result.actions {
                    if let p = a.point { print("   → point (\(p.x),\(p.y)) \(a.label ?? "")") }
                }
            }

            // 4. Réponse vocale
            if speak {
                try? await Voice.speak(result.spokenAnswer, voice: voice)
            }

            // 5. Pointage + clic confirmé
            for action in result.actions {
                guard let p = action.point else { continue }
                await Actions.pointAt(p, label: action.label)
                if action.click == true {
                    let target = Actions.toPixels(p)
                    let ok = await Actions.confirmAndClick(at: target, label: action.label)
                    if ok { Actions.click(at: target) }
                    else { print("⊘ Clic annulé.") }
                }
            }

        } catch let e as OAuthError {
            switch e {
            case .notLoggedIn:
                print("Pas connecté. Lance: swift run GrokBuddy --login")
            default:
                print("OAuth error: \(e)")
            }
        } catch {
            print("Erreur: \(error)")
        }
    }

    static let usage = """
    GrokBuddy (spike Phase 0)

      swift run GrokBuddy "ta question"          # question texte → vision + clic
      swift run GrokBuddy "ta question" --voice   # question micro (Grok Voice)
      swift run GrokBuddy --voice                 # question micro, sans question initiale
      swift run GrokBuddy --no-speak              # désactive la TTS
      swift run GrokBuddy --logout                # oublie le token xAI
    """
}
