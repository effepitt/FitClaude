import AVFoundation
import SceneKit
import SwiftUI

/// Mostra la scena di Venezia (la stessa scena sull'iPad e sulla TV).
struct VeniceSceneView: UIViewRepresentable {
    let venice: VeniceScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = venice.scene
        view.pointOfView = venice.cameraNode
        view.isPlaying = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        view.allowsCameraControl = false
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

/// Anteprima della fotocamera frontale, per sistemare l'iPad sul supporto.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Riquadro con un dato del tapis.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: large ? 18 : 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: large ? 56 : 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit).font(.system(size: large ? 20 : 14, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, large ? 20 : 12)
        .padding(.vertical, large ? 12 : 8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Stato della voce: ascolto, Claude che pensa, Claude che parla.
struct VoiceIndicator: View {
    let phase: VoiceController.Phase
    var large = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: large ? 18 : 12, height: large ? 18 : 12)
            Text(label).font(large ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private var color: Color {
        switch phase {
        case .idle: return .gray
        case .listening: return .green
        case .thinking: return .orange
        case .speaking: return .blue
        }
    }

    private var label: String {
        switch phase {
        case .idle: return "In attesa"
        case .listening: return "Ti ascolto"
        case .thinking: return "Claude pensa…"
        case .speaking: return "Claude parla"
        }
    }
}

/// Richiesta di conferma per un aumento di velocità o pendenza.
struct PendingCard: View {
    let change: TreadmillController.PendingChange
    var large = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.thumbsup.fill").font(large ? .largeTitle : .title2)
            VStack(alignment: .leading) {
                Text("Confermi?").font(large ? .title.bold() : .headline)
                Text(change.description.capitalizedFirst).font(large ? .title2 : .subheadline)
                Text("Pollice su o \"sì\" per confermare, pollice giù o \"no\" per annullare")
                    .font(large ? .headline : .caption).foregroundStyle(.secondary)
            }
        }
        .padding(large ? 24 : 14)
        .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
