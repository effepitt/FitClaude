import CoreBluetooth
import Foundation

/// Tapis vero tramite il profilo standard Bluetooth "Fitness Machine Service" (FTMS, 0x1826).
/// Legge Treadmill Data (0x2ACD) e, se il tapis lo permette, comanda velocità e pendenza
/// con il Fitness Machine Control Point (0x2AD9).
///
/// Mostra anche un registro diagnostico di tutti i servizi trovati: se il Toorx non usa FTMS,
/// il registro dice cosa espone, così possiamo adattare il protocollo.
final class FTMSTreadmill: NSObject, TreadmillSource {
    struct DiscoveredPeripheral: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let advertisesFTMS: Bool
    }

    static let ftmsService = CBUUID(string: "1826")
    static let treadmillData = CBUUID(string: "2ACD")
    static let controlPoint = CBUUID(string: "2AD9")
    static let machineStatus = CBUUID(string: "2ADA")
    static let speedRange = CBUUID(string: "2AD4")
    static let inclineRange = CBUUID(string: "2AD5")
    static let heartRateService = CBUUID(string: "180D")

    var displayName: String { peripheral?.name ?? "Tapis Bluetooth" }
    private(set) var connection: TreadmillConnection = .disconnected {
        didSet { onConnectionChange?(connection) }
    }
    private(set) var canControl = false
    var onUpdate: ((TreadmillState) -> Void)?
    var onConnectionChange: ((TreadmillConnection) -> Void)?
    var onDiscoveredChange: (([DiscoveredPeripheral]) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private(set) var discovered: [DiscoveredPeripheral] = [] {
        didSet { onDiscoveredChange?(discovered) }
    }
    private(set) var supportedSpeed: ClosedRange<Double>?
    private(set) var supportedIncline: ClosedRange<Double>?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var controlPointChar: CBCharacteristic?
    private var hasControl = false
    private var pendingCommands: [Data] = []
    private var state = TreadmillState()
    private var wantsScan = false

    // MARK: TreadmillSource

    func activate() {
        wantsScan = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            startScan()
        }
    }

    func deactivate() {
        wantsScan = false
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        controlPointChar = nil
        hasControl = false
        canControl = false
        connection = .disconnected
    }

    func connect(to id: UUID) {
        guard let central, let target = peripheralsByID[id] else { return }
        central.stopScan()
        peripheral = target
        target.delegate = self
        connection = .connecting(target.name ?? "tapis")
        log("Collegamento a \(target.name ?? id.uuidString)")
        central.connect(target)
    }

    func setTargetSpeed(_ kmh: Double) {
        let value = UInt16(max(0, min(kmh, 30)) * 100 + 0.5)
        var data = Data([0x02])
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        send(data)
    }

    func setTargetIncline(_ pct: Double) {
        let value = Int16((max(-10, min(pct, 30)) * 10).rounded())
        var data = Data([0x03])
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        send(data)
    }

    func start() { send(Data([0x07])) }
    func pause() { send(Data([0x08, 0x02])) }

    // MARK: Internals

    private func startScan() {
        guard let central, central.state == .poweredOn, wantsScan else { return }
        discovered = []
        peripheralsByID = [:]
        connection = .scanning
        log("Ricerca dispositivi Bluetooth…")
        // Nessun filtro: alcuni tapis non annunciano 0x1826 nella pubblicità.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func send(_ command: Data) {
        guard let peripheral, let controlPointChar else {
            log("Comando ignorato: control point non disponibile")
            return
        }
        if !hasControl {
            pendingCommands.append(command)
            requestControl()
            return
        }
        peripheral.writeValue(command, for: controlPointChar, type: .withResponse)
    }

    private func requestControl() {
        guard let peripheral, let controlPointChar else { return }
        peripheral.writeValue(Data([0x00]), for: controlPointChar, type: .withResponse)
    }

    private func log(_ message: String) {
        onDiagnostic?(message)
    }

    /// Decodifica la caratteristica Treadmill Data (0x2ACD) secondo la specifica FTMS 1.0.
    static func parseTreadmillData(_ data: Data, into state: inout TreadmillState) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let flags = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var i = 2

        func u8() -> UInt8? { guard i + 1 <= bytes.count else { return nil }; defer { i += 1 }; return bytes[i] }
        func u16() -> UInt16? { guard i + 2 <= bytes.count else { return nil }; defer { i += 2 }; return UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        func s16() -> Int16? { u16().map { Int16(bitPattern: $0) } }
        func u24() -> UInt32? {
            guard i + 3 <= bytes.count else { return nil }
            defer { i += 3 }
            return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16
        }
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }

        // Bit 0 = "More Data": se è 0 la velocità istantanea è presente.
        if !has(0), let speed = u16() { state.speedKmh = Double(speed) / 100 }
        if has(1) { _ = u16() }                                   // velocità media
        if has(2), let distance = u24() { state.distanceM = Double(distance) }
        if has(3) {                                               // pendenza + angolo rampa
            if let incline = s16() { state.inclinePct = Double(incline) / 10 }
            _ = s16()
        }
        if has(4) { _ = u16(); _ = u16() }                        // dislivello + / -
        if has(5) { _ = u8() }                                    // passo istantaneo
        if has(6) { _ = u8() }                                    // passo medio
        if has(7) {                                               // energia
            if let total = u16(), total != 0xFFFF { state.energyKcal = Double(total) }
            _ = u16(); _ = u8()
        }
        if has(8), let hr = u8(), hr > 0 { state.heartRate = Int(hr) }
        if has(9) { _ = u8() }                                    // MET
        if has(10), let elapsed = u16() { state.elapsedS = Double(elapsed) }
        if has(11) { _ = u16() }                                  // tempo rimanente
        if has(12) { _ = s16(); _ = s16() }                       // forza e potenza
    }

    private static func parseRange(_ data: Data, scale: Double, signed: Bool) -> ClosedRange<Double>? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let rawMin = UInt16(b[0]) | UInt16(b[1]) << 8
        let rawMax = UInt16(b[2]) | UInt16(b[3]) << 8
        let lo = signed ? Double(Int16(bitPattern: rawMin)) : Double(rawMin)
        let hi = signed ? Double(Int16(bitPattern: rawMax)) : Double(rawMax)
        guard hi >= lo else { return nil }
        return (lo * scale)...(hi * scale)
    }
}

