import Foundation

/// Client minimale per la Messages API di Anthropic (HTTP diretto: non esiste un SDK ufficiale per Swift).
struct ClaudeClient {
    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "Errore API (\(status)): \(message)" }
    }

    struct Response {
        let raw: JSONValue
        var content: [JSONValue] { raw["content"]?.arrayValue ?? [] }
        var stopReason: String? { raw["stop_reason"]?.stringValue }
        var text: String {
            content.compactMap { block in
                block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
            }.joined(separator: " ")
        }
        var toolUses: [(id: String, name: String, input: JSONValue)] {
            content.compactMap { block in
                guard block["type"]?.stringValue == "tool_use",
                      let id = block["id"]?.stringValue,
                      let name = block["name"]?.stringValue else { return nil }
                return (id, name, block["input"] ?? .object([:]))
            }
        }
    }

    let apiKey: String
    let model: String
    let effort: String

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// I modelli Opus, Sonnet 5.5 e Fable accettano il fallback lato server in caso di rifiuto.
    private var supportsFallbacks: Bool {
        model.hasPrefix("claude-opus-5") || model == "claude-sonnet-5-5" || model.hasPrefix("claude-fable-5")
    }

    func send(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> Response {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(4096),
            "system": .string(system),
            "tools": .array(tools),
            "messages": .array(messages),
            "output_config": .object(["effort": .string(effort)]),
            "cache_control": .object(["type": .string("ephemeral")]),
        ]
        if supportsFallbacks { body["fallbacks"] = .string("default") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if supportsFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard status == 200 else {
            let message = json["error"]?["message"]?.stringValue ?? String(data: data, encoding: .utf8) ?? "sconosciuto"
            throw APIError(status: status, message: message)
        }
        return Response(raw: json)
    }
}
