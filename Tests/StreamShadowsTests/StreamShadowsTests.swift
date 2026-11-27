import XCTest
@testable import StreamShadows

final class StreamShadowsTests: XCTestCase {
    func testDestinationFullRTMPURLFormattingAndValidation() {
        let yt = StreamDestinationConfig(
            platform: .youtube,
            isEnabled: true,
            ingestURL: "rtmps://a.rtmps.youtube.com/live2/",
            streamKey: "abcd-1234"
        )
        XCTAssertTrue(yt.hasValidIngestURL)
        XCTAssertEqual(yt.fullRTMPURL, "rtmps://a.rtmps.youtube.com/live2/abcd-1234")
        XCTAssertTrue(yt.isReadyToStream)

        let twitchNoSlash = StreamDestinationConfig(
            platform: .twitch,
            isEnabled: true,
            ingestURL: "rtmp://live.twitch.tv/app",
            streamKey: "live_999"
        )
        XCTAssertTrue(twitchNoSlash.hasValidIngestURL)
        XCTAssertEqual(twitchNoSlash.fullRTMPURL, "rtmp://live.twitch.tv/app/live_999")

        let xEmptyKey = StreamDestinationConfig(
            platform: .x,
            isEnabled: true,
            ingestURL: "rtmps://va.pscp.tv:443/x/",
            streamKey: "   "
        )
        XCTAssertTrue(xEmptyKey.hasValidIngestURL)
        XCTAssertNil(xEmptyKey.fullRTMPURL)
        XCTAssertFalse(xEmptyKey.isReadyToStream)

        // Reject non-RTMP(S) schemes
        let badScheme = StreamDestinationConfig(
            platform: .youtube,
            isEnabled: true,
            ingestURL: "https://example.com/live/",
            streamKey: "key123"
        )
        XCTAssertFalse(badScheme.hasValidIngestURL)
        XCTAssertNil(badScheme.fullRTMPURL)
        XCTAssertFalse(badScheme.isReadyToStream)
    }

    func testFFmpegSingleAndMultiDestinationArgumentsAndTeeEscaping() {
        let singleArgs = RTMPStreamer.buildFFmpegArguments(
            videoPipePath: "/tmp/v.fifo",
            audioPipePath: "/tmp/a.fifo",
            preset: .p1080_30,
            encoder: .hardwareVideoToolbox,
            destinationURLs: ["rtmps://a.rtmps.youtube.com/live2/key1"]
        )
        XCTAssertTrue(singleArgs.contains("h264_videotoolbox"))
        XCTAssertTrue(singleArgs.contains("flv"))
        XCTAssertFalse(singleArgs.contains("tee"))

        let multiArgs = RTMPStreamer.buildFFmpegArguments(
            videoPipePath: "/tmp/v.fifo",
            audioPipePath: "/tmp/a.fifo",
            preset: .p720_60,
            encoder: .softwareX264,
            destinationURLs: [
                "rtmps://a.rtmps.youtube.com/live2/key|1",
                "rtmp://live.twitch.tv/app/key[2]"
            ]
        )
        XCTAssertTrue(multiArgs.contains("libx264"))
        XCTAssertTrue(multiArgs.contains("tee"))
        XCTAssertTrue(multiArgs.contains {
            $0.contains(#"[f=flv:onfail=ignore]rtmps://a.rtmps.youtube.com/live2/key\|1|[f=flv:onfail=ignore]rtmp://live.twitch.tv/app/key\[2\]"#)
        })
    }

    func testSecretRedactionInLogs() {
        let raw = "Opening 'rtmps://a.rtmps.youtube.com/live2/super-secret-key-123' for writing"
        let redacted = RTMPStreamer.redactSecrets(in: raw, secrets: ["super-secret-key-123"])
        XCTAssertFalse(redacted.contains("super-secret-key-123"))
        XCTAssertTrue(redacted.contains("••••••••"))
    }

    func testProgressLineParsing() {
        let line = "frame=  120 fps= 30 q=-0.0 size=    1420kB time=00:00:04.00 bitrate=2908.2kbits/s speed=1.00x"
        let parsed = RTMPStreamer.parseProgressLine(line)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.framesSent, 120)
        XCTAssertEqual(parsed?.fps, "30")
        XCTAssertEqual(parsed?.bitrate, "2908.2kbits/s")
        XCTAssertEqual(parsed?.speed, "1.00x")
    }

