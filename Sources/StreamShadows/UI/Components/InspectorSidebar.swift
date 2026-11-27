import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case sources = "Sources"
    case destinations = "Destinations"
    case output = "Output"

    var id: String { rawValue }
}

struct InspectorSidebar: View {
    @ObservedObject var viewModel: StreamViewModel
    @State private var selectedTab: InspectorTab = .sources
    @State private var revealedKeys: Set<StreamingPlatform> = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $selectedTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .sources:
                        sourcesSection
                    case .destinations:
                        destinationsSection
                    case .output:
                        outputSection
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Sources Tab

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Mode selector
            VStack(alignment: .leading, spacing: 6) {
                Text("Stream Mode")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Stream Mode", selection: $viewModel.sourceMode) {
                    ForEach(StreamSourceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Screen selection
            if viewModel.sourceMode.usesScreen {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Select Screen (\(viewModel.displays.count))", systemImage: "display.2")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                Task { await viewModel.refreshAllDevices() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh Displays & Devices")
                        }

                        if viewModel.displays.isEmpty {
                            Text("No displays detected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 6) {
                                ForEach(viewModel.displays) { display in
                                    let isSelected = display.id == viewModel.selectedDisplayID
                                    Button {
                                        viewModel.selectDisplay(display.id)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "display")
                                                .font(.body)
                                                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(display.name)
                                                    .font(.callout.weight(isSelected ? .semibold : .regular))
                                                    .foregroundStyle(isSelected ? .white : .primary)
                                                    .lineLimit(1)
                                                Text(display.resolutionLabel)
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                                            }
                                            Spacer()
                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(isSelected ? Color.purple : Color.white.opacity(0.06))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Toggle("Hide StreamShadows from capture", isOn: $viewModel.excludeSelfFromCapture)
                            .font(.callout)
                            .help("Prevents infinite preview recursion when streaming the same screen StreamShadows is on")

                        if !viewModel.hasScreenPermission {
                            Button("Grant Screen Recording Access") {
                                viewModel.requestScreenPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(4)
                }
            }

            // Camera selection (optional or primary)
            if viewModel.sourceMode.usesCamera {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Camera", systemImage: "video.fill")
                            .font(.subheadline.weight(.semibold))

                        if viewModel.cameras.isEmpty {
                            Text("No camera detected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Select Camera", selection: Binding(
                                get: { viewModel.selectedCameraID ?? "" },
                                set: { viewModel.selectCamera($0.isEmpty ? nil : $0) }
                            )) {
                                ForEach(viewModel.cameras) { cam in
                                    Text(cam.name).tag(cam.id)
                                }
                            }
                            .labelsHidden()
                        }

                        Toggle("Mirror Camera Horizontally", isOn: $viewModel.mirrorCamera)
                            .font(.callout)

                        if viewModel.sourceMode == .screenWithCameraPiP {
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Picture-in-Picture Placement")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Picker("Corner", selection: $viewModel.pipPosition) {
                                    ForEach(PiPPosition.allCases) { pos in
                                        Text(pos.title).tag(pos)
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Size", selection: $viewModel.pipSize) {
                                    ForEach(PiPSize.allCases) { size in
                                        Text(size.title).tag(size)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                    .padding(4)
                }
            }

            // Permissions checklist
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS Permissions")
                        .font(.subheadline.weight(.semibold))

                    permissionRow(
                        title: "Screen Recording",
                        granted: viewModel.hasScreenPermission,
                        action: { viewModel.requestScreenPermission() },
                        settingsPane: "Privacy_ScreenCapture"
                    )
                    permissionRow(
                        title: "Camera",
                        granted: viewModel.hasCameraPermission,
                        action: { viewModel.requestCameraPermission() },
                        settingsPane: "Privacy_Camera"
                    )
                    permissionRow(
                        title: "Microphone",
                        granted: viewModel.hasMicPermission,
                        action: { viewModel.requestMicPermission() },
                        settingsPane: "Privacy_Microphone"
                    )
                }
                .padding(4)
            }
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        action: @escaping () -> Void,
        settingsPane: String
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
                .font(.caption)
            Spacer()
            if !granted {
                Button("Allow") { action() }
                    .controlSize(.mini)
                Button("Settings") { viewModel.openSystemSettingsPrivacy(settingsPane) }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
            } else {
                Text("Granted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Destinations Tab

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enable one or more platforms to stream simultaneously. Stream keys are stored securely in your macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(viewModel.destinations) { dest in
                destinationCard(for: dest)
            }
        }
    }

    private func destinationCard(for dest: StreamDestinationConfig) -> some View {
        let isRevealed = revealedKeys.contains(dest.platform)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(platformColor(dest.platform))
                        .frame(width: 9, height: 9)

                    Text(dest.platform.displayName)
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    if dest.isEnabled {
                        let statusText: String = {
                            if !dest.hasValidIngestURL { return "Invalid URL" }
                            if !dest.isReadyToStream { return "Key required" }
                            return "Ready"
                        }()
                        let statusColor: Color = {
                            if !dest.hasValidIngestURL { return .red }
                            if !dest.isReadyToStream { return .orange }
                            return .green
                        }()
                        Text(statusText)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(statusColor.opacity(0.2)))
                            .foregroundStyle(statusColor)
                    }

                    Toggle("", isOn: Binding(
                        get: { dest.isEnabled },
                        set: { newVal in
                            var updated = dest
                            updated.isEnabled = newVal
                            viewModel.updateDestination(updated)
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(viewModel.streamState.isActive)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Ingest Server (RTMP/RTMPS)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") {
                            viewModel.resetIngestURL(for: dest.platform)
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .disabled(viewModel.streamState.isActive)
                    }

                    TextField("rtmps://…", text: Binding(
                        get: { dest.ingestURL },
                        set: { newVal in
                            var updated = dest
                            updated.ingestURL = newVal
                            viewModel.updateDestination(updated)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .disabled(viewModel.streamState.isActive)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Stream Key")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        if isRevealed {
                            TextField("Paste stream key", text: Binding(
                                get: { dest.streamKey },
                                set: { newVal in
                                    var updated = dest
                                    updated.streamKey = newVal
                                    viewModel.updateDestination(updated)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .disabled(viewModel.streamState.isActive)
                        } else {
                            SecureField("Paste stream key", text: Binding(
                                get: { dest.streamKey },
                                set: { newVal in
                                    var updated = dest
                                    updated.streamKey = newVal
                                    viewModel.updateDestination(updated)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .disabled(viewModel.streamState.isActive)
                        }

                        Button {
                            if isRevealed {
                                revealedKeys.remove(dest.platform)
                            } else {
                                revealedKeys.insert(dest.platform)
                            }
                        } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(isRevealed ? "Hide key" : "Show key")
                    }
                }

                Text(dest.platform.setupHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private func platformColor(_ platform: StreamingPlatform) -> Color {
        switch platform {
        case .youtube: return Color(red: 1.0, green: 0.0, blue: 0.2)
        case .twitch: return Color(red: 0.57, green: 0.27, blue: 1.0)
        case .x: return Color(red: 0.11, green: 0.61, blue: 0.94)
        }
    }

    // MARK: - Output Tab

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Video Quality")
                        .font(.subheadline.weight(.semibold))

                    Picker("Preset", selection: $viewModel.qualityPreset) {
                        ForEach(VideoQualityPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .disabled(viewModel.isEncodingActive)

                    Text("Encoder")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)

                    Picker("Encoder", selection: $viewModel.encoderPreference) {
                        ForEach(VideoEncoderPreference.allCases) { enc in
                            Text(enc.title).tag(enc)
                        }
                    }
                    .labelsHidden()
                    .disabled(viewModel.isEncodingActive)
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Local Recording", systemImage: "record.circle")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if viewModel.recordingState.isRecording {
                            Text(viewModel.recordingElapsedText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }

                    Picker("Format", selection: $viewModel.recordingFormat) {
                        ForEach(RecordingFormat.allCases) { fmt in
                            Text(fmt.title).tag(fmt)
                        }
                    }
                    .disabled(viewModel.recordingState.isActive)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Save Folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(viewModel.recordingDirectoryPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        Button("Choose…") {
                            viewModel.chooseRecordingFolder()
                        }
                        .controlSize(.small)
                        .disabled(viewModel.recordingState.isActive)

                        Button("Open Folder") {
                            viewModel.openRecordingsFolder()
                        }
                        .controlSize(.small)

                        if viewModel.lastRecordingURL != nil {
                            Button("Reveal Last") {
                                viewModel.revealLastRecordingInFinder()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("FFmpeg Engine")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if viewModel.detectedFFmpegPath != nil {
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Missing", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    if let path = viewModel.detectedFFmpegPath {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("Install via `brew install ffmpeg` or enter a custom binary path below.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    TextField("Optional custom ffmpeg path", text: $viewModel.customFFmpegPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Stream Logs")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Clear") {
                            viewModel.clearLogs()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if viewModel.logs.isEmpty {
                                Text("No log messages yet.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                }
                .padding(4)
            }
        }
    }
}
