import Foundation

enum HTTP {
    static func postForm(_ url: String, _ fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw HTTPError.badURL(url) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(XAI.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = formEncode(fields).data(using: .utf8)
        return try await send(req)
    }

    static func postJSON(_ url: String, _ body: Data, bearer: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw HTTPError.badURL(url) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(XAI.userAgent, forHTTPHeaderField: "User-Agent")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        return try await send(req)
    }

    static func getJSON(_ url: String, bearer: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw HTTPError.badURL(url) }
        var req = URLRequest(url: u)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(XAI.userAgent, forHTTPHeaderField: "User-Agent")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HTTPError.notHTTP }
        return (data, http)
    }

    static func formEncode(_ fields: [String: String]) -> String {
        fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
    }
}

enum HTTPError: Error {
    case badURL(String), notHTTP, status(Int, String)
}
