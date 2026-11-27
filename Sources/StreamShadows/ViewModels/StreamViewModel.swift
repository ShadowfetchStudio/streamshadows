import Foundation
import SwiftUI
import AppKit
import CoreGraphics

@MainActor
public final class StreamViewModel: ObservableObject {
    // MARK: - Devices & Permissions
    @Published public var displays: [DisplayOption] = []
    @Published public var selectedDisplayID: CGDirectDisplayID?

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

    @Published public var mirrorCamera: Bool = true {
        didSet {
            savePreferences()
            updateCompositorConfig()
        }
    }

    // MARK: - Audio Mixer
    @Published public var systemAudioEnabled: Bool = true {
        didSet {
            savePreferences()
            pushAudioMixerSettings()
            Task { await reconfigureScreenCapture() }
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

    @Published public var customFFmpegPath: String = "" {
        didSet {
            savePreferences()
            refreshFFmpegDetection()
        }
    }

    @Published public var detectedFFmpegPath: String?

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
    private let keychain = KeychainStore()
    private let defaults = UserDefaults.standard

    private var uptimeTimer: Timer?
    private var isBootstrapped = false

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

    // MARK: - Lifecycle

    public func bootstrap() async {
        guard !isBootstrapped else { return }
        isBootstrapped = true

        refreshPermissionStatus()
        await refreshAllDevices()

        updateCompositorConfig()
        pushAudioMixerSettings()

        compositor.start()
        audioMixer.start()
        await reconfigureCaptureSources()
    }

    public func shutdown() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        streamer.stop()
        compositor.stop()
        audioMixer.stop()
        Task {
            await captureManager.stopAll()
        }
    }

    // MARK: - Permissions & Device Discovery

    public func refreshPermissionStatus() {
        hasScreenPermission = CaptureManager.hasScreenCapturePermission()
        hasCameraPermission = CaptureManager.cameraAuthorizationStatus() == .authorized
        hasMicPermission = CaptureManager.microphoneAuthorizationStatus() == .authorized
    }

    public func requestScreenPermission() {
        CaptureManager.requestScreenCapturePermission()
        refreshPermissionStatus()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshAllDevices()
            await reconfigureScreenCapture()
        }
    }

