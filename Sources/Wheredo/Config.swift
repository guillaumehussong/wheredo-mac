import Foundation

/// Loads settings from `.env` (project root or cwd) and process environment.
/// Environment variables override `.env` file values.
enum Config {
    private static var fileValues: [String: String] = loadEnvFile()

    static func load() {
        migrateLegacyDataDir()
        fileValues = loadEnvFile()
    }

    /// One-time migration from the pre-rename "GrokBuddy" data folder so
    /// existing users keep their login (oauth.json) and settings (.env).
    private static func migrateLegacyDataDir() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldDir = base.appendingPathComponent("GrokBuddy", isDirectory: true)
        let newDir = base.appendingPathComponent("Wheredo", isDirectory: true)
        guard fm.fileExists(atPath: oldDir.path) else { return }
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        for name in ["oauth.json", ".env"] {
            let old = oldDir.appendingPathComponent(name)
            let new = newDir.appendingPathComponent(name)
            if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
                try? fm.copyItem(at: old, to: new)
            }
        }
    }

    // MARK: - Models

    static var visionModel: String { string("VISION_MODEL", default: "grok-4.3") }
    static var ttsVoice: String { string("TTS_VOICE", default: "eve") }
    static var realtimeModel: String { string("REALTIME_MODEL", default: "grok-voice-latest") }
    static var apiBase: String { string("API_BASE", default: "https://api.x.ai/v1") }

    // MARK: - Vision speed / quality

    /// `low` sends a smaller image payload and is usually faster than `high`.
    static var visionImageDetail: String { string("VISION_IMAGE_DETAIL", default: "low") }
    static var visionJpegQuality: CGFloat { CGFloat(double("VISION_JPEG_QUALITY", default: 0.6)) }
    /// Capture scale multiplier (1 = native size, 2 = retina). Lower = faster upload.
    static var captureScale: Int { max(1, int("CAPTURE_SCALE", default: 1)) }
    static var visionMaxTokens: Int { max(64, int("VISION_MAX_TOKENS", default: 300)) }
    static var visionTemperature: Double { double("VISION_TEMPERATURE", default: 0.2) }

    // MARK: - Speech

    static var sttLanguage: String { string("STT_LANGUAGE", default: "en") }
    static var ttsLanguage: String { string("TTS_LANGUAGE", default: "en") }
    /// Seconds of silence that end the recording (lower = snappier, higher = fewer cut-offs).
    static var sttSilence: Double { double("STT_SILENCE", default: 0.9) }
    /// "xai" = Grok voice via network (natural, slower). "local" = macOS voice (instant).
    static var ttsEngine: String { string("TTS_ENGINE", default: "xai") }
    /// Speak a short "let me look…" filler right after the question (masks model latency).
    static var speakFiller: Bool { bool("SPEAK_FILLER", default: true) }

    // MARK: - Guide cursor (Clicky-style overlay)

    static var showGuideCursor: Bool { bool("SHOW_GUIDE_CURSOR", default: true) }
    /// Seconds before auto-dismiss (0 = stay until next ⌘$).
    static var guideCursorDuration: TimeInterval { double("GUIDE_CURSOR_DURATION", default: 15) }

    // MARK: - Lookup

    private static func string(_ key: String, default defaultValue: String) -> String {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        if let v = fileValues[key], !v.isEmpty { return v }
        return defaultValue
    }

    private static func int(_ key: String, default defaultValue: Int) -> Int {
        if let v = ProcessInfo.processInfo.environment[key], let n = Int(v) { return n }
        if let v = fileValues[key], let n = Int(v) { return n }
        return defaultValue
    }

    private static func double(_ key: String, default defaultValue: Double) -> Double {
        if let v = ProcessInfo.processInfo.environment[key], let n = Double(v) { return n }
        if let v = fileValues[key], let n = Double(v) { return n }
        return defaultValue
    }

    private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v != "0" && v.lowercased() != "false" }
        if let v = fileValues[key], !v.isEmpty { return v != "0" && v.lowercased() != "false" }
        return defaultValue
    }

    private static func loadEnvFile() -> [String: String] {
        for path in envSearchPaths() {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            return parseEnv(contents)
        }
        return [:]
    }

    /// `.env` lookup order — first existing file wins:
    ///   1. WHEREDO_ENV (explicit override)
    ///   2. ./​.env (Terminal / development runs)
    ///   3. next to the executable inside the app bundle
    ///   4. ~/Library/Application Support/Wheredo/.env — the one that applies
    ///      to Spotlight launches, where cwd is "/"
    private static func envSearchPaths() -> [String] {
        var paths: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["WHEREDO_ENV"] {
            paths.append(explicit)
        }
        let cwd = FileManager.default.currentDirectoryPath
        paths.append((cwd as NSString).appendingPathComponent(".env"))
        if let exec = Bundle.main.executableURL?.deletingLastPathComponent() {
            paths.append(exec.appendingPathComponent(".env").path)
            paths.append(exec.deletingLastPathComponent().appendingPathComponent(".env").path)
        }
        let home = NSHomeDirectory()
        paths.append((home as NSString).appendingPathComponent("Library/Application Support/Wheredo/.env"))
        return paths
    }

    private static func parseEnv(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            if s.hasPrefix("export ") { s.removeFirst(7) }
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
