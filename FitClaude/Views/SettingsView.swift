import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section("Claude") {
                    SecureField("Chiave API (sk-ant-…)", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Modello", selection: $settings.model) {
                        Text("Claude Opus 5.5").tag("claude-opus-5-5")
                        Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                        Text("Claude Haiku 5.5 (più rapido)").tag("claude-haiku-5-5")
                    }
                    Picker("Riflessione", selection: $settings.effort) {
                        Text("Bassa (risposte rapide)").tag("low")
                        Text("Media").tag("medium")
                        Text("Alta").tag("high")
                    }
                    TextField("Il tuo nome", text: $settings.userName)
                    Toggle("Leggi ad alta voce le risposte", isOn: $settings.speakReplies)
                    Toggle("Ascolto continuo", isOn: $settings.continuousListening)
                }

                Section {
                    stepperRow("Velocità massima", value: $settings.maxSpeedKmh, range: 3...20, step: 0.5, unit: "km/h")
                    stepperRow("Pendenza massima", value: $settings.maxInclinePct, range: 0...12, step: 1, unit: "%")
                    stepperRow("Gesti attivi fino a", value: $settings.gestureSpeedLimitKmh, range: 3...16, step: 0.5, unit: "km/h")
                } header: {
                    Text("Sicurezza")
                } footer: {
                    Text("Claude e i gesti non possono superare questi limiti. Gli aumenti vanno sempre confermati. La chiave magnetica del tapis resta lo stop d'emergenza.")
                }

                Section("Tapis roulant") {
                    Picker("Sorgente", selection: Binding(
                        get: { model.treadmill.sourceKind },
                        set: { model.treadmill.switchSource(to: $0) })) {
                        ForEach(TreadmillController.SourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Stato", value: model.treadmill.connection.label)
                    LabeledContent("Comandi", value: model.treadmill.canControl ? "accettati" : "solo lettura")
                    if model.treadmill.sourceKind == .bluetooth {
                        ForEach(model.treadmill.discovered) { device in
                            Button {
                                model.treadmill.connectBluetooth(to: device.id)
                            } label: {
                                HStack {
                                    Text(device.name)
                                    if device.advertisesFTMS { Text("FTMS").font(.caption).foregroundStyle(.green) }
                                    Spacer()
                                    Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        NavigationLink("Registro Bluetooth") { DiagnosticsView().environment(model) }
                    }
                }

                Section {
                    Toggle("Inverti destra e sinistra", isOn: $settings.mirrorGestures)
                        .onChange(of: settings.mirrorGestures) { model.gestures.mirrored = settings.mirrorGestures }
                    if model.gesturesEnabled {
                        CameraPreview(session: model.gestures.session)
                            .frame(height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        LabeledContent("Fotocamera", value: model.gestures.cameraName)
                        LabeledContent("Corpo inquadrato", value: model.gestures.bodyVisible ? "sì" : "no")
                        LabeledContent("Gesto in corso", value: model.gestures.candidate?.rawValue ?? "—")
                        LabeledContent("Ultimo gesto", value: model.gestures.lastGesture?.rawValue ?? "—")
                    } else {
                        Text("Attiva i gesti dalla schermata principale per vedere l'anteprima della fotocamera.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Gesti")
                } footer: {
                    Text("Mano alzata: parla con Claude. Pollice su/giù: conferma/annulla. Palmo aperto: rallenta al passo. Braccio a destra/sinistra: ±0,5 km/h, oppure scegli il bivio.")
                }
            }
            .navigationTitle("Impostazioni")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
        }
    }

    private func stepperRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: step < 1 ? "%.1f %@" : "%.0f %@", value.wrappedValue, unit)).monospacedDigit()
            }
        }
    }
}

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.treadmill.diagnostics.reversed(), id: \.self) { line in
            Text(line).font(.system(.caption, design: .monospaced))
        }
        .navigationTitle("Registro Bluetooth")
        .toolbar {
            ShareLink(item: model.treadmill.diagnostics.joined(separator: "\n"))
        }
    }
}
