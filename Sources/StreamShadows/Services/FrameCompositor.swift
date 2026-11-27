import Foundation
import CoreImage
import CoreVideo
import CoreGraphics

public struct CompositorConfig: Sendable {
    public var mode: StreamSourceMode = .screenOnly
    public var pipPosition: PiPPosition = .bottomRight
    public var pipSize: PiPSize = .medium
    public var mirrorCamera: Bool = true
    public var width: Int = 1920
    public var height: Int = 1080
    public var fps: Int = 30
    public var isStreaming: Bool = false

    public init() {}
}

/// Real-time Metal-backed CoreImage compositor for screen, camera, and Picture-in-Picture layouts.
public final class FrameCompositor: @unchecked Sendable {
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()

    private var config = CompositorConfig()
    private var latestScreenBuffer: CVPixelBuffer?
    private var latestCameraBuffer: CVPixelBuffer?

    private var timer: DispatchSourceTimer?
    private let renderQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.compositor", qos: .userInteractive)
    private var frameCounter: Int = 0

    public var onPreviewFrame: (@Sendable (CGImage) -> Void)?
    public var onEncodedVideoFrame: (@Sendable (Data) -> Void)?

    public init() {
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }

    public func updateConfig(_ newConfig: CompositorConfig) {
        let fpsChanged: Bool
        lock.lock()
        fpsChanged = config.fps != newConfig.fps || config.isStreaming != newConfig.isStreaming
        config = newConfig
        lock.unlock()

        if fpsChanged && timer != nil {
            start()
        }
    }

