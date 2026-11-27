import AVFoundation
import Foundation
import UIKit
import Vision

enum GestureKind: String {
    case raisedHand = "Mano alzata"
    case pointLeft = "Braccio a sinistra"
    case pointRight = "Braccio a destra"
    case thumbsUp = "Pollice su"
    case thumbsDown = "Pollice giù"
    case openPalm = "Palmo aperto"
}

/// Riconosce i gesti con la fotocamera frontale (Vision: posa del corpo e della mano).
/// Le immagini restano sull'iPad e non vengono salvate.
///
/// Ogni gesto va tenuto circa mezzo secondo; dopo un gesto c'è una pausa di 1,5 s.
@Observable
final class GestureController: NSObject {
    private(set) var isRunning = false
    private(set) var bodyVisible = false
    private(set) var lastGesture: GestureKind?
    private(set) var lastGestureDate: Date?
    private(set) var candidate: GestureKind?
    private(set) var cameraName = ""
    private(set) var error: String?

    /// Chiamato sul thread principale quando un gesto è confermato.
    @ObservationIgnored var onGesture: ((GestureKind) -> Void)?
    /// Inverte destra e sinistra se la fotocamera risulta specchiata al contrario.
    @ObservationIgnored var mirrored = false

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "fitclaude.gestures")
    @ObservationIgnored private let output = AVCaptureVideoDataOutput()
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var frameCounter = 0
    @ObservationIgnored private var streak: (kind: GestureKind?, count: Int) = (nil, 0)
    @ObservationIgnored private var cooldownUntil = Date.distantPast
    @ObservationIgnored private var lastEmitted: GestureKind?
    @ObservationIgnored private let framesToConfirm = 5      // ~0,5 s a 10 analisi al secondo
    @ObservationIgnored private let cooldown: TimeInterval = 1.5

    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    func start() {
        guard !isRunning else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.error = "Permesso fotocamera negato (Impostazioni iPad)." }
                return
            }
            self.videoQueue.async { self.configureAndRun() }
        }
    }

    func stop() {
        videoQueue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async { self?.isRunning = false; self?.bodyVisible = false }
        }
    }

    private func configureAndRun() {
        if session.inputs.isEmpty {
            // Center Stage ritaglia l'immagine: lo disattiviamo per avere tutto il campo dell'ultra-grandangolo.
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false

            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTrueDepthCamera],
                mediaType: .video, position: .front)
            guard let device = discovery.devices.first,
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.error = "Fotocamera frontale non disponibile." }
                return
            }
            self.device = device
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            if session.canAddInput(input) { session.addInput(input) }
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            selectWidestFormat(device)
            let name = device.localizedName
            DispatchQueue.main.async {
                self.cameraName = name
                self.setUpRotation(for: device)
            }
        }
        session.startRunning()
        DispatchQueue.main.async { self.isRunning = true; self.error = nil }
    }

    /// Sceglie il formato con il campo visivo più ampio, fino a 1920 px di larghezza.
    private func selectWidestFormat(_ device: AVCaptureDevice) {
        let candidates = device.formats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width <= 1920 && dims.width >= 960
        }
        guard let best = candidates.max(by: { $0.videoFieldOfView < $1.videoFieldOfView }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.error = "Formato fotocamera: \(error.localizedDescription)" }
        }
    }

    /// Ruota i fotogrammi secondo l'orientamento dell'iPad, così "su" è sempre in alto.
    private func setUpRotation(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            self?.videoQueue.async { self?.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true   // come uno specchio: la tua destra è a destra
        }
    }

    // MARK: Classificazione

    private func classify(body: VNHumanBodyPoseObservation?, hands: [VNHumanHandPoseObservation]) -> GestureKind? {
        var shoulderY: CGFloat?
        if let body, let points = try? body.recognizedPoints(.all) {
            func p(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let pt = points[name], pt.confidence > 0.3 else { return nil }
                return pt.location   // normalizzato, origine in basso a sinistra
            }
            let ls = p(.leftShoulder), rs = p(.rightShoulder)
            if let ls, let rs {
                let sw = max(abs(ls.x - rs.x), 0.08)
                let sy = (ls.y + rs.y) / 2
                shoulderY = sy
                let leftEdge = min(ls.x, rs.x), rightEdge = max(ls.x, rs.x)
                let wrists = [p(.leftWrist), p(.rightWrist)].compactMap { $0 }

                // Mani: hanno la precedenza (pollice, palmo)
                if let handGesture = classifyHands(hands, shoulderY: sy) { return handGesture }

                for w in wrists {
                    // Mano alzata vicino alla spalla
                    if w.y > sy + sw * 0.6, w.x > leftEdge - sw * 0.8, w.x < rightEdge + sw * 0.8 {
                        return .raisedHand
                    }
                }
                for w in wrists where abs(w.y - sy) < sw * 0.9 {
                    // Mano o avambraccio aperti di lato, all'altezza della spalla
                    if w.x > rightEdge + sw * 0.75 { return mirrored ? .pointLeft : .pointRight }
                    if w.x < leftEdge - sw * 0.75 { return mirrored ? .pointRight : .pointLeft }
                }
                return nil
            }
        }
        return classifyHands(hands, shoulderY: shoulderY)
    }

    private func classifyHands(_ hands: [VNHumanHandPoseObservation], shoulderY: CGFloat?) -> GestureKind? {
        for hand in hands {
            guard let pts = try? hand.recognizedPoints(.all),
                  let wrist = pts[.wrist], wrist.confidence > 0.3 else { continue }
            func loc(_ j: VNHumanHandPoseObservation.JointName) -> CGPoint? {
                guard let pt = pts[j], pt.confidence > 0.3 else { return nil }
                return pt.location
            }
            func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
            let w = wrist.location
            let fingers: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] =
                [(.indexTip, .indexMCP), (.middleTip, .middleMCP), (.ringTip, .ringMCP), (.littleTip, .littleMCP)]
            var extended = 0, folded = 0
            var fingerTipsY: [CGFloat] = []
            for (tipName, mcpName) in fingers {
                guard let tip = loc(tipName), let mcp = loc(mcpName) else { continue }
                fingerTipsY.append(tip.y)
                let ratio = dist(tip, w) / max(dist(mcp, w), 0.001)
                if ratio > 1.6 { extended += 1 } else if ratio < 1.25 { folded += 1 }
            }
            guard let thumbTip = loc(.thumbTip), let thumbIP = loc(.thumbIP), let thumbMP = loc(.thumbMP) else { continue }
            let handSize = dist(loc(.middleMCP) ?? w, w)
            guard handSize > 0.02 else { continue }   // mano troppo piccola/lontana

            if folded >= 3, let highest = fingerTipsY.max(), let lowest = fingerTipsY.min() {
                if thumbTip.y > thumbIP.y, thumbIP.y > thumbMP.y, thumbTip.y > highest + handSize * 0.4 { return .thumbsUp }
                if thumbTip.y < thumbIP.y, thumbIP.y < thumbMP.y, thumbTip.y < lowest - handSize * 0.4 { return .thumbsDown }
            }
            if extended >= 4 {
                // Palmo "alt" all'altezza del petto (non sopra la spalla, quello è "mano alzata")
                if let sy = shoulderY, w.y > sy { continue }
                return .openPalm
            }
        }
        return nil
    }

    private func handle(_ kind: GestureKind?) {
        if kind == streak.kind {
            streak.count += 1
        } else {
            streak = (kind, 1)
            if kind == nil { lastEmitted = nil }
        }
        DispatchQueue.main.async { self.candidate = kind }
        guard let kind, streak.count == framesToConfirm, Date() > cooldownUntil, kind != lastEmitted else { return }
        lastEmitted = kind
        cooldownUntil = Date().addingTimeInterval(cooldown)
        DispatchQueue.main.async {
            self.lastGesture = kind
            self.lastGestureDate = Date()
            self.onGesture?(kind)
        }
    }
}

extension GestureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % 3 == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // I fotogrammi sono già ruotati e specchiati dalla connessione: orientamento .up
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([bodyRequest, handRequest])
        } catch {
            return
        }
        let body = bodyRequest.results?.first
        let hands = handRequest.results ?? []
        let visible = body != nil
        DispatchQueue.main.async { if self.bodyVisible != visible { self.bodyVisible = visible } }
        handle(classify(body: body, hands: hands))
    }
}
