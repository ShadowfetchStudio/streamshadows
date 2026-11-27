import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

@MainActor
public final class StreamViewModel: ObservableObject {
    // MARK: - Devices & Permissions
    @Published public var displays: [DisplayOption] = []
    @Published public var selectedDisplayID: CGDirectDisplayID?

    @Published public var windows: [WindowOption] = []
    @Published public var selectedWindowID: CGWindowID?

    @Published public var cameras: [CaptureDeviceOption] = []
    @Published public var selectedCameraID: String?

    @Published public var microphones: [CaptureDeviceOption] = []
    @Published public var selectedMicID: String?

    @Published public var hasScreenPermission: Bool = false
    @Published public var hasCameraPermission: Bool = false
    @Published public var hasMicPermission: Bool = false

    // MARK: - Source & Layout
    @Published public var sourceMode: StreamSourceMode = .screenOnly {
        didSet {
            savePreferences()
            updateCompositorConfig()
            Task { await reconfigureCaptureSources() }
        }
    }

    @Published public var screenTargetMode: ScreenCaptureTargetMode = .display {
        didSet {
            savePreferences()
            Task { await reconfigureScreenCapture() }
        }
    }

    @Published public var pipPosition: PiPPosition = .bottomRight {
        didSet {
            savePreferences()
            updateCompositorConfig()
        }
    }

    @Published public var pipSize: PiPSize = .medium {
        didSet {
            savePreferences()
            updateCompositorConfig()
        }
    }

    @Published public var pipShape: PiPShape = .rounded {
        didSet {
            savePreferences()
            updateCompositorConfig()
        }
    }

    @Published public var mirrorCamera: Bool = true {
        didSet {
            savePreferences()
            updateCompositorConfig()
        }
    }

    @Published public var excludeSelfFromCapture: Bool = true {
        didSet {
            savePreferences()
            Task { await reconfigureScreenCapture() }
        }
    }

    // MARK: - Audio Mixer
    @Published public var systemAudioEnabled: Bool = true {
        didSet {
            savePreferences()
            pushAudioMixerSettings()
        }
    }
    @Published public var systemAudioMuted: Bool = false {
        didSet { pushAudioMixerSettings() }
    }
    @Published public var systemAudioVolume: Float = 1.0 {
        didSet {
            savePreferences()
            pushAudioMixerSettings()
        }
    }

    @Published public var micAudioEnabled: Bool = true {
        didSet {
            savePreferences()
            pushAudioMixerSettings()
            reconfigureMicCapture()
        }
    }
    @Published public var micAudioMuted: Bool = false {
        didSet { pushAudioMixerSettings() }
    }
    @Published public var micAudioVolume: Float = 1.0 {
        didSet {
            savePreferences()
            pushAudioMixerSettings()
        }
    }
    @Published public var micNoiseGateThreshold: Float = 0.0 {
        didSet {
            savePreferences()
            pushAudioMixerSettings()
        }
    }
    @Published public var micDelayMs: Int = 0 {
        didSet {
            savePreferences()
            pushAudioMixerSettings()
        }
    }

    @Published public var masterMuted: Bool = false {
        didSet { pushAudioMixerSettings() }
    }
    @Published public var masterVolume: Float = 1.0 {
        didSet {
            savePreferences()
            pushAudioMixerSettings()
        }
    }

    @Published public var audioLevels = AudioLevels()

    // MARK: - Destinations
    @Published public var destinations: [StreamDestinationConfig] = []

    // MARK: - Output & Engine
    @Published public var qualityPreset: VideoQualityPreset = .p1080_30 {
        didSet {
            savePreferences()
            updateCompositorConfig()
            Task { await reconfigureScreenCapture() }
        }
    }

    @Published public var encoderPreference: VideoEncoderPreference = .hardwareVideoToolbox {
        didSet { savePreferences() }
    }

    @Published public var autoReconnectEnabled: Bool = true {
        didSet { savePreferences() }
    }

    @Published public var customFFmpegPath: String = "" {
        didSet {
            savePreferences()
            refreshFFmpegDetection()
        }
    }

    @Published public var detectedFFmpegPath: String?

    // MARK: - Recording Settings & State
    @Published public var recordingFormat: RecordingFormat = .mp4 {
        didSet { savePreferences() }
    }
    @Published public var recordingDirectoryPath: String = LocalRecorder.defaultRecordingsDirectory().path {
        didSet { savePreferences() }
    }
    /// When enabled (default), clicking Record prompts with a native Save dialog to pick exact location & filename.
    @Published public var askRecordingLocationOnRecord: Bool = true {
        didSet { savePreferences() }
    }
    @Published public var recordingCountdownEnabled: Bool = false {
        didSet { savePreferences() }
    }
    @Published public var recordingState: RecordingState = .idle
    @Published public var recordingElapsedText: String = "00:00:00"
    @Published public var recordingFileSizeText: String = ""
    @Published public var lastRecordingURL: URL?

