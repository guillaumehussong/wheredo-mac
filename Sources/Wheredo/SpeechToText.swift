import Foundation
import AVFoundation
import AppKit

/// Speech-to-text: local mic recording, transcribed via POST /v1/stt.
enum SpeechToText {
    static func listen(timeout: TimeInterval = 30) async throws -> String {
        guard await MicAccess.ensure() else { throw VoiceError.micDenied }

        let recording = try await AudioRecorder.recordUntilSilence(
            maxDuration: timeout,
            silenceDuration: Config.sttSilence
        )
        let seconds = Double(recording.pcm.count) / (recording.sampleRate * 2)
        print(String(format: "🔊 %.1f s recorded — transcribing…", seconds))

        let wav = WAVEncoder.wrap(pcm: recording.pcm, sampleRate: UInt32(recording.sampleRate))
        return try await transcribe(wav: wav)
    }

    private static func transcribe(wav: Data) async throws -> String {
        let token = try await OAuth.accessToken()
        let (data, resp) = try await HTTP.postSTT(wav: wav, language: Config.sttLanguage, bearer: token)
        guard resp.statusCode == 200 else {
            throw VoiceError.tokenFailed(resp.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String, !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw VoiceError.tokenFailed(resp.statusCode, String(data: data, encoding: .utf8) ?? "empty STT response")
    }
}

enum MicAccess {
    /// Setup flow — always shows status and triggers the system dialog when needed.
    static func setup() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("   Authorization status: \(status.rawValue) (\(label(status)))")

        switch status {
        case .authorized:
            return await verifyRecording()
        case .notDetermined:
            print("   Showing microphone permission dialog…")
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            print("   Dialog result: \(ok ? "allowed" : "denied")")
            return ok ? await verifyRecording() : false
        default:
            Permissions.openPrivacySettings(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                key: "mic"
            )
            return false
        }
    }

    static func ensure() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            print("""
            Microphone permission denied.
            System Settings → Privacy & Security → Microphone → **Wheredo**
            """)
            Permissions.openPrivacySettings(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                key: "mic"
            )
            return false
        }
    }

    private static func label(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    private static func verifyRecording() async -> Bool {
        do {
            _ = try await AudioRecorder.recordUntilSilence(maxDuration: 2)
            print("   Mic recording test: OK")
            return true
        } catch {
            print("   Mic recording test failed: \(error)")
            return false
        }
    }
}

enum WAVEncoder {
    static func wrap(pcm: Data, sampleRate: UInt32) -> Data {
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits) / 8
        let blockAlign = channels * bits / 8
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        d.appendLE(36 + UInt32(pcm.count))
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        d.appendLE(UInt32(16))
        d.appendLE(UInt16(1))
        d.appendLE(channels)
        d.appendLE(sampleRate)
        d.appendLE(byteRate)
        d.appendLE(blockAlign)
        d.appendLE(bits)
        d.append(contentsOf: "data".utf8)
        d.appendLE(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        append(Data(bytes: &le, count: 2))
    }
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        append(Data(bytes: &le, count: 4))
    }
}
