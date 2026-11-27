import Foundation
import SwiftUI

struct TranscriptEntry: Identifiable, Equatable {
    enum Role { case user, claude, system }
    let id = UUID()
    let role: Role
    let text: String
    let date = Date()
}

/// Collega tutte le parti: tapis, voce, Claude, scena di Venezia e gesti.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings: Settings
    let treadmill: TreadmillController
    let voice = VoiceController()
    let gestures = GestureController()
    @ObservationIgnored let venice = VeniceScene()
    @ObservationIgnored private let conversation = ConversationEngine()

    private(set) var transcript: [TranscriptEntry] = []
    var externalDisplayConnected = false
    private(set) var gesturesEnabled = false
    private(set) var banner: String?
    private(set) var forkPending = false
    private(set) var isThinking = false

    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?

    private init() {
        let settings = Settings()
        self.settings = settings
        self.treadmill = TreadmillController(settings: settings)

        venice.speedKmh = { [weak self] in self?.treadmill.state.speedKmh ?? 0 }
        venice.inclinePct = { [weak self] in self?.treadmill.state.inclinePct ?? 0 }
        venice.onForkApproaching = { [weak self] in self?.announceFork() }
        voice.onUtterance = { [weak self] text in self?.handleUtterance(text) }
        voice.onFinishedSpeaking = { [weak self] in self?.resumeListeningIfNeeded() }
        gestures.onGesture = { [weak self] kind in self?.handleGesture(kind) }
        gestures.mirrored = settings.mirrorGestures

        venice.start()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func onLaunch() async {
        await voice.requestPermissions()
        addSystem("Pronto. Alza la mano o tocca \"Parla\" per parlare con Claude.")
        resumeListeningIfNeeded()
    }

    // MARK: Azioni dall'interfaccia

    func toggleGestures() {
        gesturesEnabled.toggle()
        if gesturesEnabled {
            gestures.mirrored = settings.mirrorGestures
            gestures.start()
        } else {
            gestures.stop()
        }
    }

    func talkButton() {
        switch voice.phase {
        case .listening: voice.stopListening()
        case .speaking: voice.stopSpeaking(); voice.startListening()
        default: voice.startListening()
        }
    }

    func newConversation() {
        conversation.reset()
        transcript.removeAll()
        addSystem("Nuova conversazione.")
    }

    // MARK: Voce

    private func handleUtterance(_ text: String) {
        let lower = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)

        // Comandi immediati, senza passare da Claude (più veloci e sicuri).
        let stopWords: Set<String> = ["stop", "fermati", "basta", "alt", "rallenta"]
        if words.count <= 3, words.contains(where: { stopWords.contains($0) }) {
            transcript.append(TranscriptEntry(role: .user, text: text))
            treadmill.slowDown()
            say("Rallento al passo.")
            return
        }
        if treadmill.pending != nil, words.count <= 3 {
            let yes: Set<String> = ["sì", "si", "conferma", "confermo", "ok", "okay", "vai", "certo"]
            let no: Set<String> = ["no", "annulla", "lascia"]
            if words.contains(where: { yes.contains($0) }) {
                transcript.append(TranscriptEntry(role: .user, text: text))
                say(treadmill.confirmPending() ?? "Nessuna richiesta da confermare.")
                return
            }
            if words.contains(where: { no.contains($0) }) {
                transcript.append(TranscriptEntry(role: .user, text: text))
                treadmill.cancelPending()
                say("Va bene, lascio così.")
                return
            }
        }
        if forkPending, words.count <= 3 {
            if words.contains("sinistra") || words.contains("canali") { chooseFork(.canals); return }
            if words.contains("destra") || words.contains("calli") { chooseFork(.calli); return }
        }
        askClaude(text)
    }

    private func askClaude(_ text: String) {
        transcript.append(TranscriptEntry(role: .user, text: text))
        isThinking = true
        voice.setThinking()
        let context = ConversationEngine.ToolContext(
            status: { [weak self] in self?.statusText() ?? "" },
            setSpeed: { [weak self] v in self?.treadmill.requestSpeed(v, from: .claude) ?? "" },
            setIncline: { [weak self] v in self?.treadmill.requestIncline(v, from: .claude) ?? "" },
            slowDown: { [weak self] in self?.treadmill.slowDown(); return "Rallentato a 3 km/h, pendenza 0%." },
            showSign: { [weak self] title, text, style in
                self?.venice.showSign(title: title, text: text, style: SignFactory.Style(rawValue: style) ?? .info)
                return "Insegna mostrata più avanti sul percorso."
            }
        )
        Task {
            do {
                let reply = try await conversation.send(text, settings: settings, context: context)
                isThinking = false
                say(reply.isEmpty ? "Fatto." : reply)
            } catch {
                isThinking = false
                addSystem(error.localizedDescription)
                say("Non riesco a raggiungere Claude in questo momento.")
            }
        }
    }

    private func say(_ text: String) {
        transcript.append(TranscriptEntry(role: .claude, text: text))
        if settings.speakReplies {
            voice.speak(text)
        } else {
            voice.markIdle()
            resumeListeningIfNeeded()
        }
    }

    private func resumeListeningIfNeeded() {
        if settings.continuousListening, voice.phase == .idle, !isThinking {
            voice.startListening()
        }
    }

    // MARK: Gesti

    private func handleGesture(_ kind: GestureKind) {
        guard gesturesEnabled else { return }
        let speed = treadmill.state.speedKmh
        if kind != .openPalm, speed > settings.gestureSpeedLimitKmh {
            showBanner(String(format: "Gesti in pausa sopra %.0f km/h: usa la voce", settings.gestureSpeedLimitKmh))
            return
        }
        showBanner(kind.rawValue)
        switch kind {
        case .raisedHand:
            if voice.phase == .speaking { voice.stopSpeaking() }
            voice.startListening()
        case .thumbsUp:
            if let result = treadmill.confirmPending() { say(result) }
        case .thumbsDown:
            if treadmill.pending != nil { treadmill.cancelPending(); say("Annullato.") }
            else if voice.phase == .speaking { voice.stopSpeaking() }
        case .openPalm:
            treadmill.slowDown()
            say("Rallento al passo.")
        case .pointLeft:
            if forkPending { chooseFork(.canals) }
            else { say(treadmill.requestSpeed(max(treadmill.targetSpeed, speed) - 0.5, from: .gesture)) }
        case .pointRight:
            if forkPending { chooseFork(.calli) }
            else { say(treadmill.requestSpeed(max(treadmill.targetSpeed, speed) + 0.5, from: .gesture)) }
        }
    }

    // MARK: Bivi

    private func announceFork() {
        showBanner("Bivio più avanti: a sinistra i canali, a destra le calli")
        if settings.speakReplies, voice.phase == .idle {
            say("Bivio più avanti: a sinistra canali, a destra calli.")
        }
    }

    private func chooseFork(_ route: VeniceScene.RoutePreference) {
        forkPending = false
        venice.chooseRoute(route)
        say(route == .canals ? "Andiamo verso i canali." : "Andiamo per le calli.")
    }

    // MARK: Utilità

    func statusText() -> String {
        let s = treadmill.state
        var parts = [
            String(format: "velocità %.1f km/h", s.speedKmh),
            String(format: "pendenza %.0f%%", s.inclinePct),
            String(format: "distanza %.2f km", s.distanceM / 1000),
            "tempo \(s.elapsedText)",
            "passo \(s.paceText) min/km",
        ]
        if let hr = s.heartRate { parts.append("frequenza cardiaca \(hr) bpm") }
        if let kcal = s.energyKcal { parts.append(String(format: "%.0f kcal", kcal)) }
        parts.append(String(format: "limiti: velocità max %.1f km/h, pendenza max %.0f%%", settings.maxSpeedKmh, settings.maxInclinePct))
        if !treadmill.canControl { parts.append("il tapis non accetta comandi (solo lettura)") }
        return parts.joined(separator: ", ")
    }

    private func addSystem(_ text: String) {
        transcript.append(TranscriptEntry(role: .system, text: text))
    }

    private func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    private func tick() {
        treadmill.expirePendingIfNeeded()
        let lantern: VeniceScene.LanternState
        switch voice.phase {
        case .listening: lantern = .listening
        case .thinking: lantern = .thinking
        case .speaking: lantern = .speaking
        case .idle: lantern = isThinking ? .thinking : .idle
        }
        venice.setLantern(lantern)
        if forkPending != venice.forkOpen { forkPending = venice.forkOpen }
    }
}
