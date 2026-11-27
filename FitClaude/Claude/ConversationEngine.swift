import Foundation

/// La conversazione con Claude: manda il testo trascritto, esegue gli strumenti (tapis, cartelli)
/// e restituisce la risposta da leggere ad alta voce.
@MainActor
final class ConversationEngine {
    struct ToolContext {
        let status: () -> String
        let setSpeed: (Double) -> String
        let setIncline: (Double) -> String
        let slowDown: () -> String
        let showSign: (_ title: String, _ text: String, _ style: String) -> String
    }

    private var messages: [JSONValue] = []
    private let maxToolRounds = 6

    func reset() { messages = [] }

    func send(_ userText: String, settings: Settings, context: ToolContext) async throws -> String {
        guard !settings.apiKey.isEmpty else {
            return "Manca la chiave API di Claude: inseriscila nelle impostazioni."
        }
        let client = ClaudeClient(apiKey: settings.apiKey, model: settings.model, effort: settings.effort)
        let system = Self.systemPrompt(name: settings.userName)

        let userContent: [JSONValue] = [
            .object(["type": .string("text"), "text": .string(userText)]),
            .object(["type": .string("text"), "text": .string("[Dati attuali del tapis: \(context.status())]")]),
        ]
        messages.append(.object(["role": .string("user"), "content": .array(userContent)]))

        var spoken: [String] = []
        for _ in 0..<maxToolRounds {
            let response = try await client.send(system: system, tools: Self.tools, messages: messages)
            // Il contenuto dell'assistente va rimandato esattamente com'è (thinking compreso).
            messages.append(.object(["role": .string("assistant"), "content": .array(response.content)]))
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { spoken.append(text) }

            if response.stopReason == "refusal" {
                return spoken.isEmpty ? "Su questo non posso aiutarti." : spoken.joined(separator: " ")
            }
            guard response.stopReason == "tool_use" else { break }

            var results: [JSONValue] = []
            for call in response.toolUses {
                let output = run(call.name, call.input, context)
                results.append(.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(call.id),
                    "content": .string(output),
                ]))
            }
            messages.append(.object(["role": .string("user"), "content": .array(results)]))
        }
        return spoken.joined(separator: " ")
    }

    private func run(_ name: String, _ input: JSONValue, _ context: ToolContext) -> String {
        switch name {
        case "get_treadmill_status":
            return context.status()
        case "set_speed":
            guard let v = input["speed_kmh"]?.doubleValue else { return "Parametro speed_kmh mancante." }
            return context.setSpeed(v)
        case "set_incline":
            guard let v = input["incline_pct"]?.doubleValue else { return "Parametro incline_pct mancante." }
            return context.setIncline(v)
        case "slow_down":
            return context.slowDown()
        case "show_sign":
            return context.showSign(input["title"]?.stringValue ?? "",
                                    input["text"]?.stringValue ?? "",
                                    input["style"]?.stringValue ?? "info")
        default:
            return "Strumento sconosciuto: \(name)"
        }
    }

    static func systemPrompt(name: String) -> String {
        """
        Sei FitClaude, compagno di allenamento di \(name). \(name) cammina o corre su un tapis roulant \
        (Toorx Mirage C80) davanti a una grande TV che mostra una passeggiata in soggettiva tra le calli \
        e i canali di Venezia. Ti parla con gli AirPods; le tue risposte vengono lette ad alta voce.

        Come rispondere:
        - Sempre in italiano, tono naturale e incoraggiante, come un amico che corre accanto.
        - Frasi brevi: di solito una o due, al massimo tre. \(name) sta facendo fatica e ascolta mentre si muove.
        - Niente elenchi, markdown, emoji o simboli: il testo viene pronunciato.
        - Se una risposta è lunga o ha numeri da ricordare, mettila su un cartello con show_sign e dì a voce solo l'essenziale.

        Tapis e sicurezza:
        - A ogni messaggio ricevi i dati attuali del tapis. Usali per commentare ritmo, distanza e tempo quando serve.
        - Puoi cambiare velocità e pendenza con set_speed e set_incline. Le diminuzioni sono immediate. \
        Gli aumenti richiedono la conferma di \(name) (pollice in su o "sì"): se lo strumento risponde \
        "in attesa di conferma", diglielo in poche parole.
        - L'app impone limiti di velocità e pendenza: non cercare di aggirarli.
        - Se \(name) segnala dolore, vertigini, fiato corto anomalo o malessere, usa subito slow_down \
        e suggerisci di fermarsi. Non dare consigli medici.

        Venezia:
        - Puoi raccontare brevi curiosità su calli, campi, ponti e canali, ma solo se \(name) lo gradisce \
        o in una pausa naturale. Non inventare fatti: se non sei sicuro, dillo.
        """
    }

    private static func tool(_ name: String, _ description: String,
                             properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [:]
        schema["type"] = .string("object")
        schema["properties"] = .object(properties)
        schema["additionalProperties"] = .bool(false)
        if !required.isEmpty { schema["required"] = .array(required.map { JSONValue.string($0) }) }
        var def: [String: JSONValue] = [:]
        def["name"] = .string(name)
        def["description"] = .string(description)
        def["input_schema"] = .object(schema)
        if !required.isEmpty { def["strict"] = .bool(true) }
        return .object(def)
    }

    private static func prop(_ type: String, _ description: String, enumValues: [String]? = nil) -> JSONValue {
        var p: [String: JSONValue] = ["type": .string(type), "description": .string(description)]
        if let enumValues { p["enum"] = .array(enumValues.map { JSONValue.string($0) }) }
        return .object(p)
    }

    static let tools: [JSONValue] = [
        tool("get_treadmill_status",
             "Legge i dati attuali del tapis: velocità, pendenza, distanza, tempo, frequenza cardiaca se disponibile."),
        tool("set_speed",
             "Imposta la velocità del tapis in km/h. Gli aumenti richiedono la conferma dell'utente; l'app applica un limite massimo.",
             properties: ["speed_kmh": prop("number", "Velocità desiderata in km/h, per esempio 6.5")],
             required: ["speed_kmh"]),
        tool("set_incline",
             "Imposta la pendenza del tapis in percentuale. Gli aumenti richiedono la conferma dell'utente; l'app applica un limite massimo.",
             properties: ["incline_pct": prop("number", "Pendenza desiderata in %, per esempio 3")],
             required: ["incline_pct"]),
        tool("slow_down",
             "Rallenta subito al passo (3 km/h) e azzera la pendenza. Da usare se l'utente chiede di fermarsi o segnala malessere."),
        tool("show_sign",
             "Mostra un'insegna nella scena di Venezia, sul muro di una casa lungo il percorso. Per obiettivi, numeri, riepiloghi e curiosità brevi.",
             properties: [
                 "title": prop("string", "Titolo breve, massimo 4 parole"),
                 "text": prop("string", "Testo dell'insegna, massimo 25 parole"),
                 "style": prop("string", "Stile: info, goal (obiettivo) o warning (attenzione)", enumValues: ["info", "goal", "warning"]),
             ],
             required: ["title", "text", "style"]),
    ]
}
