import SwiftUI

/// Schermata dell'iPad: comandi grandi da toccare anche mentre cammini, conversazione e anteprima della scena.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        let state = model.treadmill.state
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            VStack(spacing: 12) {
                header(state)
                if landscape {
                    HStack(spacing: 12) {
                        scenePanel
                        transcriptPanel.frame(width: geo.size.width * 0.36)
                    }
                } else {
                    scenePanel.frame(height: geo.size.height * 0.38)
                    transcriptPanel
                }
                controls
            }
            .padding(16)
        }
        .background(Color(white: 0.07).ignoresSafeArea())
        .foregroundStyle(.white)
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(model)
        }
        .task { await model.onLaunch() }
    }

    private func header(_ state: TreadmillState) -> some View {
        HStack(spacing: 10) {
            StatTile(label: "Velocità", value: String(format: "%.1f", state.speedKmh), unit: "km/h")
            StatTile(label: "Passo", value: state.paceText, unit: "/km")
            StatTile(label: "Distanza", value: String(format: "%.2f", state.distanceM / 1000), unit: "km")
            StatTile(label: "Tempo", value: state.elapsedText)
            StatTile(label: "Pendenza", value: String(format: "%.0f", state.inclinePct), unit: "%")
            if let hr = state.heartRate { StatTile(label: "Cuore", value: "\(hr)", unit: "bpm") }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                VoiceIndicator(phase: model.voice.phase)
                Label(model.treadmill.connection.label, systemImage: model.treadmill.sourceKind == .simulator ? "gamecontroller" : "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
                Label(model.externalDisplayConnected ? "TV collegata" : "TV non collegata", systemImage: "tv")
                    .font(.caption).foregroundStyle(model.externalDisplayConnected ? .green : .secondary)
            }
        }
    }

    private var scenePanel: some View {
        ZStack(alignment: .bottom) {
            VeniceSceneView(venice: model.venice)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(spacing: 8) {
                if let banner = model.banner {
                    Text(banner).font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                if let pending = model.treadmill.pending {
                    PendingCard(change: pending)
                    HStack {
                        Button("Annulla") { model.treadmill.cancelPending() }
                            .buttonStyle(.bordered).tint(.white)
                        Button("Conferma") { model.treadmill.confirmPending() }
                            .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .controlSize(.large)
                }
            }
            .padding(12)
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversazione").font(.headline)
                Spacer()
                Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.transcript) { entry in
                            bubble(entry).id(entry.id)
                        }
                        if model.voice.phase == .listening, !model.voice.partialTranscript.isEmpty {
                            Text(model.voice.partialTranscript)
                                .foregroundStyle(.green)
                                .italic()
                                .id("partial")
                        }
                    }
                }
                .onChange(of: model.transcript.count) {
                    if let last = model.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let error = model.voice.lastError ?? model.gestures.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private func bubble(_ entry: TranscriptEntry) -> some View {
        let (label, color): (String, Color) = {
            switch entry.role {
            case .user: return ("Tu", .green)
            case .claude: return ("Claude", .blue)
            case .system: return ("App", .gray)
            }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(color)
            Text(entry.text).font(entry.role == .system ? .footnote : .body)
                .foregroundStyle(entry.role == .system ? .secondary : .primary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            bigButton(model.voice.phase == .listening ? "Stop" : "Parla",
                      icon: model.voice.phase == .listening ? "mic.slash.fill" : "mic.fill",
                      tint: .green) { model.talkButton() }
            bigButton(model.gesturesEnabled ? "Gesti attivi" : "Gesti spenti",
                      icon: model.gesturesEnabled ? "hand.raised.fill" : "hand.raised.slash",
                      tint: model.gesturesEnabled ? .teal : .gray) { model.toggleGestures() }
            Divider().frame(height: 50)
            bigButton("Avvia", icon: "play.fill", tint: .blue) { model.treadmill.start() }
            bigButton("Pausa", icon: "pause.fill", tint: .orange) { model.treadmill.pause() }
            stepper("Velocità", minus: { adjustSpeed(-0.5) }, plus: { adjustSpeed(0.5) })
            stepper("Pendenza", minus: { adjustIncline(-1) }, plus: { adjustIncline(1) })
            Spacer()
            bigButton("Impostazioni", icon: "gearshape.fill", tint: .gray) { showSettings = true }
        }
    }

    private func adjustSpeed(_ delta: Double) {
        let current = max(model.treadmill.targetSpeed, model.treadmill.state.speedKmh)
        model.treadmill.requestSpeed(current + delta, from: .user)
    }

    private func adjustIncline(_ delta: Double) {
        let current = max(model.treadmill.targetIncline, model.treadmill.state.inclinePct)
        model.treadmill.requestIncline(current + delta, from: .user)
    }

    private func bigButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(minWidth: 84, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    private func stepper(_ title: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button(action: minus) { Image(systemName: "minus").frame(width: 44, height: 36) }
                Button(action: plus) { Image(systemName: "plus").frame(width: 44, height: 36) }
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }
}
