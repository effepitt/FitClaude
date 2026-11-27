import Foundation
import Security

/// Impostazioni dell'app. La chiave API sta nel Portachiavi, il resto in UserDefaults.
@Observable
final class Settings {
    private let defaults = UserDefaults.standard

    var apiKey: String {
        didSet { Keychain.save(apiKey, account: "anthropic-api-key") }
    }
    var model: String { didSet { defaults.set(model, forKey: "model") } }
    var effort: String { didSet { defaults.set(effort, forKey: "effort") } }
    /// Velocità massima che Claude o i gesti possono impostare (km/h).
    var maxSpeedKmh: Double { didSet { defaults.set(maxSpeedKmh, forKey: "maxSpeedKmh") } }
    /// Pendenza massima che Claude o i gesti possono impostare (%).
    var maxInclinePct: Double { didSet { defaults.set(maxInclinePct, forKey: "maxInclinePct") } }
    /// Oltre questa velocità i gesti si disattivano (resta solo il palmo "alt").
    var gestureSpeedLimitKmh: Double { didSet { defaults.set(gestureSpeedLimitKmh, forKey: "gestureSpeedLimitKmh") } }
    /// Inverte destra/sinistra nei gesti laterali, se la fotocamera risulta specchiata al contrario.
    var mirrorGestures: Bool { didSet { defaults.set(mirrorGestures, forKey: "mirrorGestures") } }
    /// Ascolto continuo (true) oppure solo dopo "mano alzata" / pulsante (false).
    var continuousListening: Bool { didSet { defaults.set(continuousListening, forKey: "continuousListening") } }
    /// Parla le risposte di Claude (negli AirPods o dalla TV).
    var speakReplies: Bool { didSet { defaults.set(speakReplies, forKey: "speakReplies") } }
    var userName: String { didSet { defaults.set(userName, forKey: "userName") } }

    init() {
        apiKey = Keychain.load(account: "anthropic-api-key") ?? ""
        model = defaults.string(forKey: "model") ?? "claude-opus-5-5"
        effort = defaults.string(forKey: "effort") ?? "low"
        maxSpeedKmh = defaults.object(forKey: "maxSpeedKmh") as? Double ?? 12
        maxInclinePct = defaults.object(forKey: "maxInclinePct") as? Double ?? 10
        gestureSpeedLimitKmh = defaults.object(forKey: "gestureSpeedLimitKmh") as? Double ?? 9
        mirrorGestures = defaults.bool(forKey: "mirrorGestures")
        continuousListening = defaults.bool(forKey: "continuousListening")
        speakReplies = defaults.object(forKey: "speakReplies") as? Bool ?? true
        userName = defaults.string(forKey: "userName") ?? "Fabio"
    }
}

enum Keychain {
    static func save(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "it.fitclaude",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "it.fitclaude",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