    // MARK: - Live State
    @Published public var streamState: StreamState = .idle
    @Published public var previewImage: CGImage?
    @Published public var telemetry = StreamTelemetry()
    @Published public var elapsedTimeText: String = "00:00:00"
    @Published public var logs: [String] = []
    @Published public var statusBanner: String?

    // MARK: - Services
    private let captureManager = CaptureManager()
    private let compositor = FrameCompositor()
    private let audioMixer = AudioMixer()
    private let streamer = RTMPStreamer()
    private let recorder = LocalRecorder()
    private let keychain = KeychainStore()
    private let sleepPreventer = SleepPreventer()
    private let defaults = UserDefaults.standard

    private var uptimeTimer: Timer?
    private var recordingTimer: Timer?
    private var recordingAccumulatedSeconds: TimeInterval = 0
    private var recordingSegmentStartDate: Date?
    private var activeRecordingURL: URL?
    private var countdownTask: Task<Void, Never>?

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private let maxReconnectAttempts: Int = 5
    private var userRequestedStreamStop: Bool = false

    private var isBootstrapped = false
    private var isPreviewWindowHidden = false
    private var isRequestingMicPermission = false
    private var hasAutoPromptedMic = false
    private var isRequestingCameraPermission = false
    private var hasAutoPromptedCamera = false
    private var notificationObservers: [NSObjectProtocol] = []
    private var destinationSaveTasks: [StreamingPlatform: Task<Void, Never>] = [:]

    public init() {
        loadPreferences()
        refreshFFmpegDetection()
        wireCallbacks()
    }

    // MARK: - Computed Helpers

    public var readyDestinations: [StreamDestinationConfig] {
        destinations.filter { $0.isReadyToStream }
    }

    public var canStartStream: Bool {
        !streamState.isActive && !readyDestinations.isEmpty && detectedFFmpegPath != nil
    }

    public var canStartRecording: Bool {
        !recordingState.isActive && detectedFFmpegPath != nil
    }

    public var isEncodingActive: Bool {
        streamState.isActive || recordingState.isActive
    }

    private var isPipelineProducingFrames: Bool {
        streamState == .starting || streamState.isLive || recordingState.isRecording
    }

    // MARK: - Lifecycle

    public func bootstrap() async {
        guard !isBootstrapped else { return }
        isBootstrapped = true

        displays = CaptureManager.listConnectedDisplays()
        if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id
        }

