import SwiftUI

struct AudioMixerPanel: View {
    @ObservedObject var viewModel: StreamViewModel
    @State private var showMicProcessingPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Audio Mixer", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    showMicProcessingPopover.toggle()
                } label: {
                    Label(micFXLabel, systemImage: "waveform.badge.mic")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showMicProcessingPopover, arrowEdge: .top) {
                    micProcessingPopover
                }
                .help("Microphone Noise Gate & Lip-Sync Delay")

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
                    .frame(maxWidth: 210)
                    .labelsHidden()
                    .help("Select Microphone Input")
                }
            }

            HStack(spacing: 12) {
                mixerStrip(
                    title: "Desktop Sound",
                    subtitle: viewModel.sourceMode.usesScreen ? nil : "Screen mode only",
                    icon: "speaker.wave.2.fill",
                    isEnabled: $viewModel.systemAudioEnabled,
                    isMuted: $viewModel.systemAudioMuted,
                    volume: $viewModel.systemAudioVolume,
                    maxVolume: 1.5,
                    peak: viewModel.sourceMode.usesScreen ? viewModel.audioLevels.systemPeak : 0,
                    showEnableToggle: true,
                    isUnavailable: !viewModel.sourceMode.usesScreen
                )

                mixerStrip(
                    title: "Microphone",
                    subtitle: nil,
                    icon: "mic.fill",
                    isEnabled: $viewModel.micAudioEnabled,
                    isMuted: $viewModel.micAudioMuted,
                    volume: $viewModel.micAudioVolume,
                    maxVolume: 2.0,
                    peak: viewModel.audioLevels.micPeak,
                    showEnableToggle: true,
                    isUnavailable: false
                )

                mixerStrip(
                    title: "Master Output",
                    subtitle: nil,
                    icon: "waveform",
                    isEnabled: .constant(true),
                    isMuted: $viewModel.masterMuted,
                    volume: $viewModel.masterVolume,
                    maxVolume: 1.5,
                    peak: viewModel.audioLevels.masterPeak,
                    showEnableToggle: false,
                    isUnavailable: false
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

    private var micFXLabel: String {
        let gateOn = viewModel.micNoiseGateThreshold > 0.001
        let delayOn = viewModel.micDelayMs > 0
        if gateOn && delayOn { return "Mic FX • Gate + \(viewModel.micDelayMs)ms" }
        if gateOn { return "Mic FX • Gate" }
        if delayOn { return "Mic FX • \(viewModel.micDelayMs)ms" }
        return "Mic FX"
    }

    private var micProcessingPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Microphone Processing")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Noise Gate")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(viewModel.micNoiseGateThreshold < 0.001 ? "Off" : "\(Int((viewModel.micNoiseGateThreshold * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(viewModel.micNoiseGateThreshold) },
                        set: { viewModel.micNoiseGateThreshold = Float($0) }
                    ),
                    in: 0...0.15
                )
                Text("Silences background fan or keyboard noise when you aren't speaking.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Mic Sync Delay")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(viewModel.micDelayMs) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(viewModel.micDelayMs) },
                        set: { viewModel.micDelayMs = Int($0.rounded()) }
                    ),
                    in: 0...300,
                    step: 10
                )
                Text("Delay your mic to match higher-latency USB webcams.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    @ViewBuilder
    private func mixerStrip(
        title: String,
        subtitle: String?,
        icon: String,
        isEnabled: Binding<Bool>,
        isMuted: Binding<Bool>,
        volume: Binding<Float>,
        maxVolume: Float,
        peak: Float,
        showEnableToggle: Bool,
        isUnavailable: Bool
    ) -> some View {
        let effectivelyActive = isEnabled.wrappedValue && !isUnavailable
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(effectivelyActive && !isMuted.wrappedValue ? Color.accentColor : Color.secondary)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if showEnableToggle {
                    Toggle("", isOn: isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }

            LevelMeterView(level: peak, isMuted: !effectivelyActive || isMuted.wrappedValue)

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
                .disabled(isUnavailable)
                .help(isMuted.wrappedValue ? "Unmute \(title)" : "Mute \(title)")

                Slider(
                    value: Binding(
                        get: { Double(volume.wrappedValue) },
                        set: { volume.wrappedValue = Float($0) }
                    ),
                    in: 0...Double(maxVolume)
                )
                .disabled(!effectivelyActive)

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
        .opacity(effectivelyActive ? 1.0 : 0.5)
    }
}
