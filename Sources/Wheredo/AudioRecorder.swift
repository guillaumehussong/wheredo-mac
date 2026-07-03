import Foundation
import AVFoundation

struct AudioRecording {
    let pcm: Data
    let sampleRate: Double
}

/// Records mic audio until the user stops speaking (local silence detection).
///
/// End-of-speech logic: the RMS level of each buffer is compared against
/// `silenceThreshold`. Recording ends when ALL of these hold:
///   - speech was heard at least once, for at least 0.4 s, AND
///   - the last loud buffer is older than `silenceDuration` (STT_SILENCE).
/// Safety exits: `maxDuration` overall cap, `noSpeechTimeout` when the user
/// never spoke (avoids sending 10 s of room noise to the STT API).
@MainActor
enum AudioRecorder {
    static func recordUntilSilence(
        maxDuration: TimeInterval = 30,
        silenceDuration: TimeInterval = 1.2,
        silenceThreshold: Float = 0.008,
        noSpeechTimeout: TimeInterval = 10
    ) async throws -> AudioRecording {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        print("🎤 Micro: \(Int(sampleRate)) Hz, \(format.channelCount) ch")

        var pcm = Data()
        var heardSpeech = false
        var lastLoud = Date()
        var speechStarted: Date?
        let started = Date()
        var printedLevel = false
        var done = false

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AudioRecording, Error>) in
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                guard !done else { return }
                appendPCM16(from: buffer, to: &pcm)

                let rms = rmsLevel(buffer)
                let now = Date()

                if rms > silenceThreshold {
                    heardSpeech = true
                    lastLoud = now
                    if speechStarted == nil { speechStarted = now }
                    if !printedLevel {
                        printedLevel = true
                        print("🔴 Listening…", terminator: "")
                        fflush(stdout)
                    }
                    print(".", terminator: "")
                    fflush(stdout)
                }

                let timedOut = now.timeIntervalSince(started) >= maxDuration
                let spokeLongEnough = speechStarted.map { now.timeIntervalSince($0) >= 0.4 } ?? false
                let silentLongEnough = heardSpeech && spokeLongEnough
                    && now.timeIntervalSince(lastLoud) >= silenceDuration
                let noSpeechYet = !heardSpeech && now.timeIntervalSince(started) >= noSpeechTimeout

                if silentLongEnough || timedOut || noSpeechYet {
                    done = true
                    input.removeTap(onBus: 0)
                    engine.stop()
                    if printedLevel { print("") }

                    let minBytes = Int(sampleRate * 0.2) * 2 // ≥ 0.2 s
                    if !heardSpeech || pcm.count < minBytes {
                        cont.resume(throwing: VoiceError.noAudioDetected)
                    } else {
                        cont.resume(returning: AudioRecording(pcm: pcm, sampleRate: sampleRate))
                    }
                }
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                cont.resume(throwing: VoiceError.micDenied)
            }
        }
    }

    private static func appendPCM16(from buffer: AVAudioPCMBuffer, to pcm: inout Data) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        if let floats = buffer.floatChannelData?[0] {
            var chunk = Data(count: frames * 2)
            chunk.withUnsafeMutableBytes { raw in
                guard let out = raw.bindMemory(to: Int16.self).baseAddress else { return }
                for i in 0..<frames {
                    let clamped = max(-1.0, min(1.0, floats[i]))
                    out[i] = Int16(clamped * 32767)
                }
            }
            pcm.append(chunk)
        } else if let int16 = buffer.int16ChannelData?[0] {
            pcm.append(Data(bytes: int16, count: frames * 2))
        }
    }

    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        if let channel = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<n { sum += channel[i] * channel[i] }
            return sqrt(sum / Float(n))
        }
        if let int16 = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<n {
                let s = Float(int16[i]) / 32768.0
                sum += s * s
            }
            return sqrt(sum / Float(n))
        }
        return 0
    }
}
