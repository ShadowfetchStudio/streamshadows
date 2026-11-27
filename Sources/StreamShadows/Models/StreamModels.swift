import Foundation
import CoreGraphics

public enum StreamSourceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case screenOnly = "screen_only"
    case cameraOnly = "camera_only"
    case screenWithCameraPiP = "screen_with_camera"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenOnly: return "Screen Only"
        case .cameraOnly: return "Camera Only"
        case .screenWithCameraPiP: return "Screen + Cam"
        }
    }

    public var symbolName: String {
        switch self {
        case .screenOnly: return "display"
        case .cameraOnly: return "video"
        case .screenWithCameraPiP: return "pip.enter"
        }
    }

    public var usesScreen: Bool {
        self == .screenOnly || self == .screenWithCameraPiP
    }

    public var usesCamera: Bool {
        self == .cameraOnly || self == .screenWithCameraPiP
    }
}

public enum ScreenCaptureTargetMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case display = "display"
    case window = "window"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .display: return "Full Screen"
        case .window: return "Single Window"
        }
    }
}

public enum PiPPosition: String, CaseIterable, Identifiable, Codable, Sendable {
    case topLeft = "top_left"
    case topRight = "top_right"
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

public enum PiPSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case small = "small"
    case medium = "medium"
    case large = "large"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    public var widthFraction: CGFloat {
        switch self {
        case .small: return 0.18
        case .medium: return 0.25
        case .large: return 0.33
        }
    }
}

public enum PiPShape: String, CaseIterable, Identifiable, Codable, Sendable {
    case rounded = "rounded"
    case circle = "circle"
    case rectangle = "rectangle"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rounded: return "Rounded"
        case .circle: return "Circle"
        case .rectangle: return "Sharp"
        }
    }
}

public enum StreamingPlatform: String, CaseIterable, Identifiable, Codable, Sendable {
    case youtube = "youtube"
    case twitch = "twitch"
    case x = "x"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .twitch: return "Twitch"
        case .x: return "X (Twitter)"
        }
    }

    public var defaultIngestURL: String {
        switch self {
        case .youtube: return "rtmps://a.rtmps.youtube.com/live2/"
        case .twitch: return "rtmp://live.twitch.tv/app/"
        case .x: return "rtmps://va.pscp.tv:443/x/"
        }
    }

    public var setupHint: String {
        switch self {
        case .youtube:
            return "YouTube Studio → Go Live → Copy Stream Key"
        case .twitch:
            return "Twitch Creator Dashboard → Settings → Stream → Primary Stream Key"
        case .x:
            return "X Media Studio → Producer → Sources → Paste assigned RTMP/RTMPS URL & Stream Key"
        }
    }

    public var accentHex: String {
        switch self {
        case .youtube: return "#FF0033"
        case .twitch: return "#9146FF"
        case .x: return "#1D9BF0"
        }
    }
}

public struct StreamDestinationConfig: Identifiable, Equatable, Sendable {
    public let platform: StreamingPlatform
    public var isEnabled: Bool
    public var ingestURL: String
    public var streamKey: String

    public var id: StreamingPlatform { platform }

    public init(
        platform: StreamingPlatform,
        isEnabled: Bool = false,
        ingestURL: String? = nil,
        streamKey: String = ""
    ) {
        self.platform = platform
        self.isEnabled = isEnabled
        self.ingestURL = ingestURL ?? platform.defaultIngestURL
        self.streamKey = streamKey
    }

    public var hasValidIngestURL: Bool {
        let base = ingestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base),
              let scheme = url.scheme?.lowercased(),
              (scheme == "rtmp" || scheme == "rtmps"),
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    public var fullRTMPURL: String? {
        let base = ingestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasValidIngestURL, !key.isEmpty else { return nil }
        if base.hasSuffix("/") {
            return base + key
        } else {
            return base + "/" + key
        }
    }

    public var isReadyToStream: Bool {
        isEnabled && fullRTMPURL != nil
    }
}

public enum VideoQualityPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case p720_30 = "720p30"
    case p720_60 = "720p60"
    case p1080_30 = "1080p30"
    case p1080_60 = "1080p60"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .p720_30: return "720p • 30 fps (3,000 kbps)"
        case .p720_60: return "720p • 60 fps (4,500 kbps)"
        case .p1080_30: return "1080p • 30 fps (4,500 kbps)"
        case .p1080_60: return "1080p • 60 fps (6,000 kbps)"
        }
    }

    public var width: Int {
        switch self {
        case .p720_30, .p720_60: return 1280
        case .p1080_30, .p1080_60: return 1920
        }
    }

    public var height: Int {
        switch self {
        case .p720_30, .p720_60: return 720
        case .p1080_30, .p1080_60: return 1080
        }
    }

    public var fps: Int {
        switch self {
        case .p720_30, .p1080_30: return 30
        case .p720_60, .p1080_60: return 60
        }
    }

    public var videoBitrateKbps: Int {
        switch self {
        case .p720_30: return 3000
        case .p720_60: return 4500
        case .p1080_30: return 4500
        case .p1080_60: return 6000
        }
    }

    public var audioBitrateKbps: Int {
        switch self {
        case .p720_30: return 128
        case .p720_60, .p1080_30, .p1080_60: return 160
        }
    }
}

public enum VideoEncoderPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case hardwareVideoToolbox = "h264_videotoolbox"
    case softwareX264 = "libx264"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hardwareVideoToolbox: return "Apple VideoToolbox (Hardware)"
        case .softwareX264: return "x264 (Software CPU)"
        }
    }
}

public struct DisplayOption: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let width: Int
    public let height: Int

    public var resolutionLabel: String {
        "\(width) × \(height)"
    }
}

public struct WindowOption: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let appName: String
    public let title: String
    public let width: Int
    public let height: Int

    public var displayLabel: String {
        if title.isEmpty || title == appName {
            return appName
        }
        return "\(appName) — \(title)"
    }
}

public struct CaptureDeviceOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public struct AudioLevels: Equatable, Sendable {
    public var systemPeak: Float = 0
    public var micPeak: Float = 0
    public var masterPeak: Float = 0

    public init(systemPeak: Float = 0, micPeak: Float = 0, masterPeak: Float = 0) {
        self.systemPeak = systemPeak
        self.micPeak = micPeak
        self.masterPeak = masterPeak
    }
}

public struct StreamTelemetry: Equatable, Sendable {
    public var fps: String = "0"
    public var bitrate: String = "0 kbps"
    public var speed: String = "0x"
    public var framesSent: Int = 0
    public var droppedFrames: Int = 0
}

public enum StreamState: Equatable, Sendable {
    case idle
    case starting
    case live(startedAt: Date)
    case reconnecting(attempt: Int, maxAttempts: Int)
    case stopping
    case error(String)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .starting, .live, .reconnecting, .stopping:
            return true
        case .idle, .error:
            return false
        }
    }
}

public enum RecordingFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case mp4 = "mp4"
    case mkv = "mkv"
    case mov = "mov"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mp4: return "MP4 (H.264 / AAC)"
        case .mkv: return "MKV (Matroska)"
        case .mov: return "MOV (QuickTime)"
        }
    }

    public var fileExtension: String { rawValue }
}

public enum RecordingState: Equatable, Sendable {
    case idle
    case countdown(remaining: Int, fileURL: URL)
    case recording(startedAt: Date, fileURL: URL)
    case paused(accumulated: TimeInterval, fileURL: URL)
    case stopping
    case error(String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public var isCountdown: Bool {
        if case .countdown = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .countdown, .recording, .paused, .stopping:
            return true
        case .idle, .error:
            return false
        }
    }
}