        let nc = NotificationCenter.default
        notificationObservers.append(
            nc.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshAllDevices()
                }
            }
        )

        notificationObservers.append(
            nc.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPreviewWindowHidden = false
                    self.updateCompositorConfig()
                    let hadScreen = self.hasScreenPermission
                    self.refreshPermissionStatus()
                    if !hadScreen && self.hasScreenPermission {
                        await self.refreshAllDevices()
                        await self.reconfigureScreenCapture()
                    }
                }
            }
        )

        // Idle GPU/battery pause when minimized or hidden
        for hideName in [NSWindow.didMiniaturizeNotification, NSApplication.didHideNotification] {
            notificationObservers.append(
                nc.addObserver(forName: hideName, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isPreviewWindowHidden = true
                        self?.updateCompositorConfig()
                    }
                }
            )
        }
        for showName in [NSWindow.didDeminiaturizeNotification, NSApplication.didUnhideNotification] {
            notificationObservers.append(
                nc.addObserver(forName: showName, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isPreviewWindowHidden = false
                        self?.updateCompositorConfig()
                    }
                }
            )
        }

        // Hot-plug camera & microphone detection
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            notificationObservers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        await self.refreshAllDevices()
                        self.reconfigureCameraCapture()
                        self.reconfigureMicCapture()
                    }
                }
            )
        }

        refreshPermissionStatus()
        await refreshAllDevices()

        if detectedFFmpegPath == nil {
            statusBanner = "FFmpeg not found. Install via `brew install ffmpeg` or set its path in the Output tab to enable streaming and recording."
        }

        updateCompositorConfig()
        pushAudioMixerSettings()

        compositor.start()
        audioMixer.start()
        await reconfigureCaptureSources()
    }

    /// Synchronously flushes pending Keychain saves and gracefully finalizes active recordings before app termination.
    public func shutdownSynchronously() {
        countdownTask?.cancel()
        reconnectTask?.cancel()
        flushPendingDestinationSaves()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        sleepPreventer.endPreventingSleep()
        streamer.stop()
        if recordingState.isActive {
            recorder.stopAndWait(timeout: 3.0)
        } else {
            recorder.stop()
        }
        compositor.stop()
        audioMixer.stop()
        Task {
            await captureManager.stopAll()
        }
    }

    // MARK: - Banner Dismissal

    public func dismissStatusBanner() {
        statusBanner = nil
    }

    public func dismissStreamError() {
        if case .error = streamState {
            streamState = .idle
        }
    }

    public func dismissRecordingError() {
        if case .error = recordingState {
            recordingState = .idle
        }
    }

    // MARK: - Permissions & Device Discovery

    public func refreshPermissionStatus() {
        hasScreenPermission = CaptureManager.hasScreenCapturePermission()
        hasCameraPermission = CaptureManager.cameraAuthorizationStatus() == .authorized
        hasMicPermission = CaptureManager.microphoneAuthorizationStatus() == .authorized
    }

    public func requestScreenPermission() {
        let granted = CaptureManager.requestScreenCapturePermission()
        refreshPermissionStatus()
        if !granted && !hasScreenPermission {
            openSystemSettingsPrivacy("Privacy_ScreenCapture")
            statusBanner = "Enable StreamShadows in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen StreamShadows."
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshAllDevices()
            await reconfigureScreenCapture()
        }
    }

    public func requestCameraPermission() {
        guard !isRequestingCameraPermission else { return }
        isRequestingCameraPermission = true
        hasAutoPromptedCamera = true
        Task {
            defer { isRequestingCameraPermission = false }
            let granted = await CaptureManager.requestCameraAccess()
            hasCameraPermission = granted
            if granted {
                cameras = captureManager.listCameras()
                if selectedCameraID == nil { selectedCameraID = cameras.first?.id }
                reconfigureCameraCapture()
            }
        }
    }

    public func requestMicPermission() {
        guard !isRequestingMicPermission else { return }
        isRequestingMicPermission = true
        hasAutoPromptedMic = true
        Task {
            defer { isRequestingMicPermission = false }
            let granted = await CaptureManager.requestMicrophoneAccess()
            hasMicPermission = granted
            if granted {
                microphones = captureManager.listMicrophones()
                if selectedMicID == nil { selectedMicID = microphones.first?.id }
                reconfigureMicCapture()
            }
        }
    }

    public func openSystemSettingsPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    public func refreshAllDevices() async {
        refreshPermissionStatus()
        cameras = captureManager.listCameras()
        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = cameras.first?.id
        }

        microphones = captureManager.listMicrophones()
        if selectedMicID == nil || !microphones.contains(where: { $0.id == selectedMicID }) {
            selectedMicID = microphones.first?.id
        }

        let physicalDisplays = CaptureManager.listConnectedDisplays()
        if !physicalDisplays.isEmpty {
            displays = physicalDisplays
            if selectedDisplayID == nil || !physicalDisplays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = physicalDisplays.first?.id
            }
        }

        do {
            let foundDisplays = try await captureManager.refreshDisplays()
            if !foundDisplays.isEmpty {
                displays = foundDisplays
                if selectedDisplayID == nil || !foundDisplays.contains(where: { $0.id == selectedDisplayID }) {
                    selectedDisplayID = foundDisplays.first?.id
                }
            }
            windows = captureManager.listShareableWindows()
            if selectedWindowID == nil || !windows.contains(where: { $0.id == selectedWindowID }) {
                selectedWindowID = windows.first?.id
            }
            hasScreenPermission = CaptureManager.hasScreenCapturePermission()
        } catch {
            appendLog("Display refresh notice: \(error.localizedDescription)")
        }
    }

    public func selectDisplay(_ id: CGDirectDisplayID?) {
        guard selectedDisplayID != id else { return }
        selectedDisplayID = id
        Task { await reconfigureScreenCapture() }
    }

    public func selectWindow(_ id: CGWindowID?) {
        guard selectedWindowID != id else { return }
        selectedWindowID = id
        Task { await reconfigureScreenCapture() }
    }

    public func selectCamera(_ id: String?) {
        guard selectedCameraID != id else { return }
        selectedCameraID = id
        reconfigureCameraCapture()
    }

    public func selectMicrophone(_ id: String?) {
        guard selectedMicID != id else { return }
        selectedMicID = id
        reconfigureMicCapture()
    }

    // MARK: - Capture Control

    private func reconfigureCaptureSources() async {
        await reconfigureScreenCapture()
        reconfigureCameraCapture()
        reconfigureMicCapture()
    }

    private func reconfigureScreenCapture() async {
        guard isBootstrapped else { return }
        if sourceMode.usesScreen {
            do {
                switch screenTargetMode {
                case .display:
                    guard let displayID = selectedDisplayID else { return }
                    try await captureManager.startScreenCapture(
                        displayID: displayID,
                        width: qualityPreset.width,
                        height: qualityPreset.height,
                        fps: qualityPreset.fps,
                        excludeSelf: excludeSelfFromCapture
                    )
                case .window:
                    guard let winID = selectedWindowID else {
                        await captureManager.stopScreenCapture()
                        return
                    }
                    try await captureManager.startWindowCapture(
                        windowID: winID,
                        width: qualityPreset.width,
                        height: qualityPreset.height,
                        fps: qualityPreset.fps
                    )
                }
                hasScreenPermission = true
                if detectedFFmpegPath != nil {
                    statusBanner = nil
                }
            } catch {
                appendLog("Screen capture error: \(error.localizedDescription)")
                statusBanner = "Grant Screen Recording permission in System Settings to capture your screen."
            }
        } else {
            await captureManager.stopScreenCapture()
        }
    }

    private func reconfigureCameraCapture() {
        guard isBootstrapped else { return }
        if sourceMode.usesCamera, let camID = selectedCameraID {
            let status = CaptureManager.cameraAuthorizationStatus()
            if status == .notDetermined {
                if !hasAutoPromptedCamera {
                    requestCameraPermission()
                }
                return
            }
            guard status == .authorized else {
                statusBanner = "Grant Camera permission to use your webcam."
                return
            }
            do {
                try captureManager.startCameraCapture(deviceID: camID)
            } catch {
                appendLog("Camera error: \(error.localizedDescription)")
            }
        } else {
            captureManager.stopCameraCapture()
        }
    }

    private func reconfigureMicCapture() {
        guard isBootstrapped else { return }
        if micAudioEnabled, let micID = selectedMicID {
            let status = CaptureManager.microphoneAuthorizationStatus()
            if status == .notDetermined {
                if !hasAutoPromptedMic {
                    requestMicPermission()
                }
                return
            }
            guard status == .authorized else { return }
            do {
                try captureManager.startMicrophoneCapture(deviceID: micID)
            } catch {
                appendLog("Microphone error: \(error.localizedDescription)")
            }
        } else {
            captureManager.stopMicrophoneCapture()
        }
    }

    // MARK: - Destination Management (Debounced Keychain + UserDefaults)

    public func updateDestination(_ updated: StreamDestinationConfig) {
        if let idx = destinations.firstIndex(where: { $0.platform == updated.platform }) {
            let platform = updated.platform
            let keyChanged = destinations[idx].streamKey != updated.streamKey
            let enabledChanged = destinations[idx].isEnabled != updated.isEnabled
            destinations[idx] = updated

            if enabledChanged {
                savePreferences()
            }

            destinationSaveTasks[platform]?.cancel()
            destinationSaveTasks[platform] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                self.savePreferences()
                if keyChanged {
                    let status = self.keychain.saveStreamKey(updated.streamKey, for: platform)
                    if status != errSecSuccess && status != errSecItemNotFound {
                        self.appendLog("Keychain save warning for \(platform.displayName): OSStatus \(status)")
                    }
                }
                self.destinationSaveTasks.removeValue(forKey: platform)
            }
        }
    }

    public func resetIngestURL(for platform: StreamingPlatform) {
        if let idx = destinations.firstIndex(where: { $0.platform == platform }) {
            destinations[idx].ingestURL = platform.defaultIngestURL
            savePreferences()
        }
    }

    private func flushPendingDestinationSaves() {
        guard !destinationSaveTasks.isEmpty else { return }
        for (platform, task) in destinationSaveTasks {
            task.cancel()
            if let dest = destinations.first(where: { $0.platform == platform }) {
                let status = keychain.saveStreamKey(dest.streamKey, for: platform)
                if status != errSecSuccess && status != errSecItemNotFound {
                    appendLog("Keychain save warning for \(platform.displayName): OSStatus \(status)")
                }
            }
        }
        destinationSaveTasks.removeAll()
        savePreferences()
    }

    // MARK: - Streaming Control (with Auto-Reconnect)

    public func toggleStream() {
        if streamState.isActive {
            stopStream()
        } else {
            startStream()
        }
    }

    public func startStream() {
        guard !streamState.isActive else { return }
        flushPendingDestinationSaves()

        guard detectedFFmpegPath != nil else {
            streamState = .error(RTMPStreamerError.ffmpegNotFound.localizedDescription)
            return
        }

        guard !readyDestinations.isEmpty else {
            streamState = .error(RTMPStreamerError.noValidDestinations.localizedDescription)
            return
        }

        userRequestedStreamStop = false
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        launchStreamerProcess()
    }

    private func launchStreamerProcess() {
        streamState = .starting
        telemetry = StreamTelemetry()
        elapsedTimeText = "00:00:00"

        do {
            try streamer.start(
                destinations: destinations,
                preset: qualityPreset,
                encoder: encoderPreference,
                customFFmpegPath: customFFmpegPath
            )
            updateSleepAssertion()
            updateCompositorConfig()
            pushAudioMixerSettings()
        } catch {
            streamState = .error(error.localizedDescription)
            updateSleepAssertion()
            updateCompositorConfig()
            pushAudioMixerSettings()
            appendLog("Start failed: \(error.localizedDescription)")
        }
    }

    public func stopStream() {
        guard streamState.isActive else { return }
        userRequestedStreamStop = true
        reconnectTask?.cancel()
        reconnectTask = nil

        if case .reconnecting = streamState {
            streamState = .idle
            updateSleepAssertion()
            updateCompositorConfig()
            pushAudioMixerSettings()
            appendLog("Cancelled auto-reconnect.")
            return
        }

        streamState = .stopping
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        updateSleepAssertion()
        updateCompositorConfig()
        pushAudioMixerSettings()
        streamer.stop()
        appendLog("Stopping stream…")
    }

    private func scheduleReconnect(lastError: String) {
        reconnectAttempt += 1
        guard reconnectAttempt <= maxReconnectAttempts else {
            streamState = .error("\(lastError) (Auto-reconnect exhausted after \(maxReconnectAttempts) attempts.)")
            updateSleepAssertion()
            updateCompositorConfig()
            pushAudioMixerSettings()
            return
        }

        let delaySeconds = min(15, Int(pow(2.0, Double(reconnectAttempt - 1))) * 2)
        streamState = .reconnecting(attempt: reconnectAttempt, maxAttempts: maxReconnectAttempts)
        appendLog("Connection lost (\(lastError)). Reconnecting in \(delaySeconds)s (attempt \(reconnectAttempt)/\(maxReconnectAttempts))…")
        updateCompositorConfig()
        pushAudioMixerSettings()

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled, let self, !self.userRequestedStreamStop else { return }
            self.launchStreamerProcess()
        }
    }

    // MARK: - Recording Control (On-Click Save Panel + Countdown + Pause/Resume)

    public func toggleRecording() {
        if recordingState.isActive {
            stopRecording()
        } else {
            startRecording()
        }
    }

    public func startRecording() {
        guard !recordingState.isActive else { return }

        guard detectedFFmpegPath != nil else {
            recordingState = .error(LocalRecorderError.ffmpegNotFound.localizedDescription)
            return
        }

        let chosenURL: URL
        if askRecordingLocationOnRecord {
            guard let picked = promptForRecordingSaveLocation() else {
                // User cancelled Save dialog
                return
            }
            chosenURL = picked
            recordingDirectoryPath = picked.deletingLastPathComponent().path
        } else {
            let folderURL = URL(fileURLWithPath: recordingDirectoryPath, isDirectory: true)
            chosenURL = LocalRecorder.makeRecordingURL(in: folderURL, format: recordingFormat)
        }

        if recordingCountdownEnabled {
            beginRecordingCountdown(to: chosenURL)
        } else {
            beginRecordingImmediately(to: chosenURL)
        }
    }

    private func promptForRecordingSaveLocation() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Recording As"
        panel.prompt = "Start Recording"
        panel.canCreateDirectories = true

        let defaultDir = URL(fileURLWithPath: recordingDirectoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        panel.directoryURL = defaultDir

        let suggested = LocalRecorder.makeRecordingURL(in: defaultDir, format: recordingFormat)
        panel.nameFieldStringValue = suggested.lastPathComponent
        if let utType = UTType(filenameExtension: recordingFormat.fileExtension) {
            panel.allowedContentTypes = [utType]
        }

        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func beginRecordingCountdown(to fileURL: URL) {
        countdownTask?.cancel()
        recordingState = .countdown(remaining: 3, fileURL: fileURL)
        countdownTask = Task { [weak self] in
            for remaining in stride(from: 3, through: 1, by: -1) {
                guard !Task.isCancelled, let self else { return }
                self.recordingState = .countdown(remaining: remaining, fileURL: fileURL)
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self else { return }
            self.beginRecordingImmediately(to: fileURL)
        }
    }

    private func beginRecordingImmediately(to fileURL: URL) {
        recordingElapsedText = "00:00:00"
        recordingFileSizeText = "0 MB"
        recordingAccumulatedSeconds = 0
        activeRecordingURL = fileURL

        do {
            let savedURL = try recorder.start(
                outputURL: fileURL,
                format: recordingFormat,
                preset: qualityPreset,
                encoder: encoderPreference,
                customFFmpegPath: customFFmpegPath
            )
            let now = Date()
            recordingSegmentStartDate = now
            recordingState = .recording(startedAt: now, fileURL: savedURL)
            startRecordingTimer()
            updateSleepAssertion()
            updateCompositorConfig()
            pushAudioMixerSettings()
        } catch {
            activeRecordingURL = nil
            recordingState = .error(error.localizedDescription)
            updateSleepAssertion()
            updateCompositorConfig()
            pushAudioMixerSettings()
            appendLog("Recording failed to start: \(error.localizedDescription)")
        }
    }

    public func togglePauseRecording() {
        switch recordingState {
        case .recording(let startedAt, let fileURL):
            recordingAccumulatedSeconds += max(0, Date().timeIntervalSince(startedAt))
            recordingSegmentStartDate = nil
            recorder.setPaused(true)
            recordingState = .paused(accumulated: recordingAccumulatedSeconds, fileURL: fileURL)
            updateCompositorConfig()
            pushAudioMixerSettings()
            appendLog("Recording paused.")
        case .paused(_, let fileURL):
            let resumedAt = Date()
            recordingSegmentStartDate = resumedAt
            recorder.setPaused(false)
            recordingState = .recording(startedAt: resumedAt, fileURL: fileURL)
            updateCompositorConfig()
            pushAudioMixerSettings()
            appendLog("Recording resumed.")
        default:
            break
        }
    }

    public func stopRecording() {
        guard recordingState.isActive else { return }
        if recordingState.isCountdown {
            countdownTask?.cancel()
            countdownTask = nil
            recordingState = .idle
            return
        }

        recordingState = .stopping
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingSegmentStartDate = nil
        updateSleepAssertion()
        updateCompositorConfig()
        pushAudioMixerSettings()
        recorder.stop()
        appendLog("Finalizing recording…")
    }

    public func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: recordingDirectoryPath, isDirectory: true)
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let url = panel.url {
            recordingDirectoryPath = url.path
        }
    }

    public func openRecordingsFolder() {
        let url = URL(fileURLWithPath: recordingDirectoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    public func revealLastRecordingInFinder() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func updateSleepAssertion() {
        if streamState.isActive || recordingState.isActive {
            sleepPreventer.beginPreventingSleep()
        } else {
            sleepPreventer.endPreventingSleep()
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    public func refreshFFmpegDetection() {
        detectedFFmpegPath = RTMPStreamer.detectFFmpegPath(customPath: customFFmpegPath)
    }

    // MARK: - Private Wiring

    private func wireCallbacks() {
        captureManager.onScreenVideoFrame = { [weak compositor] pixelBuffer in
            compositor?.updateScreenFrame(pixelBuffer)
        }
        captureManager.onCameraVideoFrame = { [weak compositor] pixelBuffer in
            compositor?.updateCameraFrame(pixelBuffer)
        }
        captureManager.onScreenAudioBuffer = { [weak audioMixer] sampleBuffer in
            audioMixer?.appendSystemAudio(sampleBuffer)
        }
        captureManager.onMicAudioBuffer = { [weak audioMixer] sampleBuffer in
            audioMixer?.appendMicAudio(sampleBuffer)
        }
        captureManager.onCaptureError = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }

        compositor.onPreviewFrame = { [weak self] cgImage in
            Task { @MainActor in
                self?.previewImage = cgImage
            }
        }
        compositor.onEncodedVideoFrame = { [weak streamer, weak recorder] frameBuffer in
            frameBuffer.retain()
            streamer?.writeVideoFrame(frameBuffer)
            recorder?.writeVideoFrame(frameBuffer)
        }

        audioMixer.onMixedPCMFrame = { [weak streamer, weak recorder] pcmData in
            streamer?.writeAudioFrame(pcmData)
            recorder?.writeAudioFrame(pcmData)
        }
        audioMixer.onLevelsUpdated = { [weak self] levels in
            Task { @MainActor in
                self?.audioLevels = levels
            }
        }

        streamer.onTelemetry = { [weak self] stats in
            Task { @MainActor in
                guard let self else { return }
                self.telemetry = stats
                if self.streamState == .starting && stats.framesSent > 0 {
                    self.reconnectAttempt = 0
                    let startTime = Date()
                    self.streamState = .live(startedAt: startTime)
                    self.startUptimeTimer(from: startTime)
                    self.appendLog("RTMP handshake established — stream is LIVE.")
                }
            }
        }
        streamer.onLogLine = { [weak self] line in
            Task { @MainActor in
                self?.appendLog(line)
            }
        }
        streamer.onTerminated = { [weak self] code, errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.uptimeTimer?.invalidate()
                self.uptimeTimer = nil

                if let errorMessage, !self.userRequestedStreamStop, self.autoReconnectEnabled {
                    self.scheduleReconnect(lastError: errorMessage)
                    return
                }

                if let errorMessage {
                    self.streamState = .error(errorMessage)
                    self.appendLog(errorMessage)
                } else {
                    self.streamState = .idle
                    self.appendLog("Stream stopped cleanly (exit \(code)).")
                }
                self.updateSleepAssertion()
                self.updateCompositorConfig()
                self.pushAudioMixerSettings()
            }
        }

        recorder.onLogLine = { [weak self] line in
            Task { @MainActor in
                self?.appendLog(line)
            }
        }
        recorder.onFinished = { [weak self] savedURL, code, errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
                self.activeRecordingURL = nil
                self.recordingFileSizeText = ""

                if let errorMessage {
                    self.recordingState = .error(errorMessage)
                    self.appendLog(errorMessage)
                } else {
                    self.recordingState = .idle
                    if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) {
                        self.lastRecordingURL = savedURL
                        self.appendLog("Recording saved: \(savedURL.path)")
                    } else {
                        self.appendLog("Recording stopped (exit \(code)).")
                    }
                }
                self.updateSleepAssertion()
                self.updateCompositorConfig()
                self.pushAudioMixerSettings()
            }
        }
    }

    private func updateCompositorConfig() {
        var cfg = CompositorConfig()
        cfg.mode = sourceMode
        cfg.pipPosition = pipPosition
        cfg.pipSize = pipSize
        cfg.pipShape = pipShape
        cfg.mirrorCamera = mirrorCamera
        cfg.width = qualityPreset.width
        cfg.height = qualityPreset.height
        cfg.fps = qualityPreset.fps
        cfg.isStreaming = isPipelineProducingFrames
        cfg.isPreviewPaused = isPreviewWindowHidden && !isPipelineProducingFrames
        compositor.updateConfig(cfg)
    }

    private func pushAudioMixerSettings() {
        var s = AudioMixerSettings()
        s.systemAudioEnabled = systemAudioEnabled && sourceMode.usesScreen
        s.systemAudioMuted = systemAudioMuted
        s.systemAudioVolume = systemAudioVolume
        s.micAudioEnabled = micAudioEnabled
        s.micAudioMuted = micAudioMuted
        s.micAudioVolume = micAudioVolume
        s.micNoiseGateThreshold = micNoiseGateThreshold
        s.micDelayMs = micDelayMs
        s.masterMuted = masterMuted
        s.masterVolume = masterVolume
        s.isStreaming = isPipelineProducingFrames
        audioMixer.updateSettings(s)
    }

    private func startUptimeTimer(from startDate: Date) {
        uptimeTimer?.invalidate()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = max(0, Int(Date().timeIntervalSince(startDate)))
                self.elapsedTimeText = Self.formatDuration(elapsed)
            }
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let segment = self.recordingSegmentStartDate.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                let total = Int(self.recordingAccumulatedSeconds + segment)
                self.recordingElapsedText = Self.formatDuration(total)

                if let url = self.activeRecordingURL,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber {
                    self.recordingFileSizeText = LocalRecorder.formatByteCount(size.int64Value)
                }
            }
        }
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d:%02d", hrs, mins, secs)
    }

    private func appendLog(_ message: String) {
        let timestamp = Self.timeFormatter.string(from: Date())
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 250 {
            logs.removeFirst(logs.count - 250)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Persistence

    private func loadPreferences() {
        if let raw = defaults.string(forKey: "sourceMode"), let mode = StreamSourceMode(rawValue: raw) {
            sourceMode = mode
        }
        if let raw = defaults.string(forKey: "screenTargetMode"), let target = ScreenCaptureTargetMode(rawValue: raw) {
            screenTargetMode = target
        }
        if let raw = defaults.string(forKey: "pipPosition"), let pos = PiPPosition(rawValue: raw) {
            pipPosition = pos
        }
        if let raw = defaults.string(forKey: "pipSize"), let sz = PiPSize(rawValue: raw) {
            pipSize = sz
        }
        if let raw = defaults.string(forKey: "pipShape"), let shape = PiPShape(rawValue: raw) {
            pipShape = shape
        }
        if defaults.object(forKey: "mirrorCamera") != nil {
            mirrorCamera = defaults.bool(forKey: "mirrorCamera")
        }
        if defaults.object(forKey: "excludeSelfFromCapture") != nil {
            excludeSelfFromCapture = defaults.bool(forKey: "excludeSelfFromCapture")
        }
        if defaults.object(forKey: "systemAudioEnabled") != nil {
            systemAudioEnabled = defaults.bool(forKey: "systemAudioEnabled")
        }
        if defaults.object(forKey: "systemAudioVolume") != nil {
            systemAudioVolume = defaults.float(forKey: "systemAudioVolume")
        }
        if defaults.object(forKey: "micAudioEnabled") != nil {
            micAudioEnabled = defaults.bool(forKey: "micAudioEnabled")
        }
        if defaults.object(forKey: "micAudioVolume") != nil {
            micAudioVolume = defaults.float(forKey: "micAudioVolume")
        }
        if defaults.object(forKey: "micNoiseGateThreshold") != nil {
            micNoiseGateThreshold = defaults.float(forKey: "micNoiseGateThreshold")
        }
        if defaults.object(forKey: "micDelayMs") != nil {
            micDelayMs = defaults.integer(forKey: "micDelayMs")
        }
        if defaults.object(forKey: "masterVolume") != nil {
            masterVolume = defaults.float(forKey: "masterVolume")
        }
        if let raw = defaults.string(forKey: "qualityPreset"), let preset = VideoQualityPreset(rawValue: raw) {
            qualityPreset = preset
        }
        if let raw = defaults.string(forKey: "encoderPreference"), let enc = VideoEncoderPreference(rawValue: raw) {
            encoderPreference = enc
        }
        if defaults.object(forKey: "autoReconnectEnabled") != nil {
            autoReconnectEnabled = defaults.bool(forKey: "autoReconnectEnabled")
        }
        customFFmpegPath = defaults.string(forKey: "customFFmpegPath") ?? ""
        if let raw = defaults.string(forKey: "recordingFormat"), let fmt = RecordingFormat(rawValue: raw) {
            recordingFormat = fmt
        }
        if let savedDir = defaults.string(forKey: "recordingDirectoryPath"), !savedDir.isEmpty {
            recordingDirectoryPath = savedDir
        }
        if defaults.object(forKey: "askRecordingLocationOnRecord") != nil {
            askRecordingLocationOnRecord = defaults.bool(forKey: "askRecordingLocationOnRecord")
        }
        if defaults.object(forKey: "recordingCountdownEnabled") != nil {
            recordingCountdownEnabled = defaults.bool(forKey: "recordingCountdownEnabled")
        }

        destinations = StreamingPlatform.allCases.map { platform in
            let enabled = defaults.bool(forKey: "dest_enabled_\(platform.rawValue)")
            let url = defaults.string(forKey: "dest_url_\(platform.rawValue)") ?? platform.defaultIngestURL
            let key = keychain.loadStreamKey(for: platform)
            return StreamDestinationConfig(
                platform: platform,
                isEnabled: enabled,
                ingestURL: url,
                streamKey: key
            )
        }
    }

    private func savePreferences() {
        defaults.set(sourceMode.rawValue, forKey: "sourceMode")
        defaults.set(screenTargetMode.rawValue, forKey: "screenTargetMode")
        defaults.set(pipPosition.rawValue, forKey: "pipPosition")
        defaults.set(pipSize.rawValue, forKey: "pipSize")
        defaults.set(pipShape.rawValue, forKey: "pipShape")
        defaults.set(mirrorCamera, forKey: "mirrorCamera")
        defaults.set(excludeSelfFromCapture, forKey: "excludeSelfFromCapture")
        defaults.set(systemAudioEnabled, forKey: "systemAudioEnabled")
        defaults.set(systemAudioVolume, forKey: "systemAudioVolume")
        defaults.set(micAudioEnabled, forKey: "micAudioEnabled")
        defaults.set(micAudioVolume, forKey: "micAudioVolume")
        defaults.set(micNoiseGateThreshold, forKey: "micNoiseGateThreshold")
        defaults.set(micDelayMs, forKey: "micDelayMs")
        defaults.set(masterVolume, forKey: "masterVolume")
        defaults.set(qualityPreset.rawValue, forKey: "qualityPreset")
        defaults.set(encoderPreference.rawValue, forKey: "encoderPreference")
        defaults.set(autoReconnectEnabled, forKey: "autoReconnectEnabled")
        defaults.set(customFFmpegPath, forKey: "customFFmpegPath")
        defaults.set(recordingFormat.rawValue, forKey: "recordingFormat")
        defaults.set(recordingDirectoryPath, forKey: "recordingDirectoryPath")
        defaults.set(askRecordingLocationOnRecord, forKey: "askRecordingLocationOnRecord")
        defaults.set(recordingCountdownEnabled, forKey: "recordingCountdownEnabled")

        for dest in destinations {
            defaults.set(dest.isEnabled, forKey: "dest_enabled_\(dest.platform.rawValue)")
            defaults.set(dest.ingestURL, forKey: "dest_url_\(dest.platform.rawValue)")
        }
    }
}