    public func updateScreenFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestScreenBuffer = pixelBuffer
        lock.unlock()
    }

    public func updateCameraFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestCameraBuffer = pixelBuffer
        lock.unlock()
    }

    public func clearFrames() {
        lock.lock()
        latestScreenBuffer = nil
        latestCameraBuffer = nil
        lock.unlock()
    }

    public func start() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()

            self.lock.lock()
            let targetFPS = self.config.isStreaming ? self.config.fps : 24
            self.lock.unlock()

            let intervalNs = UInt64(1_000_000_000 / max(1, targetFPS))
            let timer = DispatchSource.makeTimerSource(queue: self.renderQueue)
            timer.schedule(
                deadline: .now(),
                repeating: .nanoseconds(Int(intervalNs)),
                leeway: .milliseconds(2)
            )
            timer.setEventHandler { [weak self] in
                self?.renderTick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        renderQueue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func renderTick() {
        lock.lock()
        let cfg = config
        let screenBuf = latestScreenBuffer
        let cameraBuf = latestCameraBuffer
        lock.unlock()

        let canvasWidth = cfg.width
        let canvasHeight = cfg.height
        let canvasRect = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        var composite = CIImage(color: CIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0))
            .cropped(to: canvasRect)

        switch cfg.mode {
        case .screenOnly:
            if let screenBuf {
                let screenImg = Self.aspectFitImage(CIImage(cvPixelBuffer: screenBuf), into: canvasRect)
                composite = screenImg.composited(over: composite)
            }

        case .cameraOnly:
            if let cameraBuf {
                var camImg = CIImage(cvPixelBuffer: cameraBuf)
                if cfg.mirrorCamera {
                    camImg = Self.mirrorHorizontally(camImg)
                }
                let fitted = Self.aspectFillImage(camImg, into: canvasRect)
                composite = fitted.composited(over: composite)
            }

        case .screenWithCameraPiP:
            if let screenBuf {
                let screenImg = Self.aspectFitImage(CIImage(cvPixelBuffer: screenBuf), into: canvasRect)
                composite = screenImg.composited(over: composite)
            }
            if let cameraBuf {
                var camImg = CIImage(cvPixelBuffer: cameraBuf)
                if cfg.mirrorCamera {
                    camImg = Self.mirrorHorizontally(camImg)
                }
                let pipRect = Self.pipFrame(
                    canvasWidth: CGFloat(canvasWidth),
                    canvasHeight: CGFloat(canvasHeight),
                    position: cfg.pipPosition,
                    size: cfg.pipSize
                )
                let pipImg = Self.aspectFillImage(camImg, into: pipRect)
                // Subtle dark border behind PiP
                let borderRect = pipRect.insetBy(dx: -3, dy: -3)
                let borderImg = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.25))
                    .cropped(to: borderRect)
                composite = borderImg.composited(over: composite)
                composite = pipImg.composited(over: composite)
            }
        }

        let finalImage = composite.cropped(to: canvasRect)
        frameCounter += 1

        // Emit BGRA bytes to FFmpeg when streaming
        if cfg.isStreaming, let onEncodedVideoFrame {
            let bytesPerRow = canvasWidth * 4
            var data = Data(count: bytesPerRow * canvasHeight)
            data.withUnsafeMutableBytes { rawBuf in
                if let baseAddr = rawBuf.baseAddress {
                    ciContext.render(
                        finalImage,
                        toBitmap: baseAddr,
                        rowBytes: bytesPerRow,
                        bounds: canvasRect,
                        format: .BGRA8,
                        colorSpace: colorSpace
                    )
                }
            }
            onEncodedVideoFrame(data)
        }

        // Throttle preview CGImage updates when streaming at 60fps to keep SwiftUI smooth
        let previewStride = (cfg.isStreaming && cfg.fps >= 60) ? 2 : 1
        if frameCounter % previewStride == 0, let onPreviewFrame {
            // Downscale preview slightly for snappy UI rendering
            let previewScale = min(1.0, 960.0 / CGFloat(canvasWidth))
            let previewImage = previewScale < 1.0
                ? finalImage.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
                : finalImage
            if let cgImage = ciContext.createCGImage(previewImage, from: previewImage.extent) {
                onPreviewFrame(cgImage)
            }
        }
    }

    private static func mirrorHorizontally(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let transform = CGAffineTransform(scaleX: -1, y: 1)
            .translatedBy(x: -extent.width - 2 * extent.origin.x, y: 0)
        return image.transformed(by: transform)
    }

    private static func aspectFitImage(_ image: CIImage, into target: CGRect) -> CIImage {
        let src = image.extent
        guard src.width > 0, src.height > 0 else { return image }
        let scale = min(target.width / src.width, target.height / src.height)
        let scaledWidth = src.width * scale
        let scaledHeight = src.height * scale
        let tx = target.origin.x + (target.width - scaledWidth) / 2.0 - src.origin.x * scale
        let ty = target.origin.y + (target.height - scaledHeight) / 2.0 - src.origin.y * scale
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .cropped(to: target)
    }

    private static func aspectFillImage(_ image: CIImage, into target: CGRect) -> CIImage {
        let src = image.extent
        guard src.width > 0, src.height > 0 else { return image }
        let scale = max(target.width / src.width, target.height / src.height)
        let scaledWidth = src.width * scale
        let scaledHeight = src.height * scale
        let tx = target.origin.x + (target.width - scaledWidth) / 2.0 - src.origin.x * scale
        let ty = target.origin.y + (target.height - scaledHeight) / 2.0 - src.origin.y * scale
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .cropped(to: target)
    }

    private static func pipFrame(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        position: PiPPosition,
        size: PiPSize
    ) -> CGRect {
        let width = (canvasWidth * size.widthFraction).rounded()
        let height = (width * 9.0 / 16.0).rounded()
        let margin = (canvasWidth * 0.025).rounded()

        // CoreImage origin is bottom-left
        let x: CGFloat
        let y: CGFloat
        switch position {
        case .bottomLeft:
            x = margin
            y = margin
        case .bottomRight:
            x = canvasWidth - width - margin
            y = margin
        case .topLeft:
            x = margin
            y = canvasHeight - height - margin
        case .topRight:
            x = canvasWidth - width - margin
            y = canvasHeight - height - margin
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
