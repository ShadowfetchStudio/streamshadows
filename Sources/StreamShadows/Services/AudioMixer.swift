import Foundation
import CoreMedia
import AVFoundation

public struct AudioMixerSettings: Sendable {
    public var systemAudioEnabled: Bool = true
    public var systemAudioMuted: Bool = false
    public var systemAudioVolume: Float = 1.0

    public var micAudioEnabled: Bool = true
    public var micAudioMuted: Bool = false
    public var micAudioVolume: Float = 1.0

    public var masterMuted: Bool = false
    public var masterVolume: Float = 1.0

    public var isStreaming: Bool = false

    public init() {}
}

/// Fixed-capacity O(1) circular ring buffer for interleaved Float32 audio samples.
public struct FloatRingBuffer: Sendable {
    private var storage: [Float]
    private let capacity: Int
    private var head: Int = 0
    private var tail: Int = 0
    public private(set) var count: Int = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    public mutating func push(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        // If incoming chunk exceeds total capacity, keep only the newest `capacity` samples
        let sliceStart = max(0, samples.count - capacity)
        let incomingCount = samples.count - sliceStart

        // Drop oldest samples if buffer would overflow
        let overflow = (count + incomingCount) - capacity
        if overflow > 0 {
            head = (head + overflow) % capacity
            count -= overflow
        }

        for i in sliceStart..<samples.count {
            storage[tail] = samples[i]
            tail = (tail + 1) % capacity
        }
        count += incomingCount
    }

    public mutating func pop(count requested: Int) -> [Float] {
        var result = [Float](repeating: 0, count: requested)
        let available = min(requested, count)
        for i in 0..<available {
            result[i] = storage[head]
            head = (head + 1) % capacity
        }
        count -= available
        return result
    }

    public mutating func clear() {
        head = 0
        tail = 0
        count = 0
    }
}

