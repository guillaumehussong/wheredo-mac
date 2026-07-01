import Foundation

enum XAI {
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let scope = "openid profile email offline_access grok-cli:access api:access"
    static let issuer = "https://auth.x.ai"
    static let deviceAuthorizationEndpoint = "https://auth.x.ai/oauth2/device/code"
    static let tokenEndpoint = "https://auth.x.ai/oauth2/token"
    static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    static let apiBase = "https://api.x.ai/v1"
    static let realtimeModel = "grok-voice-think-fast-1.0"
    static let visionModel = "grok-4.3"
    static let sttModel = "grok-stt"
    static let userAgent = "grok-buddy/0.1 (macOS)"
}
