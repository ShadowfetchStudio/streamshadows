import SwiftUI

struct AudioMixerPanel: View {
    @ObservedObject var viewModel: StreamViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Audio Mixer", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                if !viewModel.microphones.isEmpty {
                    Picker("Microphone", selection: Binding(
                        get: { viewModel.selectedMicID ?? "" },
                        set: { viewModel.selectMicrophone($0.isEmpty ? nil : $0) }
                    )) {
                        ForEach(viewModel.microphones) { mic in
                            Text(mic.name).tag(mic.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .labelsHidden()
                    .help("Select Microphone Input")
                }
            }

            HStack(spacing: 12) {
                mixerStrip(
                    title: "Desktop Sound",
                    icon: "speaker.wave.2.fill",
                    isEnabled: $viewModel.systemAudioEnabled,
                    isMuted: $viewModel.systemAudioMuted,
                    volume: $viewModel.systemAudioVolume,
                    maxVolume: 1.5,
                    peak: viewModel.audioLevels.systemPeak,
                    showEnableToggle: true
                )

                mixerStrip(
                    title: "Microphone",
                    icon: "mic.fill",
                    isEnabled: $viewModel.micAudioEnabled,
                    isMuted: $viewModel.micAudioMuted,
                    volume: $viewModel.micAudioVolume,
                    maxVolume: 2.0,
                    peak: viewModel.audioLevels.micPeak,
                    showEnableToggle: true
                )

                mixerStrip(
                    title: "Master Output",
                    icon: "waveform",
                    isEnabled: .constant(true),
                    isMuted: $viewModel.masterMuted,
                    volume: $viewModel.masterVolume,
                    maxVolume: 1.5,
                    peak: viewModel.audioLevels.masterPeak,
                    showEnableToggle: false
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func mixerStrip(
        title: String,
        icon: String,
        isEnabled: Binding<Bool>,
        isMuted: Binding<Bool>,
        volume: Binding<Float>,
        maxVolume: Float,
        peak: Float,
        showEnableToggle: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(isEnabled.wrappedValue && !isMuted.wrappedValue ? Color.accentColor : Color.secondary)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if showEnableToggle {
                    Toggle("", isOn: isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }

            LevelMeterView(level: peak, isMuted: !isEnabled.wrappedValue || isMuted.wrappedValue)

            HStack(spacing: 8) {
                Button {
                    isMuted.wrappedValue.toggle()
                } label: {
                    Image(systemName: isMuted.wrappedValue ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .font(.caption)
                        .foregroundStyle(isMuted.wrappedValue ? .red : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isMuted.wrappedValue ? Color.red.opacity(0.18) : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(isMuted.wrappedValue ? "Unmute \(title)" : "Mute \(title)")

                Slider(
                    value: Binding(
                        get: { Double(volume.wrappedValue) },
                        set: { volume.wrappedValue = Float($0) }
                    ),
                    in: 0...Double(maxVolume)
                )
                .disabled(!isEnabled.wrappedValue)

                Text("\(Int((volume.wrappedValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .opacity(isEnabled.wrappedValue ? 1.0 : 0.55)
    }
}
