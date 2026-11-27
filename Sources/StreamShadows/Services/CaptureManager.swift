import Foundation
import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import AppKit

/// Coordinates macOS ScreenCaptureKit (display video + system audio) and AVFoundation (camera + microphone).
public final class CaptureManager: NSObject, @unchecked Sendable {
    private let stateLock = NSLock()

    private var scStream: SCStream?
    private var availableDisplays: [SCDisplay] = []
    private var availableWindows: [SCWindow] = []
    private var availableApplications: [SCRunningApplication] = []
    private var activeDisplayID: CGDirectDisplayID?
    private var activeWindowID: CGWindowID?
    private var activeDisplayWidth: Int = 0
    private var activeDisplayHeight: Int = 0
    private var activeDisplayFPS: Int = 0
    private var activeExcludeSelf: Bool = true

    private var cameraSession: AVCaptureSession?
    private var activeCameraID: String?
    private var micSession: AVCaptureSession?
    private var activeMicID: String?

    private let screenVideoQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.screen.video", qos: .userInteractive)
    private let screenAudioQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.screen.audio", qos: .userInteractive)
    private let cameraQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.camera.video", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.mic.audio", qos: .userInteractive)

    public var onScreenVideoFrame: (@Sendable (CVPixelBuffer) -> Void)?
    public var onScreenAudioBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    public var onCameraVideoFrame: (@Sendable (CVPixelBuffer) -> Void)?
    public var onMicAudioBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    public var onCaptureError: (@Sendable (String) -> Void)?

    // MARK: - Permissions

    public static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func cameraAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    public static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Device Discovery

    /// Lists all connected physical displays immediately via NSScreen (does not require Screen Recording permission).
    @MainActor
    public static func listConnectedDisplays() -> [DisplayOption] {
        NSScreen.screens.enumerated().compactMap { idx, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let isMain = CGDisplayIsMain(displayID) != 0
            let rawName = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = rawName.isEmpty ? "Display \(idx + 1)" : rawName
            let label = isMain ? "\(baseName) (Main)" : baseName
            let scale = screen.backingScaleFactor
            let pixelWidth = Int((screen.frame.width * scale).rounded())
            let pixelHeight = Int((screen.frame.height * scale).rounded())
            return DisplayOption(
                id: displayID,
                name: label,
                width: pixelWidth,
                height: pixelHeight
            )
        }
    }

    public func refreshDisplays() async throws -> [DisplayOption] {
        let screenDisplays = await MainActor.run { Self.listConnectedDisplays() }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            stateLock.withLock {
                self.availableDisplays = content.displays
                self.availableWindows = content.windows
                self.availableApplications = content.applications
            }

            if !screenDisplays.isEmpty {
                return screenDisplays
            }

            return content.displays.enumerated().map { idx, display in
                let isMain = CGDisplayIsMain(display.displayID) != 0
                let name = isMain ? "Main Display (\(idx + 1))" : "Display \(idx + 1)"
                return DisplayOption(
                    id: display.displayID,
                    name: name,
                    width: display.width,
                    height: display.height
                )
            }
        } catch {
            if !screenDisplays.isEmpty {
                return screenDisplays
            }
            throw error
        }
    }

    public func listShareableWindows() -> [WindowOption] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let windows = stateLock.withLock { availableWindows }
        return windows.compactMap { win in
            guard win.isOnScreen,
                  win.windowLayer == 0,
                  win.frame.width >= 200,
                  win.frame.height >= 120,
                  let app = win.owningApplication,
                  app.processID != myPID else {
                return nil
            }
            let appName = app.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appName.isEmpty else { return nil }
            let title = (win.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return WindowOption(
                id: win.windowID,
                appName: appName,
                title: title,
                width: Int(win.frame.width),
                height: Int(win.frame.height)
            )
        }
    }

    public func listCameras() -> [CaptureDeviceOption] {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map {
            CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    public func listMicrophones() -> [CaptureDeviceOption] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map {
            CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    // MARK: - Screen Capture

    /// Always captures system audio alongside screen video so enabling/muting Desktop Sound in AudioMixer never glitches video.
    public func startScreenCapture(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, excludeSelf: Bool) async throws {
        let alreadyMatching = stateLock.withLock {
            scStream != nil
                && activeWindowID == nil
                && activeDisplayID == displayID
                && activeDisplayWidth == width
                && activeDisplayHeight == height
                && activeDisplayFPS == fps
                && activeExcludeSelf == excludeSelf
        }

        if alreadyMatching {
            return
        }

        await stopScreenCapture()

        let needsRefresh = stateLock.withLock {
            availableDisplays.isEmpty
                || !availableDisplays.contains(where: { $0.displayID == displayID })
                || (excludeSelf && availableApplications.isEmpty)
        }

        if needsRefresh {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            stateLock.withLock {
                self.availableDisplays = content.displays
                self.availableApplications = content.applications
            }
        }

        let (targetDisplay, apps) = stateLock.withLock {
            (
                availableDisplays.first(where: { $0.displayID == displayID }) ?? availableDisplays.first,
                availableApplications
            )
        }

        guard let targetDisplay else {
            throw NSError(domain: "StreamShadows", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No display available to capture. Grant Screen Recording permission in System Settings."
            ])
        }

        let filter: SCContentFilter
        if excludeSelf {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let excludedApps = apps.filter { $0.processID == myPID }
            filter = SCContentFilter(display: targetDisplay, excludingApplications: excludedApps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 5
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenVideoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: screenAudioQueue)

        try await stream.startCapture()

        stateLock.withLock {
            self.scStream = stream
            self.activeDisplayID = targetDisplay.displayID
            self.activeWindowID = nil
            self.activeDisplayWidth = width
            self.activeDisplayHeight = height
            self.activeDisplayFPS = fps
            self.activeExcludeSelf = excludeSelf
        }
    }

    /// Captures a single application window via ScreenCaptureKit.
    public func startWindowCapture(windowID: CGWindowID, width: Int, height: Int, fps: Int) async throws {
        let alreadyMatching = stateLock.withLock {
            scStream != nil
                && activeWindowID == windowID
                && activeDisplayWidth == width
                && activeDisplayHeight == height
                && activeDisplayFPS == fps
        }
        if alreadyMatching { return }

        await stopScreenCapture()

        let needsRefresh = stateLock.withLock {
            !availableWindows.contains(where: { $0.windowID == windowID })
        }
        if needsRefresh {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            stateLock.withLock {
                self.availableDisplays = content.displays
                self.availableWindows = content.windows
                self.availableApplications = content.applications
            }
        }

        let targetWindow = stateLock.withLock {
            availableWindows.first(where: { $0.windowID == windowID })
        }
        guard let targetWindow else {
            throw NSError(domain: "StreamShadows", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Selected window is no longer available."
            ])
        }

        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 5
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenVideoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: screenAudioQueue)

        try await stream.startCapture()

        stateLock.withLock {
            self.scStream = stream
            self.activeDisplayID = nil
            self.activeWindowID = targetWindow.windowID
            self.activeDisplayWidth = width
            self.activeDisplayHeight = height
            self.activeDisplayFPS = fps
        }
    }

    public func stopScreenCapture() async {
        let stream: SCStream? = stateLock.withLock {
            let current = scStream
            scStream = nil
            activeDisplayID = nil
            activeWindowID = nil
            return current
        }

        if let stream {
            try? await stream.stopCapture()
        }
    }

    // MARK: - Camera Capture

    public func startCameraCapture(deviceID: String) throws {
        stateLock.lock()
        let alreadyMatching = cameraSession != nil && activeCameraID == deviceID
        stateLock.unlock()
        if alreadyMatching {
            return
        }
        stopCameraCapture()

        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw NSError(domain: "StreamShadows", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Selected camera is no longer available."
            ])
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "StreamShadows", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not attach camera input."
            ])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: cameraQueue)

        guard session.canAddOutput(output) else {
            throw NSError(domain: "StreamShadows", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Could not attach camera video output."
            ])
        }
        session.addOutput(output)
        session.commitConfiguration()

        stateLock.lock()
        self.cameraSession = session
        self.activeCameraID = deviceID
        stateLock.unlock()

        cameraQueue.async {
            session.startRunning()
        }
    }

    public func stopCameraCapture() {
        stateLock.lock()
        let session = cameraSession
        cameraSession = nil
        activeCameraID = nil
        stateLock.unlock()

        if let session {
            cameraQueue.async {
                if session.isRunning {
                    session.stopRunning()
                }
            }
        }
    }

    // MARK: - Microphone Capture

    public func startMicrophoneCapture(deviceID: String) throws {
        stateLock.lock()
        let alreadyMatching = micSession != nil && activeMicID == deviceID
        stateLock.unlock()
        if alreadyMatching {
            return
        }
        stopMicrophoneCapture()

        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw NSError(domain: "StreamShadows", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Selected microphone is no longer available."
            ])
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "StreamShadows", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Could not attach microphone input."
            ])
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Request canonical 48kHz stereo Float32 PCM so 24-bit/32-bit USB & XLR interfaces convert cleanly in CoreAudio
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: micQueue)

        guard session.canAddOutput(output) else {
            throw NSError(domain: "StreamShadows", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Could not attach microphone audio output."
            ])
        }
        session.addOutput(output)
        session.commitConfiguration()

        stateLock.lock()
        self.micSession = session
        self.activeMicID = deviceID
        stateLock.unlock()

        micQueue.async {
            session.startRunning()
        }
    }

    public func stopMicrophoneCapture() {
        stateLock.lock()
        let session = micSession
        micSession = nil
        activeMicID = nil
        stateLock.unlock()

        if let session {
            micQueue.async {
                if session.isRunning {
                    session.stopRunning()
                }
            }
        }
    }

    public func stopAll() async {
        await stopScreenCapture()
        stopCameraCapture()
        stopMicrophoneCapture()
    }
}

// MARK: - SCStreamOutput & SCStreamDelegate

extension CaptureManager: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                onScreenVideoFrame?(pixelBuffer)
            }
        case .audio:
            onScreenAudioBuffer?(sampleBuffer)
        case .microphone:
            onMicAudioBuffer?(sampleBuffer)
        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.withLock {
            if self.scStream === stream {
                self.scStream = nil
                self.activeDisplayID = nil
                self.activeWindowID = nil
            }
        }
        onCaptureError?("Screen capture stopped: \(error.localizedDescription)")
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        if output is AVCaptureVideoDataOutput {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                onCameraVideoFrame?(pixelBuffer)
            }
        } else if output is AVCaptureAudioDataOutput {
            onMicAudioBuffer?(sampleBuffer)
        }
    }
}