    public func requestCameraPermission() {
        Task {
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
        Task {
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

        do {
            let foundDisplays = try await captureManager.refreshDisplays()
            displays = foundDisplays
            if selectedDisplayID == nil || !foundDisplays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = foundDisplays.first?.id
            }
            hasScreenPermission = true
        } catch {
            appendLog("Display refresh notice: \(error.localizedDescription)")
        }
    }

    public func selectDisplay(_ id: CGDirectDisplayID?) {
        selectedDisplayID = id
        Task { await reconfigureScreenCapture() }
    }

    public func selectCamera(_ id: String?) {
        selectedCameraID = id
        reconfigureCameraCapture()
    }

    public func selectMicrophone(_ id: String?) {
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
        if sourceMode.usesScreen, let displayID = selectedDisplayID {
            do {
                try await captureManager.startScreenCapture(
                    displayID: displayID,
                    width: qualityPreset.width,
                    height: qualityPreset.height,
                    fps: qualityPreset.fps,
                    captureSystemAudio: systemAudioEnabled
                )
                statusBanner = nil
            } catch {
                appendLog("Screen capture error: \(error.localizedDescription)")
                statusBanner = "Grant Screen Recording permission in System Settings to capture your display."
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
                requestCameraPermission()
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
                requestMicPermission()
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

    // MARK: - Destination Management

    public func updateDestination(_ updated: StreamDestinationConfig) {
        if let idx = destinations.firstIndex(where: { $0.platform == updated.platform }) {
            destinations[idx] = updated
            keychain.saveStreamKey(updated.streamKey, for: updated.platform)
            savePreferences()
        }
    }

    public func resetIngestURL(for platform: StreamingPlatform) {
        if let idx = destinations.firstIndex(where: { $0.platform == platform }) {
            destinations[idx].ingestURL = platform.defaultIngestURL
            savePreferences()
        }
    }

    // MARK: - Streaming Control

    public func toggleStream() {
        if streamState.isActive {
            stopStream()
        } else {
            startStream()
        }
    }

    public func startStream() {
        guard !streamState.isActive else { return }

        guard detectedFFmpegPath != nil else {
            streamState = .error(RTMPStreamerError.ffmpegNotFound.localizedDescription)
            return
        }

        guard !readyDestinations.isEmpty else {
            streamState = .error(RTMPStreamerError.noValidDestinations.localizedDescription)
            return
        }

        streamState = .starting
        telemetry = StreamTelemetry()
        elapsedTimeText = "00:00:00"
        statusBanner = nil

        do {
            try streamer.start(
                destinations: destinations,
                preset: qualityPreset,
                encoder: encoderPreference,
                customFFmpegPath: customFFmpegPath
            )
            let startTime = Date()
            streamState = .live(startedAt: startTime)
            updateCompositorConfig()
            startUptimeTimer(from: startTime)
        } catch {
            streamState = .error(error.localizedDescription)
            appendLog("Start failed: \(error.localizedDescription)")
        }
    }

    public func stopStream() {
        guard streamState.isActive else { return }
        streamState = .stopping
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        updateCompositorConfig()
        streamer.stop()
        appendLog("Stopping stream…")
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
        compositor.onEncodedVideoFrame = { [weak streamer] frameData in
            streamer?.writeVideoFrame(frameData)
        }

        audioMixer.onMixedPCMFrame = { [weak streamer] pcmData in
            streamer?.writeAudioFrame(pcmData)
        }
        audioMixer.onLevelsUpdated = { [weak self] levels in
            Task { @MainActor in
                self?.audioLevels = levels
            }
        }

        streamer.onTelemetry = { [weak self] stats in
            Task { @MainActor in
                self?.telemetry = stats
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
                if let errorMessage {
                    self.streamState = .error(errorMessage)
                    self.appendLog(errorMessage)
                } else {
                    self.streamState = .idle
                    self.appendLog("Stream stopped cleanly (exit \(code)).")
                }
                self.updateCompositorConfig()
            }
        }
    }

    private func updateCompositorConfig() {
        var cfg = CompositorConfig()
        cfg.mode = sourceMode
        cfg.pipPosition = pipPosition
        cfg.pipSize = pipSize
        cfg.mirrorCamera = mirrorCamera
        cfg.width = qualityPreset.width
        cfg.height = qualityPreset.height
        cfg.fps = qualityPreset.fps
        cfg.isStreaming = streamState.isLive
        compositor.updateConfig(cfg)
    }

    private func pushAudioMixerSettings() {
        var s = AudioMixerSettings()
        s.systemAudioEnabled = systemAudioEnabled
        s.systemAudioMuted = systemAudioMuted
        s.systemAudioVolume = systemAudioVolume
        s.micAudioEnabled = micAudioEnabled
        s.micAudioMuted = micAudioMuted
        s.micAudioVolume = micAudioVolume
        s.masterMuted = masterMuted
        s.masterVolume = masterVolume
        audioMixer.updateSettings(s)
    }

    private func startUptimeTimer(from startDate: Date) {
        uptimeTimer?.invalidate()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = max(0, Int(Date().timeIntervalSince(startDate)))
                let hrs = elapsed / 3600
                let mins = (elapsed % 3600) / 60
                let secs = elapsed % 60
                self.elapsedTimeText = String(format: "%02d:%02d:%02d", hrs, mins, secs)
            }
        }
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
        if let raw = defaults.string(forKey: "pipPosition"), let pos = PiPPosition(rawValue: raw) {
            pipPosition = pos
        }
        if let raw = defaults.string(forKey: "pipSize"), let sz = PiPSize(rawValue: raw) {
            pipSize = sz
        }
        if defaults.object(forKey: "mirrorCamera") != nil {
            mirrorCamera = defaults.bool(forKey: "mirrorCamera")
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
        if defaults.object(forKey: "masterVolume") != nil {
            masterVolume = defaults.float(forKey: "masterVolume")
        }
        if let raw = defaults.string(forKey: "qualityPreset"), let preset = VideoQualityPreset(rawValue: raw) {
            qualityPreset = preset
        }
        if let raw = defaults.string(forKey: "encoderPreference"), let enc = VideoEncoderPreference(rawValue: raw) {
            encoderPreference = enc
        }
        customFFmpegPath = defaults.string(forKey: "customFFmpegPath") ?? ""

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
        defaults.set(pipPosition.rawValue, forKey: "pipPosition")
        defaults.set(pipSize.rawValue, forKey: "pipSize")
        defaults.set(mirrorCamera, forKey: "mirrorCamera")
        defaults.set(systemAudioEnabled, forKey: "systemAudioEnabled")
        defaults.set(systemAudioVolume, forKey: "systemAudioVolume")
        defaults.set(micAudioEnabled, forKey: "micAudioEnabled")
        defaults.set(micAudioVolume, forKey: "micAudioVolume")
        defaults.set(masterVolume, forKey: "masterVolume")
        defaults.set(qualityPreset.rawValue, forKey: "qualityPreset")
        defaults.set(encoderPreference.rawValue, forKey: "encoderPreference")
        defaults.set(customFFmpegPath, forKey: "customFFmpegPath")

        for dest in destinations {
            defaults.set(dest.isEnabled, forKey: "dest_enabled_\(dest.platform.rawValue)")
            defaults.set(dest.ingestURL, forKey: "dest_url_\(dest.platform.rawValue)")
        }
    }
}
