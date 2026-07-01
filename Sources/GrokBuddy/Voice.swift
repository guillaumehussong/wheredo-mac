import Foundation
import AVFoundation

/// Grok Voice realtime via WebSocket. Two helpers for the spike:
///  - ask(): listen to the user and return the transcribed question
///  - speak(): one-shot synthesis + playback of a text answer
enum Voice {
    // MARK: - Listen (returns the user's spoken question)

    static func ask(instructions: String, voice: String) async throws -> String {
        let token = try await ephemeralToken()
        let session = try await VoiceSession.open(token: token, instructions: instructions, voice: voice)
        defer { session.close() }

        print("🎙 Parle ta question… (silence 1.2 s pour valider)")
        return try await session.waitForUserTranscript(timeout: 30)
    }

    // MARK: - Speak (one-shot TTS via realtime)

    static func speak(_ text: String, voice: String) async throws {
        let token = try await ephemeralToken()
        let session = try await VoiceSession.open(
            token: token,
            instructions: "Lis le message à voix haute, naturellement, sans commentaire additionnel.",
            voice: voice
        )
        defer { session.close() }

        try await session.speakText(text)
    }

    // MARK: - Token

    static func ephemeralToken() async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["expires_after": ["seconds": 300]])
        let token = try await OAuth.accessToken()
        let (data, resp) = try await HTTP.postJSON("\(XAI.apiBase)/realtime/client_secrets", body, bearer: token)
        guard resp.statusCode == 200 else {
            throw VoiceError.tokenFailed(resp.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let value = json["value"] as? String { return value }
        if let secret = json["client_secret"] as? [String: Any], let value = secret["value"] as? String { return value }
        throw VoiceError.tokenMissing
    }
}

enum VoiceError: Error {
    case tokenFailed(Int, String), tokenMissing, wsOpenFailed, timeout
}

// MARK: - Realtime session

private final class VoiceSession: NSObject {
    let task: URLSessionWebSocketTask
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    var sampleRate: Double = 48000
    var pendingBuffers: [AVAudioPCMBuffer] = []
    var playing = false
    var transcriptContinuation: CheckedContinuation<String, Error>?
    var botText = ""
    var speakDoneContinuation: CheckedContinuation<Void, Error>?

    static func open(token: String, instructions: String, voice: String) async throws -> VoiceSession {
        let url = URL(string: "wss://api.x.ai/v1/realtime?model=\(XAI.realtimeModel)")!
        let ws = URLSession(configuration: .default)
        let task = ws.webSocketTask(with: url, protocols: ["xai-client-secret.\(token)"])
        let session = VoiceSession(task: task)
        task.resume()
        try await session.waitForOpen()
        try await session.sendSessionUpdate(instructions: instructions, voice: voice)
        session.startPlayback()
        return session
    }

    init(task: URLSessionWebSocketTask) {
        self.task = task
        super.init()
    }

    func close() {
        engine.stop()
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func waitForOpen() async throws {
        // No direct "open" event on URLSessionWebSocketTask; attempt a no-op send/receive loop guard.
        // We rely on send succeeding shortly after resume.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func sendSessionUpdate(instructions: String, voice: String) async throws {
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "voice": voice,
                "instructions": instructions,
                "turn_detection": ["type": "server_vad", "silence_duration_ms": 1200],
                "input_audio_transcription": ["model": XAI.sttModel],
                "audio": [
                    "input": ["format": ["type": "audio/pcm", "rate": 24000]],
                    "output": ["format": ["type": "audio/pcm", "rate": 24000]]
                ]
            ]
        ]
        try await sendJSON(payload)
    }

    func speakText(_ text: String) async throws {
        // Send the text as a user message and request a response, then wait for audio.done.
        try await sendJSON([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user",
                     "content": [["type": "input_text", "text": text]]]
        ])
        try await sendJSON(["type": "response.create"])

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.speakDoneContinuation = cont
            self.startReceiving()
        }
    }

    func waitForUserTranscript(timeout: TimeInterval) async throws -> String {
        startMicCapture()
        startReceiving()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.transcriptContinuation = cont
        }
    }

    // MARK: Mic capture (24kHz mono PCM 16-bit)

    private func startMicCapture() {
        let input = engine.inputNode
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: input.outputFormat(forBus: 0), to: fmt)

        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self, let conv else { return }
            let ratio = 24000.0 / buffer.format.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outFrames) else { return }
            var error: NSError?
            conv.convert(to: out, error: &error, withInputFrom: { _, _ in buffer })
            if error != nil { return }
            let bytes = out.int16ChannelData?[0]
            let count = Int(out.frameLength)
            var raw = Data(capacity: count * 2)
            raw.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                memcpy(base, bytes!, count * 2)
            }
            let b64 = raw.base64EncodedString()
            self.sendJSON(["type": "input_audio_buffer.append", "audio": b64])
        }
        do { try engine.start() } catch { /* engine may already run for playback */ }
    }

    // MARK: Playback

    private func startPlayback() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!)
        do { try engine.start() } catch {}
        player.play()
    }

    private func enqueueAudio(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(data.count / 2)) else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            buf.int16ChannelData?[0].update(from: base, count: data.count / 2)
        }
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
    }

    // MARK: Receive loop

    private func startReceiving() {
        Task { [weak self] in
            guard let self else { return }
            while task.readyState == .open || task.closeCode == .invalid {
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .data(let d): self.handle(d)
                    case .string(let s): self.handle(Data(s.utf8))
                    @unknown default: break
                    }
                } catch {
                    self.fail(error)
                    return
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            if let t = json["transcript"] as? String, !t.isEmpty {
                transcriptContinuation?.resume(returning: t)
                transcriptContinuation = nil
            }
        case "response.output_audio.delta":
            if let d = json["delta"] as? String { enqueueAudio(base64: d) }
        case "response.output_audio.done":
            speakDoneContinuation?.resume()
            speakDoneContinuation = nil
        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "voice error"
            fail(VoiceError.tokenFailed(0, msg))
        default: break
        }
    }

    private func fail(_ err: Error) {
        transcriptContinuation?.resume(throwing: err); transcriptContinuation = nil
        speakDoneContinuation?.resume(throwing: err); speakDoneContinuation = nil
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: payload) else { return }
        task.send(.data(d)) { _ in }
    }
}
