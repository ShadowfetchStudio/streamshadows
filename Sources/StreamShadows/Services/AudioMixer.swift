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

    public init() {}
}

/// Thread-safe real-time 48kHz stereo PCM audio mixer with independent system, mic, and master controls.
public final class AudioMixer: @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    public static let channels: Int = 2
    public static let chunkFrames: Int = 960 // 20ms at 48kHz

    private let lock = NSLock()
    private var settings = AudioMixerSettings()

    // Interleaved stereo Float32 ring buffers (max ~0.5s = 48000 floats)
    private var systemBuffer: [Float] = []
    private var micBuffer: [Float] = []
    private let maxBufferedSamples = 48_000

    private var currentSystemPeak: Float = 0
    private var currentMicPeak: Float = 0
    private var currentMasterPeak: Float = 0

    private var timer: DispatchSourceTimer?
    private let mixQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.audiomixer", qos: .userInteractive)

    public var onMixedPCMFrame: (@Sendable (Data) -> Void)?
    public var onLevelsUpdated: (@Sendable (AudioLevels) -> Void)?

    public init() {}

    public func updateSettings(_ newSettings: AudioMixerSettings) {
        lock.lock()
        settings = newSettings
        lock.unlock()
    }

    public func start() {
        mixQueue.async { [weak self] in
            guard let self else { return }
            self.stopTimerLocked()

            let timer = DispatchSource.makeTimerSource(queue: self.mixQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
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
        systemBuffer.removeAll(keepingCapacity: true)
        micBuffer.removeAll(keepingCapacity: true)
        currentSystemPeak = 0
        currentMicPeak = 0
        currentMasterPeak = 0
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
            systemBuffer.append(contentsOf: stereo)
            if systemBuffer.count > maxBufferedSamples {
                systemBuffer.removeFirst(systemBuffer.count - maxBufferedSamples)
            }
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
            micBuffer.append(contentsOf: stereo)
            if micBuffer.count > maxBufferedSamples {
                micBuffer.removeFirst(micBuffer.count - maxBufferedSamples)
            }
        }
        lock.unlock()
    }

    private func mixTick() {
        let sampleCount = Self.chunkFrames * Self.channels

        lock.lock()
        let cfg = settings
        let sysChunk = Self.popSamples(from: &systemBuffer, count: sampleCount)
        let micChunk = Self.popSamples(from: &micBuffer, count: sampleCount)
        // Smooth decay for UI meters
        currentSystemPeak *= 0.85
        currentMicPeak *= 0.85
        let sysPeakSnapshot = min(currentSystemPeak, 1.0)
        let micPeakSnapshot = min(currentMicPeak, 1.0)
        lock.unlock()

        let sysGain: Float = (cfg.systemAudioEnabled && !cfg.systemAudioMuted) ? cfg.systemAudioVolume : 0
        let micGain: Float = (cfg.micAudioEnabled && !cfg.micAudioMuted) ? cfg.micAudioVolume : 0
        let masterGain: Float = cfg.masterMuted ? 0 : cfg.masterVolume

        let (pcmData, masterPeak) = Self.mixToInt16PCM(
            systemSamples: sysChunk,
            micSamples: micChunk,
            systemGain: sysGain,
            micGain: micGain,
            masterGain: masterGain
        )

        lock.lock()
        currentMasterPeak = max(masterPeak, currentMasterPeak * 0.8)
        let masterPeakSnapshot = min(currentMasterPeak, 1.0)
        lock.unlock()

        onMixedPCMFrame?(pcmData)
        onLevelsUpdated?(AudioLevels(
            systemPeak: sysPeakSnapshot,
            micPeak: micPeakSnapshot,
            masterPeak: masterPeakSnapshot
        ))
    }

    private static func popSamples(from buffer: inout [Float], count: Int) -> [Float] {
        if buffer.count >= count {
            let slice = Array(buffer.prefix(count))
            buffer.removeFirst(count)
            return slice
        } else if !buffer.isEmpty {
            var result = buffer
            buffer.removeAll(keepingCapacity: true)
            result.append(contentsOf: repeatElement(Float(0), count: count - result.count))
            return result
        } else {
            return [Float](repeating: 0, count: count)
        }
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

    /// Extracts audio from a CMSampleBuffer into interleaved 48kHz stereo Float32 samples.
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
            let scale: Float = 1.0 / 32768.0
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
        } else {
            return nil
        }

        // Linear resample if source sample rate differs from 48kHz (e.g., 44.1kHz mic)
        if abs(asbd.mSampleRate - sampleRate) > 10 && asbd.mSampleRate > 0 {
            let ratio = sampleRate / asbd.mSampleRate
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

        return stereo
    }
}
