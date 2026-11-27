import Foundation

/// Stato istantaneo del tapis roulant.
struct TreadmillState: Equatable {
    var speedKmh: Double = 0
    var inclinePct: Double = 0
    var distanceM: Double = 0
    var elapsedS: Double = 0
    var heartRate: Int? = nil
    var energyKcal: Double? = nil

    var paceMinPerKm: Double? {
        speedKmh > 0.5 ? 60.0 / speedKmh : nil
    }

    var paceText: String {
        guard let pace = paceMinPerKm else { return "--:--" }
        let minutes = Int(pace)
        let seconds = Int((pace - Double(minutes)) * 60)
        return String(format: "%d:%02d", minutes, seconds)
    }

    var elapsedText: String {
        let total = Int(elapsedS)
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

enum TreadmillConnection: Equatable {
    case disconnected
    case scanning
    case connecting(String)
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "Non collegato"
        case .scanning: return "Ricerca del tapis…"
        case .connecting(let name): return "Collegamento a \(name)…"
        case .connected(let name): return name
        case .failed(let reason): return "Errore: \(reason)"
        }
    }
}

/// Una sorgente di dati del tapis: il simulatore oppure il tapis vero via Bluetooth FTMS.
/// Tutti i callback arrivano sul thread principale.
protocol TreadmillSource: AnyObject {
    var displayName: String { get }
    var connection: TreadmillConnection { get }
    /// true se la sorgente accetta comandi di velocità e pendenza.
    var canControl: Bool { get }
    var onUpdate: ((TreadmillState) -> Void)? { get set }
    var onConnectionChange: ((TreadmillConnection) -> Void)? { get set }

    func activate()
    func deactivate()
    func setTargetSpeed(_ kmh: Double)
    func setTargetIncline(_ pct: Double)
    func start()
    func pause()
}
