import Foundation
import Darwin

public enum LocalRecorderError: LocalizedError, Sendable {
    case ffmpegNotFound
    case directoryCreationFailed(String)
    case insufficientDiskSpace(String)
    case pipeCreationFailed(String)
    case processFailedToStart(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg was not found. Install FFmpeg (e.g. `brew install ffmpeg`) or set its path in the Output tab."
        case .directoryCreationFailed(let msg):
            return "Could not create recordings folder: \(msg)"
        case .insufficientDiskSpace(let msg):
            return msg
        case .pipeCreationFailed(let msg):
            return "Failed to initialize recorder media pipes: \(msg)"
        case .processFailedToStart(let msg):
            return "Failed to launch FFmpeg recorder: \(msg)"
        }
    }
}

/// Records the composited video and mixed stereo audio directly to local MP4, MKV, or MOV files.
/// Features synchronized dual-FIFO gating, pause/resume, disk-space checks, and graceful EOF finalization.
public final class LocalRecorder: @unchecked Sendable {
    public static let maxPendingVideoFrames = 3
    public static let maxPendingAudioFrames = 16
    public static let minimumFreeDiskBytes: Int64 = 150 * 1024 * 1024 // 150 MB

    private let lock = NSLock()
    private var process: Process?
    private var tempDirURL: URL?
    private var currentOutputURL: URL?

    private var videoFD: Int32 = -1
    private var audioFD: Int32 = -1
    private var isStopping = true
    private var isPaused = false
    private var lastErrorLine: String?

    private var pendingVideoFrames: Int = 0
    private var pendingAudioFrames: Int = 0
    public private(set) var droppedVideoFrames: Int = 0

    private let videoWriteQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.recorder.video", qos: .userInteractive)
    private let audioWriteQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.recorder.audio", qos: .userInteractive)

    public var onLogLine: (@Sendable (String) -> Void)?
    public var onFinished: (@Sendable (URL?, Int32, String?) -> Void)?

    public init() {
        signal(SIGPIPE, SIG_IGN)
    }

