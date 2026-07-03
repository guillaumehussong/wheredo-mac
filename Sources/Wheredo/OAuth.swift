import Foundation
import AppKit
import Security

/// xAI OAuth (device code flow) with persistent token storage.
struct XAICredentials: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

/// File-based token store (~/Library/Application Support/Wheredo/oauth.json,
/// chmod 600).
///
/// Why not Keychain? Keychain items are bound to the app's code signature.
/// Every rebuild with a changing signature made macOS re-prompt for the login
/// password on each launch. A user-only file has no such binding. Existing
/// Keychain entries are migrated once, then deleted.
private enum CredentialStore {
    // Historical values from the GrokBuddy era — must stay unchanged so the
    // one-time migration can still find items stored under the old name.
    static let legacyKeychainAccount = "grok-buddy-xai-oauth"
    static let legacyKeychainService = "com.grok-buddy.xai"

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Wheredo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("oauth.json")
    }

    /// Load from file; if absent, try a one-time migration from the legacy
    /// Keychain entry (then remove it so it never prompts again).
    static func load() -> XAICredentials? {
        if let creds = loadFromFile() { return creds }
        if let creds = loadFromKeychain() {
            save(creds)
            clearKeychain()
            return creds
        }
        return nil
    }

    static func save(_ creds: XAICredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        let url = fileURL
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("⚠️  Could not save credentials: \(error)")
        }
        clearKeychain()
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        clearKeychain()
    }

    private static func loadFromFile() -> XAICredentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(XAICredentials.self, from: data)
    }

    private static func loadFromKeychain() -> XAICredentials? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(XAICredentials.self, from: data)
    }

    private static func clearKeychain() {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount
        ]
        SecItemDelete(attrs as CFDictionary)
    }
}

enum OAuth {
    static func load() -> XAICredentials? {
        CredentialStore.load()
    }

    static func save(_ creds: XAICredentials) {
        CredentialStore.save(creds)
    }

    static func clear() {
        CredentialStore.clear()
    }

    /// Resolve a valid access token, refreshing if expired. Throws if not logged in.
    static func accessToken() async throws -> String {
        guard let creds = load() else {
            throw OAuthError.notLoggedIn
        }
        if let exp = creds.expiresAt, exp > Date().addingTimeInterval(60) {
            return creds.accessToken
        }
        if let refreshed = try? await refresh(creds) {
            save(refreshed)
            return refreshed.accessToken
        }
        return creds.accessToken
    }

    /// Run the device-code login flow (interactive). Opens browser, polls, stores.
    static func login() async throws -> XAICredentials {
        let (data, resp) = try await HTTP.postForm(XAI.deviceAuthorizationEndpoint, [
            "client_id": XAI.clientID,
            "scope": XAI.scope
        ])
        guard resp.statusCode == 200 else {
            throw OAuthError.deviceRequestFailed(resp.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let dev = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)

        print("\n━━━ xAI sign-in (SuperGrok / X Premium) ━━━")
        if let complete = dev.verification_uri_complete {
            print("Open this link in your browser:\n  \(complete)")
            if let url = URL(string: complete) { NSWorkspace.shared.open(url) }
        } else {
            print("Go to \(dev.verification_uri) and enter code: \(dev.user_code)")
            if let url = URL(string: dev.verification_uri) { NSWorkspace.shared.open(url) }
        }
        print("Waiting for authorization…\n")

        let deadline = Date().addingTimeInterval(TimeInterval(dev.expires_in ?? 300))
        var interval = Double(dev.interval ?? 5)

        while Date() < deadline {
            let (tdata, tresp) = try await HTTP.postForm(XAI.tokenEndpoint, [
                "grant_type": XAI.deviceGrantType,
                "client_id": XAI.clientID,
                "device_code": dev.device_code
            ])
            if tresp.statusCode == 200 {
                let tok = try JSONDecoder().decode(TokenResponse.self, from: tdata)
                let creds = XAICredentials(
                    accessToken: tok.access_token,
                    refreshToken: tok.refresh_token,
                    expiresAt: tok.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) }
                )
                save(creds)
                print("✓ Connected.\n")
                return creds
            }
            let errBody = try? JSONDecoder().decode(TokenError.self, from: tdata)
            switch errBody?.error {
            case "authorization_pending":
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            case "slow_down":
                interval += 5
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            case "access_denied", "authorization_denied":
                throw OAuthError.denied
            case "expired_token":
                throw OAuthError.expired
            default:
                throw OAuthError.tokenExchangeFailed(tresp.statusCode, String(data: tdata, encoding: .utf8) ?? "")
        }
        }
        throw OAuthError.expired
    }

    static func refresh(_ creds: XAICredentials) async throws -> XAICredentials {
        guard let refresh = creds.refreshToken else { throw OAuthError.noRefreshToken }
        let (data, resp) = try await HTTP.postForm(XAI.tokenEndpoint, [
            "grant_type": "refresh_token",
            "client_id": XAI.clientID,
            "refresh_token": refresh
        ])
        guard resp.statusCode == 200 else {
            throw OAuthError.refreshFailed(resp.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let tok = try JSONDecoder().decode(TokenResponse.self, from: data)
        return XAICredentials(
            accessToken: tok.access_token,
            refreshToken: tok.refresh_token ?? refresh,
            expiresAt: tok.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
    }
}

private struct DeviceCodeResponse: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let verification_uri_complete: String?
    let expires_in: Int?
    let interval: Int?
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}

private struct TokenError: Decodable {
    let error: String?
}

enum OAuthError: Error {
    case notLoggedIn, denied, expired, noRefreshToken
    case deviceRequestFailed(Int, String)
    case tokenExchangeFailed(Int, String)
    case refreshFailed(Int, String)
}