extension FTMSTreadmill: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startScan()
        case .unauthorized: connection = .failed("permesso Bluetooth negato")
        case .poweredOff: connection = .failed("Bluetooth spento")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        guard let name, !name.isEmpty else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isFTMS = services.contains(Self.ftmsService)
        peripheralsByID[peripheral.identifier] = peripheral
        let item = DiscoveredPeripheral(id: peripheral.identifier, name: name, rssi: RSSI.intValue, advertisesFTMS: isFTMS)
        if let index = discovered.firstIndex(where: { $0.id == item.id }) {
            discovered[index] = item
        } else {
            discovered.append(item)
            log("Trovato: \(name)\(isFTMS ? " (FTMS)" : "")  RSSI \(RSSI)")
        }
        // Collegamento automatico al primo dispositivo che annuncia FTMS.
        if isFTMS, self.peripheral == nil {
            connect(to: peripheral.identifier)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Collegato. Lettura dei servizi…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connection = .failed(error?.localizedDescription ?? "collegamento fallito")
        self.peripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnesso\(error.map { ": \($0.localizedDescription)" } ?? "")")
        self.peripheral = nil
        controlPointChar = nil
        hasControl = false
        canControl = false
        connection = .disconnected
        if wantsScan { startScan() }
    }
}

extension FTMSTreadmill: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        log("Servizi: " + services.map { $0.uuid.uuidString }.joined(separator: ", "))
        if !services.contains(where: { $0.uuid == Self.ftmsService }) {
            log("Questo dispositivo NON espone FTMS (0x1826). Manda questo registro a Claude.")
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        log("  \(service.uuid.uuidString): " + chars.map { $0.uuid.uuidString }.joined(separator: ", "))
        for char in chars {
            switch char.uuid {
            case Self.treadmillData:
                peripheral.setNotifyValue(true, for: char)
                connection = .connected(peripheral.name ?? "Tapis FTMS")
            case Self.controlPoint:
                controlPointChar = char
                peripheral.setNotifyValue(true, for: char) // le risposte arrivano come indication
            case Self.machineStatus:
                peripheral.setNotifyValue(true, for: char)
            case Self.speedRange, Self.inclineRange:
                peripheral.readValue(for: char)
            default:
                if service.uuid == Self.heartRateService, char.uuid == CBUUID(string: "2A37") {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.controlPoint, error == nil {
            canControl = true
            log("Control point attivo: proviamo a prendere il controllo")
            requestControl()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.treadmillData:
            Self.parseTreadmillData(data, into: &state)
            onUpdate?(state)
        case Self.controlPoint:
            handleControlPointResponse(data)
        case Self.speedRange:
            supportedSpeed = Self.parseRange(data, scale: 0.01, signed: false)
            if let r = supportedSpeed { log(String(format: "Velocità supportata: %.1f–%.1f km/h", r.lowerBound, r.upperBound)) }
        case Self.inclineRange:
            supportedIncline = Self.parseRange(data, scale: 0.1, signed: true)
            if let r = supportedIncline { log(String(format: "Pendenza supportata: %.1f–%.1f %%", r.lowerBound, r.upperBound)) }
        case CBUUID(string: "2A37"):
            let b = [UInt8](data)
            if b.count >= 2 {
                let hr = (b[0] & 0x01) != 0 && b.count >= 3 ? Int(UInt16(b[1]) | UInt16(b[2]) << 8) : Int(b[1])
                state.heartRate = hr
                onUpdate?(state)
            }
        default:
            break
        }
    }

    private func handleControlPointResponse(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == 0x80 else { return }
        let opcode = b[1], result = b[2]
        let resultText: String
        switch result {
        case 0x01: resultText = "ok"
        case 0x02: resultText = "comando non supportato"
        case 0x03: resultText = "parametro non valido"
        case 0x04: resultText = "operazione fallita"
        case 0x05: resultText = "controllo non permesso"
        default: resultText = "codice \(result)"
        }
        log(String(format: "Risposta comando 0x%02X: %@", opcode, resultText))
        if opcode == 0x00 {
            hasControl = (result == 0x01)
            if hasControl, let peripheral, let controlPointChar {
                let queued = pendingCommands
                pendingCommands = []
                for command in queued { peripheral.writeValue(command, for: controlPointChar, type: .withResponse) }
            } else if !hasControl {
                canControl = false
                pendingCommands = []
                log("Il tapis non accetta comandi: resta la sola lettura dei dati.")
            }
        } else if result == 0x05 {
            hasControl = false
        } else if result == 0x02, opcode == 0x02 || opcode == 0x03 {
            log("Il tapis non accetta comandi di \(opcode == 0x02 ? "velocità" : "pendenza").")
        }
    }
}