    public static func defaultRecordingsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("StreamShadows", isDirectory: true)
    }

    public static func makeRecordingURL(in directory: URL, format: RecordingFormat, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: date)
        return directory.appendingPathComponent("StreamShadows_\(stamp).\(format.fileExtension)")
    }

    public static func availableDiskSpaceBytes(for directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    public static func buildFFmpegArguments(
        videoPipePath: String,
        audioPipePath: String,
        preset: VideoQualityPreset,
        encoder: VideoEncoderPreference,
        format: RecordingFormat,
        outputPath: String
    ) -> [String] {
        let recordBitrateKbps = max(preset.videoBitrateKbps, preset.width >= 1920 ? 8000 : 5000)

        var args: [String] = [
            "-hide_banner",
            "-loglevel", "warning",
            "-y",
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
            // Mapping
            "-map", "0:v:0",
            "-map", "1:a:0",
            // Video encoding
            "-c:v", encoder.rawValue,
            "-pix_fmt", "yuv420p",
            "-r", "\(preset.fps)",
            "-g", "\(preset.fps * 2)",
            "-b:v", "\(recordBitrateKbps)k"
        ]

        if encoder == .hardwareVideoToolbox {
            args.append(contentsOf: ["-realtime", "true"])
        } else {
            args.append(contentsOf: ["-preset", "veryfast", "-crf", "20"])
        }

        // Audio encoding
        args.append(contentsOf: [
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-ac", "2"
        ])

        if format == .mp4 || format == .mov {
            args.append(contentsOf: ["-movflags", "+frag_keyframe+empty_moov+default_base_moof"])
        }

        args.append(outputPath)
        return args
    }

    public func setPaused(_ paused: Bool) {
        lock.withLock {
            self.isPaused = paused
        }
    }

    @discardableResult
    public func start(
        outputURL: URL,
        format: RecordingFormat,
        preset: VideoQualityPreset,
        encoder: VideoEncoderPreference,
        customFFmpegPath: String = ""
    ) throws -> URL {
        guard let ffmpegPath = RTMPStreamer.detectFFmpegPath(customPath: customFFmpegPath) else {
            throw LocalRecorderError.ffmpegNotFound
        }

        let parentDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            throw LocalRecorderError.directoryCreationFailed(error.localizedDescription)
        }

        if let freeBytes = Self.availableDiskSpaceBytes(for: parentDir), freeBytes < Self.minimumFreeDiskBytes {
            throw LocalRecorderError.insufficientDiskSpace(
                "Not enough disk space to record (\(Self.formatByteCount(freeBytes)) available). Free up space or choose another drive."
            )
        }

        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamshadows-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let videoPipeURL = sessionDir.appendingPathComponent("video.fifo")
        let audioPipeURL = sessionDir.appendingPathComponent("audio.fifo")

        guard mkfifo(videoPipeURL.path, 0o600) == 0 else {
            throw LocalRecorderError.pipeCreationFailed("video FIFO errno=\(errno)")
        }
        guard mkfifo(audioPipeURL.path, 0o600) == 0 else {
            throw LocalRecorderError.pipeCreationFailed("audio FIFO errno=\(errno)")
        }

        let args = Self.buildFFmpegArguments(
            videoPipePath: videoPipeURL.path,
            audioPipePath: audioPipeURL.path,
            preset: preset,
            encoder: encoder,
            format: format,
            outputPath: outputURL.path
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = FileHandle.nullDevice

        lock.withLock {
            self.process = proc
            self.tempDirURL = sessionDir
            self.currentOutputURL = outputURL
            self.isStopping = false
            self.isPaused = false
            self.lastErrorLine = nil
            self.pendingVideoFrames = 0
            self.pendingAudioFrames = 0
            self.droppedVideoFrames = 0
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let lines = chunk
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: true)
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    if RTMPStreamer.isMeaningfulErrorLine(line) {
                        self?.lock.withLock { self?.lastErrorLine = line }
                    }
                    self?.onLogLine?("[REC] \(line)")
                }
            }
        }

        proc.terminationHandler = { [weak self] terminatedProc in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let code = terminatedProc.terminationStatus
            let (wasStopping, savedURL, detail): (Bool, URL?, String?) = self.lock.withLock {
                let stopping = self.isStopping
                self.isStopping = true
                return (stopping, self.currentOutputURL, self.lastErrorLine)
            }
            self.cleanupPipesAndTempDir()

            // Verify non-empty file; remove 0-byte stub if recording was stopped before frames were written
            var finalURL = savedURL
            var fileSize: Int64 = 0
            if let url = savedURL,
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                fileSize = size.int64Value
            }

            var errorMessage: String?
            if fileSize == 0 {
                if let url = savedURL {
                    try? FileManager.default.removeItem(at: url)
                }
                finalURL = nil
                if let detail, !detail.isEmpty {
                    errorMessage = "Recording failed: \(detail)"
                } else if !wasStopping && code != 0 {
                    errorMessage = "Recorder exited unexpectedly (code \(code))."
                } else {
                    errorMessage = "Recording stopped before any video frames were written."
                }
            } else if !wasStopping && code != 0 {
                errorMessage = detail.map { "Recording interrupted: \($0)" } ?? "Recorder exited unexpectedly (code \(code))."
            }

            self.onFinished?(finalURL, code, errorMessage)
        }

        do {
            try proc.run()
        } catch {
            cleanupPipesAndTempDir()
            throw LocalRecorderError.processFailedToStart(error.localizedDescription)
        }

        onLogLine?("Recording started → \(outputURL.path)")

        let vPath = videoPipeURL.path
        let aPath = audioPipeURL.path
        videoWriteQueue.async { [weak self] in
            self?.openFIFOWithRetry(path: vPath, process: proc, isVideo: true)
        }
        audioWriteQueue.async { [weak self] in
            self?.openFIFOWithRetry(path: aPath, process: proc, isVideo: false)
        }

        return outputURL
    }

    private func openFIFOWithRetry(path: String, process: Process, isVideo: Bool) {
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let stopping = lock.withLock { isStopping }
            if stopping || !process.isRunning { return }

            let fd = Darwin.open(path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                if flags >= 0 {
                    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                }
                let shouldClose: Bool = lock.withLock {
                    if isStopping { return true }
                    if isVideo {
                        self.videoFD = fd
                    } else {
                        self.audioFD = fd
                    }
                    return false
                }
                if shouldClose { Darwin.close(fd) }
                return
            }

            if errno == ENXIO || errno == EINTR {
                usleep(10_000)
                continue
            } else {
                return
            }
        }
    }

    public func writeVideoFrame(_ buffer: PooledFrameBuffer) {
        let shouldWrite: Bool = lock.withLock {
            let bothPipesReady = (videoFD >= 0 && audioFD >= 0)
            if isStopping || isPaused || !bothPipesReady || pendingVideoFrames >= Self.maxPendingVideoFrames {
                if !isStopping && !isPaused && bothPipesReady {
                    droppedVideoFrames += 1
                }
                return false
            }
            pendingVideoFrames += 1
            return true
        }

        guard shouldWrite else {
            buffer.recycle()
            return
        }

        videoWriteQueue.async { [weak self] in
            defer {
                self?.lock.withLock {
                    self?.pendingVideoFrames = max(0, (self?.pendingVideoFrames ?? 1) - 1)
                }
                buffer.recycle()
            }
            guard let self else { return }
            let (fd, ready, stopping) = self.lock.withLock {
                (self.videoFD, self.videoFD >= 0 && self.audioFD >= 0, self.isStopping)
            }
            guard ready, fd >= 0, !stopping else { return }
            Self.writeAll(fd: fd, base: buffer.pointer, count: buffer.byteCount)
        }
    }

    public func writeAudioFrame(_ data: Data) {
        let shouldWrite: Bool = lock.withLock {
            let bothPipesReady = (videoFD >= 0 && audioFD >= 0)
            if isStopping || isPaused || !bothPipesReady || pendingAudioFrames >= Self.maxPendingAudioFrames {
                return false
            }
            pendingAudioFrames += 1
            return true
        }
        guard shouldWrite else { return }

        audioWriteQueue.async { [weak self] in
            defer {
                self?.lock.withLock {
                    self?.pendingAudioFrames = max(0, (self?.pendingAudioFrames ?? 1) - 1)
                }
            }
            guard let self else { return }
            let (fd, ready, stopping) = self.lock.withLock {
                (self.audioFD, self.videoFD >= 0 && self.audioFD >= 0, self.isStopping)
            }
            guard ready, fd >= 0, !stopping else { return }
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                Self.writeAll(fd: fd, base: base, count: rawBuffer.count)
            }
        }
    }

    /// Gracefully stops recording by closing both FIFOs (sending EOF) so FFmpeg finalizes the container cleanly.
    public func stop() {
        let (proc, vfd, afd): (Process?, Int32, Int32) = lock.withLock {
            isStopping = true
            isPaused = false
            let p = process
            let v = videoFD
            let a = audioFD
            videoFD = -1
            audioFD = -1
            return (p, v, a)
        }

        if vfd >= 0 { Darwin.close(vfd) }
        if afd >= 0 { Darwin.close(afd) }

        if let proc, proc.isRunning {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.0) {
                if proc.isRunning {
                    proc.terminate()
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6.0) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        } else {
            cleanupPipesAndTempDir()
        }
    }

    /// Synchronously stops and waits up to `timeout` seconds for FFmpeg to flush and finalize the file (used on app quit).
    public func stopAndWait(timeout: TimeInterval = 3.0) {
        let proc = lock.withLock { process }
        stop()
        guard let proc else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            usleep(25_000)
        }
        if proc.isRunning {
            proc.terminate()
        }
    }

    private func cleanupPipesAndTempDir() {
        let (vfd, afd, dir): (Int32, Int32, URL?) = lock.withLock {
            let v = videoFD
            let a = audioFD
            videoFD = -1
            audioFD = -1
            let d = tempDirURL
            tempDirURL = nil
            process = nil
            return (v, a, d)
        }
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
}
