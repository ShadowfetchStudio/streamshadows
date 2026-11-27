import Foundation
import CoreImage
import CoreVideo
import CoreGraphics

public struct CompositorConfig: Sendable {
    public var mode: StreamSourceMode = .screenOnly
    public var pipPosition: PiPPosition = .bottomRight
    public var pipSize: PiPSize = .medium
    public var pipShape: PiPShape = .rounded
    public var mirrorCamera: Bool = true
    public var width: Int = 1920
    public var height: Int = 1080
    public var fps: Int = 30
    public var isStreaming: Bool = false
    public var isPreviewPaused: Bool = false

    public init() {}
}

/// Reusable raw byte buffer with thread-safe retain/release so streaming and local recording can share frames zero-copy.
public final class PooledFrameBuffer: @unchecked Sendable {
    public let pointer: UnsafeMutableRawPointer
    public let byteCount: Int
    private weak var pool: FrameBufferPool?
    private let refLock = NSLock()
    private var refCount: Int = 1

    init(byteCount: Int, pool: FrameBufferPool) {
        self.byteCount = byteCount
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        self.pool = pool
    }

    func resetRefCount() {
        refLock.lock()
        refCount = 1
        refLock.unlock()
    }

    /// Retains an additional consumer reference (e.g. simultaneous streaming + recording).
    public func retain() {
        refLock.lock()
        refCount += 1
        refLock.unlock()
    }

    /// Releases a consumer reference; recycles back to the pool once all consumers are done.
    public func recycle() {
        refLock.lock()
        refCount -= 1
        let shouldRecycle = refCount <= 0
        refLock.unlock()

        if shouldRecycle {
            pool?.release(self)
        }
    }

    deinit {
        pointer.deallocate()
    }
}

/// Thread-safe pool of reusable raw frame buffers.
public final class FrameBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [PooledFrameBuffer] = []
    private var currentByteCount: Int = 0
    private let maxPoolSize: Int

    public init(maxPoolSize: Int = 6) {
        self.maxPoolSize = max(2, maxPoolSize)
    }

    public func acquire(byteCount: Int) -> PooledFrameBuffer {
        lock.lock()
        if currentByteCount != byteCount {
            available.removeAll()
            currentByteCount = byteCount
        }
        if let reused = available.popLast() {
            lock.unlock()
            reused.resetRefCount()
            return reused
        }
        lock.unlock()
        return PooledFrameBuffer(byteCount: byteCount, pool: self)
    }

    func release(_ buffer: PooledFrameBuffer) {
        lock.lock()
        if buffer.byteCount == currentByteCount && available.count < maxPoolSize {
            available.append(buffer)
        }
        lock.unlock()
    }
}

/// Real-time Metal-backed CoreImage compositor for screen, camera, and Picture-in-Picture layouts.
public final class FrameCompositor: @unchecked Sendable {
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private let bufferPool = FrameBufferPool(maxPoolSize: 4)

    private var config = CompositorConfig()
    private var latestScreenBuffer: CVPixelBuffer?
    private var latestCameraBuffer: CVPixelBuffer?

    private var timer: DispatchSourceTimer?
    private let renderQueue = DispatchQueue(label: "com.shadowfetch.streamshadows.compositor", qos: .userInteractive)
    private var frameCounter: Int = 0

    // Wall-clock drift tracking for steady FPS over long streams
    private var streamStartUptimeNs: UInt64 = 0
    private var emittedVideoFrames: UInt64 = 0

    public var onPreviewFrame: (@Sendable (CGImage) -> Void)?
    public var onEncodedVideoFrame: (@Sendable (PooledFrameBuffer) -> Void)?

    public init() {
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }

