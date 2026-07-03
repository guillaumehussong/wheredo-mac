import Foundation
import AVFoundation

/// Voice I/O facade: speech-to-text via the xAI REST /v1/stt endpoint,
/// text-to-speech via /v1/tts (natural Grok voice) or the local macOS
/// synthesizer (instant, offline) depending on TTS_ENGINE.
enum Voice {
    /// Record the user's spoken question and return its transcription.
    /// Recording stops automatically after `STT_SILENCE` seconds of silence.
    static func ask(voice: String) async throws -> String {
        _ = voice
        print("🎙 Speak your question… (1.2 s silence to confirm)")
        return try await SpeechToText.listen(timeout: 30)
    }

    /// Speak `text` aloud using the configured TTS engine.
    /// - "local": macOS AVSpeechSynthesizer — instant, works offline.
    /// - "xai" (default): Grok voice — natural but adds 1–3 s of network latency.
    static func speak(_ text: String, voice: String) async throws {
        if Config.ttsEngine == "local" {
            await LocalTTS.speak(text)
            return
        }
        let audio = try await synthesizeMP3(text, voice: voice)
        try await AudioPlayer.playMP3(audio)
    }

    /// Generate MP3 audio via the xAI TTS endpoint (no playback).
    static func synthesizeMP3(_ text: String, voice: String) async throws -> Data {
        let token = try await OAuth.accessToken()
        let body: [String: Any] = [
            "text": text,
            "voice_id": voice,
            "language": Config.ttsLanguage,
            "output_format": ["codec": "mp3", "sample_rate": 24000]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await HTTP.postJSON("\(XAI.apiBase)/tts", jsonData, bearer: token)
        guard resp.statusCode == 200 else {
            throw VoiceError.tokenFailed(resp.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let b64 = json["audio"] as? String,
           let decoded = Data(base64Encoded: b64) {
            return decoded
        }
        return data
    }
}

/// Clicky-style instant filler ("Let me take a look…") played while the model thinks.
///
/// Why: the reasoning vision model takes ~5 s. Instead of dead silence, we speak a
/// short acknowledgement THE MOMENT the user stops talking, in parallel with the
/// screen capture + vision request. The perceived latency drops to near zero.
///
/// How: each phrase is synthesized ONCE with the natural Grok voice, cached as MP3
/// under Application Support, then replayed instantly on every later question.
enum Filler {
    /// Spoken filler phrases, localized to the configured TTS language.
    /// (The French strings are intentional — they are what the app SAYS
    /// when TTS_LANGUAGE=fr, not untranslated source text.)
    static var phrases: [String] {
        Config.ttsLanguage.hasPrefix("fr")
            ? ["Laisse-moi regarder ça.", "Je regarde ton écran.", "Un instant, je vérifie."]
            : ["Let me take a look.", "Checking your screen.", "One moment, looking into it."]
    }

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Wheredo/fillers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Cache key includes language AND voice so changing either regenerates audio.
    private static func cacheURL(for index: Int) -> URL {
        cacheDir.appendingPathComponent("\(Config.ttsLanguage)-\(Config.ttsVoice)-\(index).mp3")
    }

    /// Speak a random filler. Instant when cached; falls back to local voice otherwise.
    static func speak() async {
        guard Config.speakFiller else { return }
        let index = Int.random(in: 0..<phrases.count)
        let url = cacheURL(for: index)

        if let data = try? Data(contentsOf: url) {
            try? await AudioPlayer.playMP3(data)
            return
        }
        // Not cached yet: instant local voice now, warm the Grok-voice cache for next time.
        await LocalTTS.speak(phrases[index])
        Task.detached { await warmCache() }
    }

    /// Pre-generate all filler audio with the Grok voice (runs in background at startup).
    static func warmCache() async {
        for (i, phrase) in phrases.enumerated() {
            let url = cacheURL(for: i)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try await Voice.synthesizeMP3(phrase, voice: Config.ttsVoice)
                try data.write(to: url, options: .atomic)
            } catch {
                print("⚠️  Filler cache: \(error)")
                return
            }
        }
    }
}

enum VoiceError: Error, CustomStringConvertible {
    case tokenFailed(Int, String), tokenMissing, wsOpenFailed, timeout, micDenied, noAudioDetected

    var description: String {
        switch self {
        case .tokenFailed(let code, let msg): return "Voice API \(code): \(msg)"
        case .tokenMissing: return "Missing voice token"
        case .wsOpenFailed: return "Voice WebSocket unavailable"
        case .timeout: return "Timeout — speak then pause for 1.2 s"
        case .micDenied: return "Microphone not authorized"
        case .noAudioDetected: return "No audio detected — check mic (Wheredo in System Settings → Microphone)"
        }
    }
}

@MainActor
enum AudioPlayer {
    /// Play MP3 data and suspend until playback finishes.
    /// We sleep for the clip duration (+0.3 s of tail room) rather than using a
    /// delegate: simpler, and precise enough for sequential speech.
    static func playMP3(_ data: Data) async throws {
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        player.play()
        let wait = player.duration + 0.3
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
}

/// Instant offline speech via macOS system voices (TTS_ENGINE=local).
@MainActor
enum LocalTTS {
    private static let synthesizer = AVSpeechSynthesizer()
    private static var delegateHolder: Delegate?

    static func speak(_ text: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let delegate = Delegate { cont.resume() }
            delegateHolder = delegate
            synthesizer.delegate = delegate

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: Config.ttsLanguage == "fr" ? "fr-FR" : "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesizer.speak(utterance)
        }
        delegateHolder = nil
    }

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        private let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            onDone()
        }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            onDone()
        }
    }
}
