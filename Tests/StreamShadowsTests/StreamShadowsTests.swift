import XCTest
@testable import StreamShadows

final class StreamShadowsTests: XCTestCase {
    func testDestinationFullRTMPURLFormatting() {
        let yt = StreamDestinationConfig(
            platform: .youtube,
            isEnabled: true,
            ingestURL: "rtmps://a.rtmps.youtube.com/live2/",
            streamKey: "abcd-1234"
        )
        XCTAssertEqual(yt.fullRTMPURL, "rtmps://a.rtmps.youtube.com/live2/abcd-1234")
        XCTAssertTrue(yt.isReadyToStream)

        let twitchNoSlash = StreamDestinationConfig(
            platform: .twitch,
            isEnabled: true,
            ingestURL: "rtmp://live.twitch.tv/app",
            streamKey: "live_999"
        )
        XCTAssertEqual(twitchNoSlash.fullRTMPURL, "rtmp://live.twitch.tv/app/live_999")

        let xEmptyKey = StreamDestinationConfig(
            platform: .x,
            isEnabled: true,
            ingestURL: "rtmps://va.pscp.tv:443/x/",
            streamKey: "   "
        )
        XCTAssertNil(xEmptyKey.fullRTMPURL)
        XCTAssertFalse(xEmptyKey.isReadyToStream)
    }

    func testFFmpegSingleAndMultiDestinationArguments() {
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
                "rtmps://a.rtmps.youtube.com/live2/key1",
                "rtmp://live.twitch.tv/app/key2"
            ]
        )
        XCTAssertTrue(multiArgs.contains("libx264"))
        XCTAssertTrue(multiArgs.contains("tee"))
        XCTAssertTrue(multiArgs.contains { $0.contains("[f=flv:onfail=ignore]rtmps://a.rtmps.youtube.com/live2/key1|[f=flv:onfail=ignore]rtmp://live.twitch.tv/app/key2") })
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

        // Muted master should produce silence
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
}
