import SwiftUI

/// Schermata della TV: percorso a schermo intero, dati grandi in alto, sottotitoli di Claude in basso.
struct TVView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.treadmill.state
        ZStack {
            VeniceSceneView(venice: model.venice)
                .ignoresSafeArea()

            VStack {
                HStack(alignment: .top, spacing: 14) {
                    StatTile(label: "Velocità", value: String(format: "%.1f", state.speedKmh), unit: "km/h", large: true)
                    StatTile(label: "Passo", value: state.paceText, unit: "min/km", large: true)
                    StatTile(label: "Distanza", value: String(format: "%.2f", state.distanceM / 1000), unit: "km", large: true)
                    StatTile(label: "Tempo", value: state.elapsedText, large: true)
                    StatTile(label: "Pendenza", value: String(format: "%.0f", state.inclinePct), unit: "%", large: true)
                    if let hr = state.heartRate {
                        StatTile(label: "Cuore", value: "\(hr)", unit: "bpm", large: true)
                    }
                    Spacer()
                    VoiceIndicator(phase: model.voice.phase, large: true)
                }
                .padding(32)

                if let banner = model.banner {
                    Text(banner)
                        .font(.system(size: 34, weight: .semibold))
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(.black.opacity(0.55), in: Capsule())
                        .transition(.opacity)
                }

                Spacer()

                if let pending = model.treadmill.pending {
                    PendingCard(change: pending, large: true)
                        .padding(.bottom, 20)
                }

                if model.voice.phase == .listening, !model.voice.partialTranscript.isEmpty {
                    subtitle(model.voice.partialTranscript, color: .green)
                } else if let last = model.transcript.last(where: { $0.role == .claude }) {
                    subtitle(last.text, color: .white)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: model.banner)
        }
        .foregroundStyle(.white)
    }

    private func subtitle(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 36, weight: .medium))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 36).padding(.vertical, 18)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 120)
            .padding(.bottom, 48)
    }
}
