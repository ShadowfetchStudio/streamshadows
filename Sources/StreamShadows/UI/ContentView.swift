import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: StreamViewModel

    var body: some View {
        VStack(spacing: 0) {
            topHeaderBar
            Divider()

            HStack(spacing: 0) {
                // Left/Center Stage: Preview + Audio Mixer
                VStack(spacing: 14) {
                    if let banner = viewModel.statusBanner {
                        bannerView(banner, isError: false) {
                            viewModel.dismissStatusBanner()
                        }
                    }
                    if case .error(let message) = viewModel.streamState {
                        bannerView(message, isError: true) {
                            viewModel.dismissStreamError()
                        }
                    }
                    if case .error(let message) = viewModel.recordingState {
                        bannerView(message, isError: true) {
                            viewModel.dismissRecordingError()
                        }
                    }

                    previewStage
                    AudioMixerPanel(viewModel: viewModel)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.07, green: 0.08, blue: 0.11))

                Divider()

                // Right Inspector Panel
                InspectorSidebar(viewModel: viewModel)
                    .frame(width: 340)
            }
        }
        .task {
            await viewModel.bootstrap()
        }
    }

    // MARK: - Responsive Top Header Bar

    private var topHeaderBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.purple)
                    Text("StreamShadows")
                        .font(.title3.weight(.bold))
                        .fixedSize()
                }

                statusPill

                if viewModel.recordingState.isRecording || viewModel.recordingState.isPaused {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.recordingState.isPaused ? Color.orange : Color.red)
                            .frame(width: 8, height: 8)
                        Text(viewModel.recordingState.isPaused ? "PAUSED \(viewModel.recordingElapsedText)" : "REC \(viewModel.recordingElapsedText)")
                            .font(.caption.weight(.bold).monospacedDigit())
                        if !viewModel.recordingFileSizeText.isEmpty {
                            Text("• \(viewModel.recordingFileSizeText)")
                                .font(.caption2.monospacedDigit())
                                .opacity(0.85)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill((viewModel.recordingState.isPaused ? Color.orange : Color.red).opacity(0.18)))
                    .foregroundStyle(viewModel.recordingState.isPaused ? .orange : .red)
                    .fixedSize()
                }

                Spacer(minLength: 8)

                // Pause/Resume Recording button when actively recording or paused
                if viewModel.recordingState.isRecording || viewModel.recordingState.isPaused {
                    Button {
                        viewModel.togglePauseRecording()
                    } label: {
                        Image(systemName: viewModel.recordingState.isPaused ? "play.fill" : "pause.fill")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .help(viewModel.recordingState.isPaused ? "Resume Recording (⌘⇧P)" : "Pause Recording (⌘⇧P)")
                }

                Button {
                    viewModel.toggleRecording()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.recordingState.isActive ? "stop.circle.fill" : "record.circle")
                        Text(recordButtonTitle)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(viewModel.recordingState.isActive ? .red : .secondary)
                .disabled(!viewModel.recordingState.isActive && !viewModel.canStartRecording)
                .fixedSize()
                .help(viewModel.recordingState.isActive
                      ? "Stop local recording (⌘⇧R)"
                      : "Choose save location & record locally (⌘⇧R)")

                Button {
                    viewModel.toggleStream()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.streamState.isActive ? "stop.fill" : "play.fill")
                        Text(streamButtonTitle)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.streamState.isActive ? .red : .purple)
                .disabled(!viewModel.streamState.isActive && !viewModel.canStartStream)
                .fixedSize()
                .help(viewModel.canStartStream || viewModel.streamState.isActive
                      ? "Start or stop streaming (⌘⇧L)"
                      : "Enable at least one destination with a stream key to go live")
            }

            // Secondary telemetry & destinations bar (shown when live or destinations configured — prevents clipping at 980px)
            if viewModel.streamState.isLive || !viewModel.readyDestinations.isEmpty {
                HStack(spacing: 10) {
                    if viewModel.streamState.isLive {
                        HStack(spacing: 8) {
                            Label(viewModel.elapsedTimeText, systemImage: "clock")
                            Text("•")
                            Text("\(viewModel.telemetry.fps) fps")
                            Text("•")
                            Text(viewModel.telemetry.bitrate)
                            if viewModel.telemetry.droppedFrames > 0 {
                                Text("•")
                                Text("\(viewModel.telemetry.droppedFrames) dropped")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        ForEach(viewModel.readyDestinations) { dest in
                            Text(dest.platform.displayName)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var recordButtonTitle: String {
        switch viewModel.recordingState {
        case .idle, .error: return "Record"
        case .countdown(let rem, _): return "Cancel (\(rem))"
        case .recording, .paused: return "Stop Rec"
        case .stopping: return "Saving…"
        }
    }

    private var streamButtonTitle: String {
        switch viewModel.streamState {
        case .idle, .error: return "Go Live"
        case .starting: return "Starting…"
        case .live: return "Stop Stream"
        case .reconnecting: return "Cancel"
        case .stopping: return "Stopping…"
        }
    }

    private var statusPill: some View {
        let (label, color): (String, Color) = {
            switch viewModel.streamState {
            case .idle: return ("OFFLINE", .gray)
            case .starting: return ("CONNECTING", .orange)
            case .live: return ("LIVE", .red)
            case .reconnecting(let attempt, let max): return ("RECONNECT \(attempt)/\(max)", .orange)
            case .stopping: return ("STOPPING", .orange)
            case .error: return ("ERROR", .red)
            }
        }()

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.18)))
        .foregroundStyle(color)
        .fixedSize()
    }

    // MARK: - Preview Stage

    private var previewStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)

            if let cgImage = viewModel.previewImage {
                Image(decorative: cgImage, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Preview Ready")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Select a display, window, or camera on the right to begin.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Countdown overlay
            if case .countdown(let remaining, _) = viewModel.recordingState {
                ZStack {
                    Color.black.opacity(0.55)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(spacing: 8) {
                        Text("\(remaining)")
                            .font(.system(size: 72, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Recording starts in…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }

            // Corner mode badge & quick screen/window switcher
            VStack {
                HStack(spacing: 8) {
                    Label(viewModel.sourceMode.title, systemImage: viewModel.sourceMode.symbolName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())

                    if viewModel.sourceMode.usesScreen && viewModel.screenTargetMode == .display && !viewModel.displays.isEmpty {
                        Picker("Screen", selection: Binding(
                            get: { viewModel.selectedDisplayID ?? viewModel.displays.first?.id ?? 0 },
                            set: { viewModel.selectDisplay($0) }
                        )) {
                            ForEach(viewModel.displays) { display in
                                Text("\(display.name) (\(display.resolutionLabel))")
                                    .tag(display.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .help("Choose which screen to capture")
                    } else if viewModel.sourceMode.usesScreen && viewModel.screenTargetMode == .window && !viewModel.windows.isEmpty {
                        Picker("Window", selection: Binding(
                            get: { viewModel.selectedWindowID ?? viewModel.windows.first?.id ?? 0 },
                            set: { viewModel.selectWindow($0) }
                        )) {
                            ForEach(viewModel.windows) { win in
                                Text(win.displayLabel)
                                    .tag(win.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .help("Choose which window to capture")
                    }

                    Spacer()
                    Text("\(viewModel.qualityPreset.width)×\(viewModel.qualityPreset.height) • \(viewModel.qualityPreset.fps)fps")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
            }
            .padding(10)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    (viewModel.streamState.isLive || viewModel.recordingState.isRecording)
                        ? Color.red.opacity(0.7)
                        : Color.white.opacity(0.1),
                    lineWidth: (viewModel.streamState.isLive || viewModel.recordingState.isRecording) ? 2 : 1
                )
        )
    }

    private func bannerView(_ message: String, isError: Bool, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.octagon.fill" : "info.circle.fill")
                .foregroundStyle(isError ? .red : .orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((isError ? Color.red : Color.orange).opacity(0.15))
        )
    }
}
