import Foundation

/// A grounded UI action returned by Grok vision. Coordinates are NORMALIZED (0–1000)
/// so they map to any screen resolution; we convert to pixels in Actions.swift.
struct UIAction: Decodable {
    let point: Point?
    let click: Bool?
    let label: String?
    let speak: String?

    struct Point: Decodable {
        let x: Double
        let y: Double
        let screen: Int?

        init(x: Double, y: Double, screen: Int? = nil) {
            self.x = x
            self.y = y
            self.screen = screen
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            x = try Self.flexDouble(c, key: .x)
            y = try Self.flexDouble(c, key: .y)
            screen = try c.decodeIfPresent(Int.self, forKey: .screen)
        }

        private enum CodingKeys: String, CodingKey { case x, y, screen }

        private static func flexDouble(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Double {
            if let v = try? c.decode(Double.self, forKey: key) { return v }
            if let v = try? c.decode(Int.self, forKey: key) { return Double(v) }
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Expected number")
        }
    }
}

struct VisionResult {
    let spokenAnswer: String
    let actions: [UIAction]
}

/// Sends the screenshot + user question to the configured vision model and
/// parses its strict-JSON reply into a spoken answer + grounded pointer actions.
enum Vision {
    /// Heuristic: does the question ask WHERE something is / HOW to do something?
    /// If yes, the system prompt nudges the model to return pointer coordinates.
    static func needsPointing(_ question: String) -> Bool {
        let q = question.lowercased()
        let keys = [
            "how ", "where", "comment", "ouvrir", "ouvre", "cliqu", "click",
            "nouvelle", "new ", "trouver", "find", "faire", "go to", "open "
        ]
        return keys.contains { q.contains($0) }
    }

    /// Single vision call — no auto-high detail, no retry (those doubled latency).
    static func analyze(imageBase64: String, question: String, appContext: String) async throws -> VisionResult {
        let result = try await analyze(
            imageBase64: imageBase64,
            question: question,
            appContext: appContext,
            imageDetail: Config.visionImageDetail,
            strictPointing: needsPointing(question)
        )

        if result.actions.isEmpty && needsPointing(question) {
            print("⚠️  No pointer coordinates returned — guide overlay cannot appear.")
        } else if !result.actions.isEmpty {
            print("   \(result.actions.count) pointer action(s) parsed.")
        }

        return result
    }

    private static func analyze(
        imageBase64: String,
        question: String,
        appContext: String,
        imageDetail: String,
        strictPointing: Bool = false
    ) async throws -> VisionResult {
        let pointingRules = strictPointing ? """
        The user is asking WHERE something is: if the relevant control is visible on screen, return its coordinates.
        """ : ""

        let systemPrompt = """
        You are a vocal Mac tutor helping the user with the app currently on screen.
        You see a screenshot of the active window. \(appContext)
        Reply in the same language as the user's question. Be concise and natural for text-to-speech.
        \(pointingRules)

        A red guide cursor will appear at each point you return — use it to show WHERE to click.

        ACCURACY FIRST:
        - Use your real knowledge of the app to answer correctly (menus, settings, features).
        - Only point at a control if it is ACTUALLY VISIBLE in the screenshot and truly relevant.
        - If the feature lives elsewhere (a menu, a settings page), say the exact path in "speak"
          (e.g. "Open Settings, then the MCP tab") and point at the first visible step (e.g. the gear icon) if one exists.
        - Never point at an unrelated control just to have an action. An empty "actions" array is better than a wrong pointer.
        - If you are not sure, say what you would check — do not guess.

        Reply with STRICT JSON only:
        {
          "speak": "short phrase to say aloud",
          "actions": [
            { "point": { "x": 850, "y": 50, "screen": 0 }, "label": "visible text or icon", "click": false }
          ]
        }
        Rules:
        - x and y are integers 0 (left/top) to 1000 (right/bottom) on the captured screenshot.
        - Put the point on the CENTER of the clickable control.
        - label: exact visible text OR icon symbol ("+", "×", "…") — never invent names.
        - click: false unless the user explicitly asked you to click for them.
        - No markdown, no text outside the JSON object.
        """

        let body: [String: Any] = [
            "model": XAI.visionModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": question],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(imageBase64)",
                                "detail": imageDetail
                            ]
                        ]
                    ]
                ]
            ],
            "response_format": ["type": "json_object"],
            "temperature": Config.visionTemperature,
            "max_tokens": Config.visionMaxTokens
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await authorizedPost("\(XAI.apiBase)/chat/completions", jsonData)
        guard resp.statusCode == 200 else {
            throw VisionError.requestFailed(resp.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let chat = try JSONDecoder().decode(ChatCompletion.self, from: data)
        let raw = chat.choices.first?.message.content ?? "{}"
        return parseVisionJSON(raw)
    }

    /// Parse the model's reply. Models occasionally return malformed JSON, so this
    /// is deliberately forgiving: on failure the raw text becomes the spoken answer
    /// (the user still hears something useful) and actions default to empty.
    static func parseVisionJSON(_ raw: String) -> VisionResult {
        guard let blob = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: blob) as? [String: Any]
        else {
            return VisionResult(spokenAnswer: raw, actions: [])
        }

        let speak = parsed["speak"] as? String ?? raw
        let actions = parseActions(from: parsed["actions"])

        if actions.isEmpty, let arr = parsed["actions"] as? [[String: Any]], !arr.isEmpty {
            print("⚠️  Action JSON present but failed to decode: \(arr)")
        }

        return VisionResult(spokenAnswer: speak, actions: actions)
    }

    /// Manual action decoding tolerant to model quirks: numbers may arrive as
    /// Int, Double or String ("850"), and unknown fields are ignored.
    private static func parseActions(from value: Any?) -> [UIAction] {
        guard let arr = value as? [[String: Any]] else { return [] }

        var actions: [UIAction] = []
        for item in arr {
            let click = item["click"] as? Bool
            let label = item["label"] as? String
            let speak = item["speak"] as? String

            var point: UIAction.Point?
            if let pt = item["point"] as? [String: Any],
               let x = flexNumber(pt["x"]),
               let y = flexNumber(pt["y"]) {
                point = UIAction.Point(
                    x: x,
                    y: y,
                    screen: pt["screen"] as? Int
                )
            }

            actions.append(UIAction(point: point, click: click, label: label, speak: speak))
        }

        if actions.isEmpty, let arrData = try? JSONSerialization.data(withJSONObject: arr),
           let decoded = try? JSONDecoder().decode([UIAction].self, from: arrData) {
            return decoded
        }
        return actions
    }

    private static func flexNumber(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// POST with bearer auth; on a 401 the OAuth token is refreshed once and the
    /// request replayed, so an expired token never surfaces as a user-facing error.
    private static func authorizedPost(_ url: String, _ body: Data) async throws -> (Data, HTTPURLResponse) {
        let token = try await OAuth.accessToken()
        let (data, resp) = try await HTTP.postJSON(url, body, bearer: token)
        guard resp.statusCode == 401, let creds = OAuth.load() else { return (data, resp) }
        let refreshed = try await OAuth.refresh(creds)
        OAuth.save(refreshed)
        return try await HTTP.postJSON(url, body, bearer: refreshed.accessToken)
    }
}

private struct ChatCompletion: Decodable {
    let choices: [Choice]
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String }
}

enum VisionError: Error {
    case parseFailed(String), requestFailed(Int, String)
}
