import Foundation

/// A grounded UI action returned by Grok vision. Coordinates are NORMALIZED (0–1000)
/// so they map to any screen resolution; we convert to pixels in Actions.swift.
struct UIAction: Decodable {
    let point: Point?
    let click: Bool?
    let label: String?
    let speak: String?

    struct Point: Decodable {
        let x: Double   // 0–1000 (left→right)
        let y: Double   // 0–1000 (top→bottom)
        let screen: Int? // 0 = main
    }
}

struct VisionResult {
    let spokenAnswer: String
    let actions: [UIAction]
}

/// Sends the screenshot + user question to grok-4.3 vision and parses structured actions.
enum Vision {
    static func analyze(imageBase64: String, question: String, appContext: String) async throws -> VisionResult {
        let systemPrompt = """
        Tu es un tuteur vocal qui aide l'utilisateur à utiliser l'app ouverte sur son Mac.
        Tu vois une capture de la fenêtre active. \(appContext)
        Réponds en français (ou la langue de la question), de façon concise et naturelle à la voix.

        Si tu peux indiquer où l'utilisateur doit aller, réponds en JSON STRICT avec ce schéma :
        {
          "speak": "phrase courte à dire à voix haute",
          "actions": [
            { "point": { "x": <0-1000>, "y": <0-1000>, "screen": 0 }, "label": "nom du bouton/zone", "click": false }
          ]
        }
        Règles :
        - x et y sont normalisés 0 (gaute/haut) à 1000 (droite/bas) sur la fenêtre visible.
        - Au plus 1-2 actions par réponse.
        - click: false sauf si l'utilisateur a explicitement demandé de le faire pour lui.
        - Pas de texte hors du JSON.
        Si la question ne nécessite pas de pointer l'écran, réponds quand même en JSON avec "speak" et "actions": [].
        """

        let body: [String: Any] = [
            "model": XAI.visionModel,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": question
                        ],
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(imageBase64)", "detail": "high"]
                        ]
                    ]
                ]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.2
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await HTTP.postJSON("\(XAI.apiBase)/chat/completions", jsonData)
        guard resp.statusCode == 200 else {
            throw VisionError.requestFailed(resp.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let chat = try JSONDecoder().decode(ChatCompletion.self, from: data)
        let raw = chat.choices.first?.message.content ?? "{}"
        guard let blob = raw.data(using: .utf8) else { throw VisionError.parseFailed(raw) }

        let parsed = try JSONSerialization.jsonObject(with: blob) as? [String: Any] ?? [:]
        let speak = parsed["speak"] as? String ?? raw
        var actions: [UIAction] = []
        if let arr = parsed["actions"] as? [[String: Any]] {
            let arrData = try JSONSerialization.data(withJSONObject: arr)
            actions = (try? JSONDecoder().decode([UIAction].self, from: arrData)) ?? []
        }
        return VisionResult(spokenAnswer: speak, actions: actions)
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