/// Thread-safe real-time 48kHz stereo PCM audio mixer with O(1) ring buffers, drift protection, and 16/24/32-bit PCM support.
public final class AudioMixer: @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    public static let channels: Int = 2
    public static let chunkFrames: Int = 960 // 20ms at 48kHz

    private let lock = NSLock()
    private var settings = AudioMixerSettings()

    // Interleaved stereo Float32 ring buffers (max ~0.5s = 48000 floats)
    private var systemBuffer = FloatRingBuffer(capacity: 48_000)
    private var micBuffer = FloatRingBuffer(capacity: 48_000)

    private var currentSystemPeak: Float = 0
    private var currentMicPeak: Float = 0
    private var currentMasterPeak: Float = 0

    // Wall-clock drift tracking while streaming
    private var streamStartUptimeNs: UInt64 = 0
    private var emittedStreamChunks: UInt64 = 0

    private var timer: DispatchSourceTimer?
    private let mixQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.audiomixer", qos: .userInteractive)

    public var onMixedPCMFrame: (@Sendable (Data) -> Void)?
    public var onLevelsUpdated: (@Sendable (AudioLevels) -> Void)?

    public init() {}

    public func updateSettings(_ newSettings: AudioMixerSettings) {
        lock.lock()
        let wasStreaming = settings.isStreaming
        settings = newSettings
        if !wasStreaming && newSettings.isStreaming {
            streamStartUptimeNs = DispatchTime.now().uptimeNanoseconds
            emittedStreamChunks = 0
            systemBuffer.clear()
            micBuffer.clear()
        } else if wasStreaming && !newSettings.isStreaming {
            streamStartUptimeNs = 0
            emittedStreamChunks = 0
        }
        lock.unlock()
    }

    public func start() {
        mixQueue.async { [weak self] in
            guard let self else { return }
            self.stopTimerLocked()

            let timer = DispatchSource.makeTimerSource(queue: self.mixQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                self?.mixTick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        mixQueue.async { [weak self] in
            self?.stopTimerLocked()
            self?.clearBuffers()
        }
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func clearBuffers() {
        lock.lock()
        systemBuffer.clear()
        micBuffer.clear()
        currentSystemPeak = 0
        currentMicPeak = 0
        currentMasterPeak = 0
        streamStartUptimeNs = 0
        emittedStreamChunks = 0
        lock.unlock()
    }

    public func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let stereo = Self.extractStereoFloat32(from: sampleBuffer) else { return }
        lock.lock()
        let effectiveGain = (settings.systemAudioEnabled && !settings.systemAudioMuted) ? settings.systemAudioVolume : 0
        var peak: Float = 0
        for sample in stereo {
            let v = abs(sample * effectiveGain)
            if v > peak { peak = v }
        }
        currentSystemPeak = max(peak, currentSystemPeak * 0.7)

        if settings.systemAudioEnabled {
            systemBuffer.push(stereo)
        }
        lock.unlock()
    }

    public func appendMicAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let stereo = Self.extractStereoFloat32(from: sampleBuffer) else { return }
        lock.lock()
        let effectiveGain = (settings.micAudioEnabled && !settings.micAudioMuted) ? settings.micAudioVolume : 0
        var peak: Float = 0
        for sample in stereo {
            let v = abs(sample * effectiveGain)
            if v > peak { peak = v }
        }
        currentMicPeak = max(peak, currentMicPeak * 0.7)

        if settings.micAudioEnabled {
            micBuffer.push(stereo)
        }
        lock.unlock()
    }

    private func mixTick() {
        let sampleCount = Self.chunkFrames * Self.channels
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let cfg = settings
        let chunksToEmit: Int
        if cfg.isStreaming {
            if streamStartUptimeNs == 0 {
                streamStartUptimeNs = nowNs
                emittedStreamChunks = 0
            }
            let elapsedNs = nowNs >= streamStartUptimeNs ? (nowNs - streamStartUptimeNs) : 0
            let expectedChunks = (elapsedNs / 20_000_000) + 1
            if expectedChunks > emittedStreamChunks {
                // Cap catch-up to at most 3 chunks per tick to avoid bursts
                chunksToEmit = Int(min(3, expectedChunks - emittedStreamChunks))
                emittedStreamChunks += UInt64(chunksToEmit)
            } else {
                chunksToEmit = 0
            }
        } else {
            chunksToEmit = 1
        }
        lock.unlock()

        guard chunksToEmit > 0 else { return }

        let sysGain: Float = (cfg.systemAudioEnabled && !cfg.systemAudioMuted) ? cfg.systemAudioVolume : 0
        let micGain: Float = (cfg.micAudioEnabled && !cfg.micAudioMuted) ? cfg.micAudioVolume : 0
        let masterGain: Float = cfg.masterMuted ? 0 : cfg.masterVolume

        var latestSysPeak: Float = 0
        var latestMicPeak: Float = 0
        var latestMasterPeak: Float = 0

        for _ in 0..<chunksToEmit {
            lock.lock()
            let sysChunk = systemBuffer.pop(count: sampleCount)
            let micChunk = micBuffer.pop(count: sampleCount)
            currentSystemPeak *= 0.85
            currentMicPeak *= 0.85
            latestSysPeak = min(currentSystemPeak, 1.0)
            latestMicPeak = min(currentMicPeak, 1.0)
            lock.unlock()

            let (pcmData, masterPeak) = Self.mixToInt16PCM(
                systemSamples: sysChunk,
                micSamples: micChunk,
                systemGain: sysGain,
                micGain: micGain,
                masterGain: masterGain
            )

            lock.lock()
            currentMasterPeak = max(masterPeak, currentMasterPeak * 0.8)
            latestMasterPeak = min(currentMasterPeak, 1.0)
            lock.unlock()

            // Only emit PCM to FFmpeg when actively streaming
            if cfg.isStreaming {
                onMixedPCMFrame?(pcmData)
            }
        }

        onLevelsUpdated?(AudioLevels(
            systemPeak: latestSysPeak,
            micPeak: latestMicPeak,
            masterPeak: latestMasterPeak
        ))
    }

    /// Mixes two equal-length stereo Float32 buffers with soft-clipping and converts to interleaved s16le PCM.
    public static func mixToInt16PCM(
        systemSamples: [Float],
        micSamples: [Float],
        systemGain: Float,
        micGain: Float,
        masterGain: Float
    ) -> (Data, Float) {
        let count = min(systemSamples.count, micSamples.count)
        var int16Samples = [Int16](repeating: 0, count: count)
        var peak: Float = 0

        for i in 0..<count {
            let mixed = (systemSamples[i] * systemGain + micSamples[i] * micGain) * masterGain
            let limited = softClip(mixed)
            let absVal = abs(limited)
            if absVal > peak { peak = absVal }
            int16Samples[i] = Int16(max(-32768, min(32767, Int32(limited * 32767.0))))
        }

        let data = int16Samples.withUnsafeBytes { Data($0) }
        return (data, min(peak, 1.0))
    }

    public static func softClip(_ sample: Float) -> Float {
        if abs(sample) <= 0.92 {
            return sample
        }
        return tanh(sample)
    }

    /// Linearly resamples interleaved stereo Float32 samples between sample rates.
    public static func resampleStereo(_ stereo: [Float], fromSampleRate: Double, toSampleRate: Double = sampleRate) -> [Float] {
        let numFrames = stereo.count / 2
        guard numFrames > 0, fromSampleRate > 0, abs(fromSampleRate - toSampleRate) > 10 else {
            return stereo
        }
        let ratio = toSampleRate / fromSampleRate
        let outFrames = max(1, Int((Double(numFrames) * ratio).rounded()))
        var resampled = [Float](repeating: 0, count: outFrames * 2)
        for outF in 0..<outFrames {
            let srcPos = Double(outF) / ratio
            let idx0 = min(numFrames - 1, Int(srcPos))
            let idx1 = min(numFrames - 1, idx0 + 1)
            let frac = Float(srcPos - Double(idx0))
            resampled[outF * 2] = stereo[idx0 * 2] * (1 - frac) + stereo[idx1 * 2] * frac
            resampled[outF * 2 + 1] = stereo[idx0 * 2 + 1] * (1 - frac) + stereo[idx1 * 2 + 1] * frac
        }
        return resampled
    }

    /// Decodes packed 24-bit signed little-endian PCM bytes into interleaved stereo Float32.
    public static func decode24BitSignedInterleaved(_ bytes: UnsafePointer<UInt8>, numFrames: Int, channels: Int) -> [Float] {
        let ch = max(1, channels)
        var stereo = [Float](repeating: 0, count: numFrames * 2)
        let scale: Float = 1.0 / 8_388_608.0 // 2^23

        func readSample(at byteOffset: Int) -> Float {
            let b0 = Int32(bytes[byteOffset])
            let b1 = Int32(bytes[byteOffset + 1]) << 8
            let b2 = Int32(Int8(bitPattern: bytes[byteOffset + 2])) << 16
            let value = b0 | b1 | b2
            return Float(value) * scale
        }

        for f in 0..<numFrames {
            let frameBase = f * ch * 3
            let left = readSample(at: frameBase)
            let right = ch > 1 ? readSample(at: frameBase + 3) : left
            stereo[f * 2] = left
            stereo[f * 2 + 1] = right
        }
        return stereo
    }

    /// Extracts audio from a CMSampleBuffer into interleaved 48kHz stereo Float32 samples (supports 32f, 16i, 24i, 32i).
    public static func extractStereoFloat32(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        let asbd = asbdPtr.pointee
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return nil }

        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0

        var bufferListSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard bufferListSizeNeeded > 0 else { return nil }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        let ablPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard !audioBuffers.isEmpty else { return nil }

        var stereo = [Float](repeating: 0, count: numFrames * 2)

        if isFloat && asbd.mBitsPerChannel == 32 {
            if isNonInterleaved {
                guard let leftData = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let rightData = audioBuffers.count > 1
                    ? audioBuffers[1].mData?.assumingMemoryBound(to: Float.self)
                    : leftData
                guard let rData = rightData else { return nil }
                for f in 0..<numFrames {
                    stereo[f * 2] = leftData[f]
                    stereo[f * 2 + 1] = rData[f]
                }
            } else {
                guard let data = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
                for f in 0..<numFrames {
                    let base = f * channelCount
                    stereo[f * 2] = data[base]
                    stereo[f * 2 + 1] = channelCount > 1 ? data[base + 1] : data[base]
                }
            }
        } else if isSignedInt && asbd.mBitsPerChannel == 16 {
            let scale: Float = 1.0 / 32_768.0
            if isNonInterleaved {
                guard let leftData = audioBuffers[0].mData?.assumingMemoryBound(to: Int16.self) else { return nil }
                let rightData = audioBuffers.count > 1
                    ? audioBuffers[1].mData?.assumingMemoryBound(to: Int16.self)
                    : leftData
                guard let rData = rightData else { return nil }
                for f in 0..<numFrames {
                    stereo[f * 2] = Float(leftData[f]) * scale
                    stereo[f * 2 + 1] = Float(rData[f]) * scale
                }
            } else {
                guard let data = audioBuffers[0].mData?.assumingMemoryBound(to: Int16.self) else { return nil }
                for f in 0..<numFrames {
                    let base = f * channelCount
                    stereo[f * 2] = Float(data[base]) * scale
                    stereo[f * 2 + 1] = Float(channelCount > 1 ? data[base + 1] : data[base]) * scale
                }
            }
        } else if isSignedInt && asbd.mBitsPerChannel == 24 && !isNonInterleaved {
            guard let bytes = audioBuffers[0].mData?.assumingMemoryBound(to: UInt8.self) else { return nil }
            stereo = decode24BitSignedInterleaved(bytes, numFrames: numFrames, channels: channelCount)
        } else if isSignedInt && asbd.mBitsPerChannel == 32 {
            let scale: Float = 1.0 / 2_147_483_648.0 // 2^31
            if isNonInterleaved {
                guard let leftData = audioBuffers[0].mData?.assumingMemoryBound(to: Int32.self) else { return nil }
                let rightData = audioBuffers.count > 1
                    ? audioBuffers[1].mData?.assumingMemoryBound(to: Int32.self)
                    : leftData
                guard let rData = rightData else { return nil }
                for f in 0..<numFrames {
                    stereo[f * 2] = Float(leftData[f]) * scale
                    stereo[f * 2 + 1] = Float(rData[f]) * scale
                }
            } else {
                guard let data = audioBuffers[0].mData?.assumingMemoryBound(to: Int32.self) else { return nil }
                for f in 0..<numFrames {
                    let base = f * channelCount
                    stereo[f * 2] = Float(data[base]) * scale
                    stereo[f * 2 + 1] = Float(channelCount > 1 ? data[base + 1] : data[base]) * scale
                }
            }
        } else {
            return nil
        }

        return resampleStereo(stereo, fromSampleRate: asbd.mSampleRate, toSampleRate: sampleRate)
    }
}
