import Foundation
import Darwin

public enum RTMPStreamerError: LocalizedError, Sendable {
    case ffmpegNotFound
    case noValidDestinations
    case pipeCreationFailed(String)
    case processFailedToStart(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg was not found. Install FFmpeg (e.g. `brew install ffmpeg`) or set its path in the Output tab."
        case .noValidDestinations:
            return "Enable at least one streaming platform (YouTube, Twitch, or X) with a valid rtmp:// or rtmps:// URL and stream key."
        case .pipeCreationFailed(let msg):
            return "Failed to initialize media pipes: \(msg)"
        case .processFailedToStart(let msg):
            return "Failed to launch FFmpeg encoder: \(msg)"
        }
    }
}

/// Manages FFmpeg hardware/software encoding and RTMP(S) output to one or multiple platforms.
public final class RTMPStreamer: @unchecked Sendable {
    public static let maxPendingVideoFrames = 2
    public static let maxPendingAudioFrames = 12

    private let lock = NSLock()
    private var process: Process?
    private var tempDirURL: URL?

    private var videoFD: Int32 = -1
    private var audioFD: Int32 = -1
    private var isStopping = true
    private var secretsToRedact: [String] = []

    private var pendingVideoFrames: Int = 0
    private var pendingAudioFrames: Int = 0
    public private(set) var droppedVideoFrames: Int = 0

    private let videoWriteQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.rtmp.video", qos: .userInteractive)
    private let audioWriteQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.rtmp.audio", qos: .userInteractive)

    public var onTelemetry: (@Sendable (StreamTelemetry) -> Void)?
    public var onLogLine: (@Sendable (String) -> Void)?
    public var onTerminated: (@Sendable (Int32, String?) -> Void)?

    public init() {
        // Ignore SIGPIPE so writing to a closed FFmpeg FIFO returns EPIPE instead of terminating the app
        signal(SIGPIPE, SIG_IGN)
    }