    public func updateConfig(_ newConfig: CompositorConfig) {
        let fpsChanged: Bool
        lock.lock()
        let wasStreaming = config.isStreaming
        fpsChanged = config.fps != newConfig.fps || wasStreaming != newConfig.isStreaming
        config = newConfig
        if !wasStreaming && newConfig.isStreaming {
            streamStartUptimeNs = DispatchTime.now().uptimeNanoseconds
            emittedVideoFrames = 0
        } else if wasStreaming && !newConfig.isStreaming {
            streamStartUptimeNs = 0
            emittedVideoFrames = 0
        }
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
                leeway: .milliseconds(1)
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
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let cfg = config
        let screenBuf = latestScreenBuffer
        let cameraBuf = latestCameraBuffer

        var shouldEmitStreamFrame = cfg.isStreaming
        if cfg.isStreaming {
            if streamStartUptimeNs == 0 {
                streamStartUptimeNs = nowNs
                emittedVideoFrames = 0
            }
            let elapsedNs = nowNs >= streamStartUptimeNs ? (nowNs - streamStartUptimeNs) : 0
            let expectedFrames = (elapsedNs * UInt64(max(1, cfg.fps))) / 1_000_000_000 + 1
            if expectedFrames > emittedVideoFrames {
                emittedVideoFrames += 1
            } else {
                shouldEmitStreamFrame = false
            }
        }
        lock.unlock()

        // Skip GPU rendering completely when window is minimized/hidden and neither streaming nor recording
        if cfg.isPreviewPaused && !shouldEmitStreamFrame {
            return
        }

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
                    size: cfg.pipSize,
                    shape: cfg.pipShape
                )
                let pipImg = Self.aspectFillImage(camImg, into: pipRect)
                composite = Self.compositePiP(pipImg, in: pipRect, shape: cfg.pipShape, over: composite)
            }
        }

        let finalImage = composite.cropped(to: canvasRect)
        frameCounter += 1

        // Emit pooled BGRA bytes to FFmpeg when streaming (zero per-frame heap allocation)
        if shouldEmitStreamFrame, let onEncodedVideoFrame {
            let bytesPerRow = canvasWidth * 4
            let totalBytes = bytesPerRow * canvasHeight
            let buffer = bufferPool.acquire(byteCount: totalBytes)
            ciContext.render(
                finalImage,
                toBitmap: buffer.pointer,
                rowBytes: bytesPerRow,
                bounds: canvasRect,
                format: .BGRA8,
                colorSpace: colorSpace
            )
            onEncodedVideoFrame(buffer)
        }

        // Throttle preview CGImage updates when streaming at 60fps to keep SwiftUI smooth
        let previewStride = (cfg.isStreaming && cfg.fps >= 60) ? 2 : 1
        if frameCounter % previewStride == 0, let onPreviewFrame {
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
        size: PiPSize,
        shape: PiPShape
    ) -> CGRect {
        let width = (canvasWidth * size.widthFraction).rounded()
        let height = shape == .circle ? width : (width * 9.0 / 16.0).rounded()
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

    private static func compositePiP(_ pipImg: CIImage, in pipRect: CGRect, shape: PiPShape, over background: CIImage) -> CIImage {
        let borderInset: CGFloat = -3
        let borderRect = pipRect.insetBy(dx: borderInset, dy: borderInset)

        switch shape {
        case .rectangle:
            let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.28)).cropped(to: borderRect)
            return pipImg.composited(over: border.composited(over: background))

        case .rounded, .circle:
            let radius: CGFloat = (shape == .circle) ? (pipRect.width / 2.0) : min(22, pipRect.height * 0.14)
            let borderRadius = radius + abs(borderInset)

            guard let maskFilter = CIFilter(name: "CIRoundedRectangleGenerator"),
                  let borderFilter = CIFilter(name: "CIRoundedRectangleGenerator"),
                  let blendFilter = CIFilter(name: "CIBlendWithAlphaMask") else {
                let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.28)).cropped(to: borderRect)
                return pipImg.composited(over: border.composited(over: background))
            }

            borderFilter.setValue(CIVector(cgRect: borderRect), forKey: "inputExtent")
            borderFilter.setValue(borderRadius, forKey: "inputRadius")
            borderFilter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0.30), forKey: "inputColor")

            let bgWithBorder = borderFilter.outputImage?.composited(over: background) ?? background

            maskFilter.setValue(CIVector(cgRect: pipRect), forKey: "inputExtent")
            maskFilter.setValue(radius, forKey: "inputRadius")
            maskFilter.setValue(CIColor.white, forKey: "inputColor")

            guard let maskImg = maskFilter.outputImage else {
                return pipImg.composited(over: bgWithBorder)
            }

            blendFilter.setValue(pipImg, forKey: kCIInputImageKey)
            blendFilter.setValue(bgWithBorder, forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(maskImg, forKey: kCIInputMaskImageKey)
            return blendFilter.outputImage ?? pipImg.composited(over: bgWithBorder)
        }
    }
}
