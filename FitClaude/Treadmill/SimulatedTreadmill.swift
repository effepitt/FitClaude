import Foundation

/// Tapis simulato: serve per provare scena, voce e gesti prima che arrivi il modulo Bluetooth.
/// Velocità e pendenza cambiano gradualmente, come su un tapis vero.
final class SimulatedTreadmill: TreadmillSource {
    let displayName = "Simulatore"
    private(set) var connection: TreadmillConnection = .disconnected
    let canControl = true
    var onUpdate: ((TreadmillState) -> Void)?
    var onConnectionChange: ((TreadmillConnection) -> Void)?

    private var state = TreadmillState()
    private var targetSpeed: Double = 0
    private var targetIncline: Double = 0
    private var running = false
    private var timer: Timer?
    private let tick: TimeInterval = 0.1
    private let speedRampPerSecond = 0.6     // km/h al secondo
    private let inclineRampPerSecond = 0.5   // % al secondo

    func activate() {
        connection = .connected(displayName)
        onConnectionChange?(connection)
        timer?.invalidate()
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onUpdate?(state)
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        connection = .disconnected
        onConnectionChange?(connection)
    }

    func setTargetSpeed(_ kmh: Double) {
        targetSpeed = max(0, kmh)
        if targetSpeed > 0 { running = true }
    }

    func setTargetIncline(_ pct: Double) {
        targetIncline = max(0, pct)
    }

    func start() {
        running = true
        if targetSpeed < 0.8 { targetSpeed = 3.0 }
    }

    func pause() {
        targetSpeed = 0
    }

    private func step() {
        state.speedKmh = approach(state.speedKmh, targetSpeed, speedRampPerSecond * tick)
        state.inclinePct = approach(state.inclinePct, targetIncline, inclineRampPerSecond * tick)
        if state.speedKmh > 0.05 {
            state.elapsedS += tick
            state.distanceM += state.speedKmh / 3.6 * tick
            // Stima grossolana: ~1 kcal per kg per km, peso medio 80 kg, +10% per ogni 1% di pendenza
            let km = state.speedKmh / 3600 * tick
            state.energyKcal = (state.energyKcal ?? 0) + km * 80 * (1 + state.inclinePct * 0.1)
        } else if targetSpeed == 0 {
            running = false
        }
        onUpdate?(state)
    }

    private func approach(_ value: Double, _ target: Double, _ maxStep: Double) -> Double {
        if abs(target - value) <= maxStep { return target }
        return value + (target > value ? maxStep : -maxStep)
    }
}