    func testAudioMixerMixingAndSoftClipping() {
        let sys: [Float] = [0.5, -0.5, 0.8, -0.8]
        let mic: [Float] = [0.25, -0.25, 0.8, -0.8]

        let (data, peak) = AudioMixer.mixToInt16PCM(
            systemSamples: sys,
            micSamples: mic,
            systemGain: 1.0,
            micGain: 1.0,
            masterGain: 1.0
        )

        XCTAssertEqual(data.count, 4 * MemoryLayout<Int16>.size)
        XCTAssertLessThanOrEqual(peak, 1.0)
        XCTAssertGreaterThan(peak, 0.9)

        let (silentData, silentPeak) = AudioMixer.mixToInt16PCM(
            systemSamples: sys,
            micSamples: mic,
            systemGain: 1.0,
            micGain: 1.0,
            masterGain: 0.0
        )
        XCTAssertEqual(silentPeak, 0.0)
        XCTAssertTrue(silentData.allSatisfy { $0 == 0 })
    }

    func testFloatRingBufferWraparoundOverflowAndUnderrun() {
        var ring = FloatRingBuffer(capacity: 4)
        ring.push([1, 2, 3])
        XCTAssertEqual(ring.count, 3)

        let first = ring.pop(count: 2)
        XCTAssertEqual(first, [1, 2])
        XCTAssertEqual(ring.count, 1)

        // Wrap around and overflow oldest sample (3)
        ring.push([4, 5, 6, 7])
        XCTAssertEqual(ring.count, 4)
        let second = ring.pop(count: 6) // Request more than available -> zero padded
        XCTAssertEqual(second, [4, 5, 6, 7, 0, 0])
        XCTAssertEqual(ring.count, 0)
    }

    func testAudioResampling44100To48000() {
        // 441 frames at 44.1kHz = 10ms -> should resample to 480 frames at 48kHz
        var input = [Float](repeating: 0, count: 441 * 2)
        for i in 0..<441 {
            input[i * 2] = 0.5
            input[i * 2 + 1] = -0.25
        }
        let output = AudioMixer.resampleStereo(input, fromSampleRate: 44_100, toSampleRate: 48_000)
        XCTAssertEqual(output.count, 480 * 2)
        XCTAssertEqual(output[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(output[1], -0.25, accuracy: 0.001)
        XCTAssertEqual(output[output.count - 2], 0.5, accuracy: 0.001)
        XCTAssertEqual(output[output.count - 1], -0.25, accuracy: 0.001)
    }

    func testDecode24BitSignedInterleavedPCM() {
        // 2 frames of mono 24-bit signed LE:
        // Frame 0: +0x400000 (+0.5 full scale) -> bytes [0x00, 0x00, 0x40]
        // Frame 1: -0x400000 (-0.5 full scale, 0xC00000) -> bytes [0x00, 0x00, 0xC0]
        let rawBytes: [UInt8] = [0x00, 0x00, 0x40, 0x00, 0x00, 0xC0]
        let decoded = rawBytes.withUnsafeBufferPointer { ptr in
            AudioMixer.decode24BitSignedInterleaved(ptr.baseAddress!, numFrames: 2, channels: 1)
        }
        XCTAssertEqual(decoded.count, 4)
        XCTAssertEqual(decoded[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(decoded[1], 0.5, accuracy: 0.001) // mono upmixed to stereo
        XCTAssertEqual(decoded[2], -0.5, accuracy: 0.001)
        XCTAssertEqual(decoded[3], -0.5, accuracy: 0.001)
    }

    func testFrameBufferPoolReuseAndResize() {
        let pool = FrameBufferPool(maxPoolSize: 2)
        let buf1 = pool.acquire(byteCount: 1024)
        let ptr1 = buf1.pointer
        buf1.recycle()

        let buf2 = pool.acquire(byteCount: 1024)
        XCTAssertEqual(buf2.pointer, ptr1, "Expected pool to reuse recycled buffer of matching size")
        buf2.recycle()

        let buf3 = pool.acquire(byteCount: 2048)
        XCTAssertEqual(buf3.byteCount, 2048)
        buf3.recycle()
    }
}