    public static func detectFFmpegPath(customPath: String = "") -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let trimmedCustom = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            candidates.append(trimmedCustom)
        }
        if let bundlePath = Bundle.main.resourcePath {
            candidates.append("\(bundlePath)/ffmpeg")
        }
        candidates.append(contentsOf: [
            "\(home)/.local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ])

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let candidate = "\(dir)/ffmpeg"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Escapes special characters for FFmpeg's `tee` muxer target syntax.
    public static func escapeTeeTarget(_ target: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(target.count + 8)
        for ch in target {
            switch ch {
            case "\\", "|", "[", "]", "'":
                escaped.append("\\")
                escaped.append(ch)
            default:
                escaped.append(ch)
            }
        }
        return escaped
    }

    public static func buildFFmpegArguments(
        videoPipePath: String,
        audioPipePath: String,
        preset: VideoQualityPreset,
        encoder: VideoEncoderPreference,
        destinationURLs: [String]
    ) -> [String] {
        var args: [String] = [
            "-hide_banner",
            "-loglevel", "warning",
            "-stats",
            // Video raw input
            "-thread_queue_size", "512",
            "-f", "rawvideo",
            "-pix_fmt", "bgra",
            "-s", "\(preset.width)x\(preset.height)",
            "-r", "\(preset.fps)",
            "-i", videoPipePath,
            // Audio raw input
            "-thread_queue_size", "512",
            "-f", "s16le",
            "-ar", "48000",
            "-ac", "2",
            "-i", audioPipePath,
            // Video encoding
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", encoder.rawValue,
            "-pix_fmt", "yuv420p",
            "-r", "\(preset.fps)",
            "-g", "\(preset.fps * 2)",
            "-b:v", "\(preset.videoBitrateKbps)k",
            "-maxrate", "\(preset.videoBitrateKbps)k",
            "-bufsize", "\(preset.videoBitrateKbps * 2)k"
        ]

        if encoder == .hardwareVideoToolbox {
            args.append(contentsOf: ["-realtime", "true"])
        } else {
            args.append(contentsOf: ["-preset", "veryfast", "-tune", "zerolatency"])
        }

        // Audio encoding
        args.append(contentsOf: [
            "-c:a", "aac",
            "-b:a", "\(preset.audioBitrateKbps)k",
            "-ar", "48000",
            "-ac", "2"
        ])

        if destinationURLs.count == 1, let onlyURL = destinationURLs.first {
            args.append(contentsOf: [
                "-f", "flv",
                onlyURL
            ])
        } else {
            args.append(contentsOf: ["-flags", "+global_header"])
            let teeTargets = destinationURLs
                .map { "[f=flv:onfail=ignore]\(escapeTeeTarget($0))" }
                .joined(separator: "|")
            args.append(contentsOf: [
                "-f", "tee",
                teeTargets
            ])
        }

        return args
    }

    public static func redactSecrets(in text: String, secrets: [String]) -> String {
        var sanitized = text
        for secret in secrets where !secret.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: secret, with: "••••••••")
        }
        return sanitized
    }

    public func start(
        destinations: [StreamDestinationConfig],
        preset: VideoQualityPreset,
        encoder: VideoEncoderPreference,
        customFFmpegPath: String = ""
    ) throws {
        guard let ffmpegPath = Self.detectFFmpegPath(customPath: customFFmpegPath) else {
            throw RTMPStreamerError.ffmpegNotFound
        }

        let activeDestinations = destinations.filter { $0.isReadyToStream }
        let urls = activeDestinations.compactMap { $0.fullRTMPURL }
        guard !urls.isEmpty else {
            throw RTMPStreamerError.noValidDestinations
        }

        let secrets = activeDestinations.map { $0.streamKey.trimmingCharacters(in: .whitespacesAndNewlines) }

        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamshadows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let videoPipeURL = sessionDir.appendingPathComponent("video.fifo")
        let audioPipeURL = sessionDir.appendingPathComponent("audio.fifo")

        guard mkfifo(videoPipeURL.path, 0o600) == 0 else {
            throw RTMPStreamerError.pipeCreationFailed("video FIFO errno=\(errno)")
        }
        guard mkfifo(audioPipeURL.path, 0o600) == 0 else {
            throw RTMPStreamerError.pipeCreationFailed("audio FIFO errno=\(errno)")
        }

        let args = Self.buildFFmpegArguments(
            videoPipePath: videoPipeURL.path,
            audioPipePath: audioPipeURL.path,
            preset: preset,
            encoder: encoder,
            destinationURLs: urls
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = FileHandle.nullDevice

        lock.lock()
        self.process = proc
        self.tempDirURL = sessionDir
        self.isStopping = false
        self.secretsToRedact = secrets
        self.pendingVideoFrames = 0
        self.pendingAudioFrames = 0
        self.droppedVideoFrames = 0
        lock.unlock()

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            self?.handleStderrChunk(chunk)
        }

        proc.terminationHandler = { [weak self] terminatedProc in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let code = terminatedProc.terminationStatus
            let wasStopping: Bool
            self.lock.lock()
            wasStopping = self.isStopping
            self.isStopping = true
            self.lock.unlock()

            self.cleanupPipesAndTempDir()
            let message: String? = (!wasStopping && code != 0)
                ? "Stream encoder exited unexpectedly (code \(code)). Check your stream key, ingest URL, and internet connection."
                : nil
            self.onTerminated?(code, message)
        }

        do {
            try proc.run()
        } catch {
            cleanupPipesAndTempDir()
            throw RTMPStreamerError.processFailedToStart(error.localizedDescription)
        }

        onLogLine?("Starting \(encoder.title) stream (\(preset.width)x\(preset.height) @ \(preset.fps)fps) to \(activeDestinations.map(\.platform.displayName).joined(separator: ", "))…")

        // Open both FIFOs non-blocking with a bounded retry loop so an early ffmpeg crash never deadlocks the queues
        let vPath = videoPipeURL.path
        let aPath = audioPipeURL.path
        videoWriteQueue.async { [weak self] in
            self?.openFIFOWithRetry(path: vPath, process: proc, isVideo: true)
        }
        audioWriteQueue.async { [weak self] in
            self?.openFIFOWithRetry(path: aPath, process: proc, isVideo: false)
        }
    }

    private func openFIFOWithRetry(path: String, process: Process, isVideo: Bool) {
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            lock.lock()
            let stopping = isStopping
            lock.unlock()
            if stopping || !process.isRunning {
                return
            }

            let fd = Darwin.open(path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                // Switch to blocking writes once reader has opened the FIFO
                let flags = fcntl(fd, F_GETFL, 0)
                if flags >= 0 {
                    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                }

                lock.lock()
                if isStopping {
                    lock.unlock()
                    Darwin.close(fd)
                } else {
                    if isVideo {
                        self.videoFD = fd
                    } else {
                        self.audioFD = fd
                    }
                    lock.unlock()
                }
                return
            }

            // ENXIO means ffmpeg hasn't opened the read end yet; retry shortly
            if errno == ENXIO || errno == EINTR {
                usleep(10_000) // 10ms
                continue
            } else {
                return
            }
        }
    }

    /// Writes a pooled BGRA video frame with backpressure dropping if the FIFO lags.
    public func writeVideoFrame(_ buffer: PooledFrameBuffer) {
        lock.lock()
        let stopping = isStopping
        if stopping || pendingVideoFrames >= Self.maxPendingVideoFrames {
            if !stopping {
                droppedVideoFrames += 1
            }
            lock.unlock()
            buffer.recycle()
            return
        }
        pendingVideoFrames += 1
        lock.unlock()

        videoWriteQueue.async { [weak self] in
            defer {
                if let self {
                    self.lock.lock()
                    self.pendingVideoFrames = max(0, self.pendingVideoFrames - 1)
                    self.lock.unlock()
                }
                buffer.recycle()
            }
            guard let self else { return }
            self.lock.lock()
            let fd = self.videoFD
            let stopping = self.isStopping
            self.lock.unlock()
            guard fd >= 0, !stopping else { return }
            Self.writeAll(fd: fd, base: buffer.pointer, count: buffer.byteCount)
        }
    }

    /// Writes mixed s16le stereo PCM audio with bounded queue backpressure.
    public func writeAudioFrame(_ data: Data) {
        lock.lock()
        let stopping = isStopping
        if stopping || pendingAudioFrames >= Self.maxPendingAudioFrames {
            lock.unlock()
            return
        }
        pendingAudioFrames += 1
        lock.unlock()

        audioWriteQueue.async { [weak self] in
            defer {
                if let self {
                    self.lock.lock()
                    self.pendingAudioFrames = max(0, self.pendingAudioFrames - 1)
                    self.lock.unlock()
                }
            }
            guard let self else { return }
            self.lock.lock()
            let fd = self.audioFD
            let stopping = self.isStopping
            self.lock.unlock()
            guard fd >= 0, !stopping else { return }
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                Self.writeAll(fd: fd, base: base, count: rawBuffer.count)
            }
        }
    }

    public func stop() {
        lock.lock()
        isStopping = true
        let proc = process
        let vfd = videoFD
        let afd = audioFD
        videoFD = -1
        audioFD = -1
        lock.unlock()

        if vfd >= 0 { Darwin.close(vfd) }
        if afd >= 0 { Darwin.close(afd) }

        if let proc, proc.isRunning {
            proc.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        } else {
            cleanupPipesAndTempDir()
        }
    }

    private func cleanupPipesAndTempDir() {
        lock.lock()
        let vfd = videoFD
        let afd = audioFD
        videoFD = -1
        audioFD = -1
        let dir = tempDirURL
        tempDirURL = nil
        process = nil
        lock.unlock()

        if vfd >= 0 { Darwin.close(vfd) }
        if afd >= 0 { Darwin.close(afd) }
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func writeAll(fd: Int32, base: UnsafeRawPointer, count: Int) {
        var totalWritten = 0
        while totalWritten < count {
            let written = Darwin.write(fd, base.advanced(by: totalWritten), count - totalWritten)
            if written < 0 {
                if errno == EINTR { continue }
                break
            }
            if written == 0 {
                break
            }
            totalWritten += written
        }
    }

    private func handleStderrChunk(_ chunk: String) {
        lock.lock()
        let secrets = secretsToRedact
        let dropped = droppedVideoFrames
        lock.unlock()

        let sanitized = Self.redactSecrets(in: chunk, secrets: secrets)
        let lines = sanitized
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.contains("frame=") && line.contains("fps=") {
                if var telemetry = Self.parseProgressLine(line) {
                    telemetry.droppedFrames = dropped
                    onTelemetry?(telemetry)
                }
            } else {
                onLogLine?(line)
            }
        }
    }

    public static func parseProgressLine(_ line: String) -> StreamTelemetry? {
        var telemetry = StreamTelemetry()
        let pattern = #"(\w+)=\s*([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: nsRange)

        var matched = false
        for match in matches {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valRange = Range(match.range(at: 2), in: line) else { continue }
            let key = String(line[keyRange])
            let val = String(line[valRange])
            switch key {
            case "frame":
                telemetry.framesSent = Int(val) ?? 0
                matched = true
            case "fps":
                telemetry.fps = val
                matched = true
            case "bitrate":
                telemetry.bitrate = val
                matched = true
            case "speed":
                telemetry.speed = val
                matched = true
            default:
                break
            }
        }
        return matched ? telemetry : nil
    }
}
