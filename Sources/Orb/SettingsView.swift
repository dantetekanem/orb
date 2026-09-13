import SwiftUI
import TalkerCore

struct SettingsView: View {
    @ObservedObject var model: OrbModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Meeting mode", isOn: $model.meetingMode)
                } header: { Text("Quiet delivery") }
                  footer: { Text("Active microphone use silences Orb automatically. Turn on Meeting mode for muted or listen-only calls in Meet, Tuple, Teams or Zoom.") }

                Section {
                    Picker("Voice", selection: $model.settings.voice) {
                        ForEach(VoiceChoice.allCases) { voice in
                            Text(voice.label).tag(voice).disabled(!voice.isAvailable(in: model.runtime))
                        }
                    }
                    .pickerStyle(.menu)
                } header: { Text("Voice") }

                Section {
                    control("Speaking speed", value: $model.settings.speed, range: 0.65...1.45, unit: "×")
                    control("Sentence pause", value: $model.settings.pause, range: 0...0.8, unit: "s")
                    control("Rhythm variation", value: $model.settings.rhythm, range: 0...1.2, unit: "")
                        .help("Varies phoneme timing using Piper’s noise-width control. Higher values add more variation.")
                } header: { Text("Delivery") }
                  footer: { Text("Changes apply to the next message or preview. Your current speech is left alone.") }
            }
            .formStyle(.grouped)
            HStack {
                Button("Reset") { model.settings = VoiceSettings() }
                    .help("Restore Jenny and the original delivery settings")
                Spacer()
                Button("Preview voice", systemImage: "play.fill") {
                    model.speak(Message(text: "Your work is ready. Take a look when you have a moment.", source: "Orb"))
                }
                .disabled(!model.settings.voice.isAvailable(in: model.runtime))
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22).padding(.bottom, 20)
        }
        .frame(width: 430, height: 540)
        .tint(Color(red: 0.38, green: 0.69, blue: 0.78))
    }

    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.2f")\(unit.isEmpty ? "" : " " + unit)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.05)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 3)
    }
}
