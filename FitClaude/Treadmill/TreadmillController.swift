import Foundation

/// Gestisce la sorgente del tapis (simulatore o Bluetooth) e applica le regole di sicurezza
/// a ogni comando che arriva da Claude o dai gesti.
///
/// Regole:
/// - velocità e pendenza restano sempre entro i massimi delle Impostazioni;
/// - le diminuzioni si applicano subito;
/// - gli aumenti chiesti da Claude o dai gesti vanno confermati (pollice su, "sì", o pulsante)
///   e sono limitati a +2 km/h e +3% per volta;
/// - la chiave magnetica del tapis resta comunque lo stop d'emergenza.
@Observable
final class TreadmillController {
    enum SourceKind: String, CaseIterable, Identifiable {
        case simulator = "Simulatore"
        case bluetooth = "Tapis Bluetooth"
        var id: String { rawValue }
    }

    enum Origin { case user, claude, gesture }

    struct PendingChange: Equatable {
        enum Kind { case speed, incline }
        let kind: Kind
        let value: Double
        let createdAt: Date

        var description: String {
            switch kind {
            case .speed: return String(format: "velocità a %.1f km/h", value)
            case .incline: return String(format: "pendenza al %.0f%%", value)
            }
        }
    }

    private(set) var sourceKind: SourceKind = .simulator
    private(set) var state = TreadmillState()
    private(set) var connection: TreadmillConnection = .disconnected
    private(set) var discovered: [FTMSTreadmill.DiscoveredPeripheral] = []
    private(set) var diagnostics: [String] = []
    private(set) var pending: PendingChange?
    private(set) var targetSpeed: Double = 0
    private(set) var targetIncline: Double = 0

    var canControl: Bool { source.canControl }

    private let settings: Settings
    private var source: TreadmillSource
    private let simulator = SimulatedTreadmill()
    private let bluetooth = FTMSTreadmill()
    private let maxSpeedStep = 2.0
    private let maxInclineStep = 3.0
    private let pendingLifetime: TimeInterval = 15

    init(settings: Settings) {
        self.settings = settings
        self.source = simulator
        wire(simulator)
        wire(bluetooth)
        bluetooth.onDiscoveredChange = { [weak self] list in self?.discovered = list }
        bluetooth.onDiagnostic = { [weak self] line in self?.addDiagnostic(line) }
        simulator.activate()
    }

    func switchSource(to kind: SourceKind) {
        guard kind != sourceKind else { return }
        source.deactivate()
        sourceKind = kind
        source = (kind == .simulator) ? simulator : bluetooth
        state = TreadmillState()
        source.activate()
    }

    func connectBluetooth(to id: UUID) { bluetooth.connect(to: id) }

    // MARK: Comandi

    /// Restituisce una frase che descrive cosa è successo (va anche a Claude come risultato dello strumento).
    @discardableResult
    func requestSpeed(_ kmh: Double, from origin: Origin) -> String {
        guard source.canControl else { return "Il tapis non accetta comandi: cambia la velocità dalla console." }
        var value = min(max(kmh, 0), settings.maxSpeedKmh)
        let current = max(targetSpeed, state.speedKmh)
        if origin != .user, value > current + 0.05 {
            value = min(value, current + maxSpeedStep)
            pending = PendingChange(kind: .speed, value: value, createdAt: Date())
            return String(format: "In attesa di conferma: velocità a %.1f km/h (pollice su o \"sì\").", value)
        }
        apply(.speed, value)
        if value < kmh - 0.05 { return String(format: "Velocità impostata a %.1f km/h (limite massimo).", value) }
        return String(format: "Velocità impostata a %.1f km/h.", value)
    }

    @discardableResult
    func requestIncline(_ pct: Double, from origin: Origin) -> String {
        guard source.canControl else { return "Il tapis non accetta comandi: cambia la pendenza dalla console." }
        var value = min(max(pct, 0), settings.maxInclinePct)
        let current = max(targetIncline, state.inclinePct)
        if origin != .user, value > current + 0.05 {
            value = min(value, current + maxInclineStep)
            pending = PendingChange(kind: .incline, value: value, createdAt: Date())
            return String(format: "In attesa di conferma: pendenza al %.0f%% (pollice su o \"sì\").", value)
        }
        apply(.incline, value)
        return String(format: "Pendenza impostata al %.0f%%.", value)
    }

    @discardableResult
    func confirmPending() -> String? {
        guard let change = pending else { return nil }
        pending = nil
        guard Date().timeIntervalSince(change.createdAt) < pendingLifetime else { return "Richiesta scaduta." }
        apply(change.kind, change.value)
        return "Confermato: \(change.description)."
    }

    func cancelPending() { pending = nil }

    /// Palmo aperto / "alt": rallenta al passo (3 km/h) e azzera la pendenza. Non ferma di colpo.
    func slowDown() {
        pending = nil
        guard source.canControl else { return }
        apply(.speed, min(max(targetSpeed, state.speedKmh), 3.0))
        apply(.incline, 0)
    }

    func start() {
        source.start()
        if targetSpeed < 0.8 { targetSpeed = 3.0; source.setTargetSpeed(3.0) }
    }

    func pause() {
        pending = nil
        targetSpeed = 0
        source.pause()
    }

    func expirePendingIfNeeded() {
        if let p = pending, Date().timeIntervalSince(p.createdAt) > pendingLifetime { pending = nil }
    }

    // MARK: Privato

    private func apply(_ kind: PendingChange.Kind, _ value: Double) {
        switch kind {
        case .speed:
            targetSpeed = value
            source.setTargetSpeed(value)
        case .incline:
            targetIncline = value
            source.setTargetIncline(value)
        }
    }

    private func wire(_ s: TreadmillSource) {
        s.onUpdate = { [weak self, weak s] newState in
            guard let self, let s, s === self.source else { return }
            self.state = newState
        }
        s.onConnectionChange = { [weak self, weak s] conn in
            guard let self, let s, s === self.source else { return }
            self.connection = conn
        }
    }

    private func addDiagnostic(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        diagnostics.append("\(time)  \(line)")
        if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
    }
}
