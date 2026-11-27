import AVFoundation
import Foundation
import Speech

/// Ascolto (riconoscimento vocale in italiano, sul dispositivo quando possibile) e voce (sintesi italiana).
/// Una frase finisce dopo ~1,3 secondi di silenzio.
@MainActor
@Observable
final class VoiceController: NSObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    private(set) var phase: Phase = .idle
    private(set) var partialTranscript = ""
    private(set) var authorized = false
    private(set) var lastError: String?

    /// Chiamato con il testo completo di ogni frase riconosciuta.
    @ObservationIgnored var onUtterance: ((String) -> Void)?
    /// Chiamato quando finisce di parlare.
    @ObservationIgnored var onFinishedSpeaking: (() -> Void)?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private let silenceTimeout: TimeInterval = 1.3
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private lazy var voice: AVSpeechSynthesisVoice? = {
        let italian = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "it-IT" }
        return italian.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: "it-IT")
    }()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func requestPermissions() async {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        authorized = speech && mic
        if !authorized { lastError = "Servono i permessi di microfono e riconoscimento vocale (Impostazioni iPad)." }
        configureSession()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .allowBluetooth = microfono degli AirPods; A2DP per l'audio di qualità quando non si registra.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
            try session.setActive(true)
        } catch {
            lastError = "Audio: \(error.localizedDescription)"
        }
    }

    // MARK: Ascolto

    func startListening() {
        guard authorized, phase != .listening else { return }
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Riconoscimento vocale italiano non disponibile."
            return
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        stopRecognition()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            lastError = "Microfono: \(error.localizedDescription)"
            return
        }

        partialTranscript = ""
        phase = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text, !text.isEmpty {
                    self.partialTranscript = text
                    self.restartSilenceTimer()
                }
                if isFinal || (failed && self.phase == .listening) {
                    self.finishUtterance()
                }
            }
        }
    }

    func stopListening() {
        stopRecognition()
        if phase == .listening { phase = .idle }
    }

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishUtterance() }
        }
    }

    private func finishUtterance() {
        guard phase == .listening else { return }
        let text = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRecognition()
        phase = .idle
        partialTranscript = ""
        if !text.isEmpty { onUtterance?(text) }
    }

    private func stopRecognition() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    // MARK: Voce

    func setThinking() { phase = .thinking }

    func speak(_ text: String) {
        stopRecognition()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        phase = .speaking
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func markIdle() { if phase != .listening { phase = .idle } }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            self.phase = .idle
            self.onFinishedSpeaking?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.phase == .speaking { self.phase = .idle }
        }
    }
}
