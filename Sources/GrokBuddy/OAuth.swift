import Foundation
import Security

/// xAI OAuth (device code flow) with Keychain persistence + refresh.
struct XAICredentials: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

enum OAuth {
    static let keychainAccount = "grok-buddy-xai-oauth"
    static let keychainService = "com.grok-buddy.xai"

    static func load() -> XAICredentials? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(XAICredentials.self, from: data)
    }

    static func save(_ creds: XAICredentials) {
        let data = (try? JSONEncoder().encode(creds)) ?? Data()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(attrs as CFDictionary)
        var add = attrs
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(attrs as CFDictionary)
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
        // Expired and no refresh: return stale token, caller will surface 401.
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

        print("\n━━━ Connexion xAI (SuperGrok / X Premium) ━━━")
        if let complete = dev.verification_uri_complete {
            print("Ouvre ce lien dans ton navigateur :\n  \(complete)")
            if let url = URL(string: complete) { NSWorkspace.shared.open(url) }
        } else {
            print("Va sur \(dev.verification_uri) et entre le code : \(dev.user_code)")
            if let url = URL(string: dev.verification_uri) { NSWorkspace.shared.open(url) }
        }
        print("En attente de ta autorisation…\n")

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
                    expiresAt: tok.expires_in.map { Date().addingTimeInterval($0) }
                )
                save(creds)
                print("✓ Connecté.\n")
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
            expiresAt: tok.expires_in.map { Date().addingTimeInterval($0) }
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
