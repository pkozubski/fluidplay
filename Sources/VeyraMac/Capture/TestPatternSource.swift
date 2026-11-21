import CoreVideo
import Foundation
import QuartzCore

/// A synthetic source for testing the pipeline without a console and without Screen Recording permission.
final class TestPatternSource: FrameSource {
    enum Cadence: String, CaseIterable {
        /// 30 unique frames per second.
        case fps30
        /// 60 unique frames per second.
        case fps60
        /// A 30 fps game in a 60 fps stream — every frame sent twice (as in Remote Play).
        case fps30in60
        /// 24, 40 and 50 fps games in a 60 fps stream: every 1/60 s the console sends the latest finished frame,
        /// so new frames arrive unevenly (e.g. at 40: alternately 17 and 33 ms apart).
        case fps24in60, fps40in60, fps50in60

        var deliveryRate: Double { self == .fps30 ? 30 : 60 }

        /// Frame rate of the game itself.
        var gameRate: Double {
            switch self {
            case .fps30, .fps30in60: return 30
            case .fps60: return 60
            case .fps24in60: return 24
            case .fps40in60: return 40
            case .fps50in60: return 50
            }
        }

        var label: String {
            switch self {
            case .fps30: return String(localized: "Test pattern 30 fps")
            case .fps60: return String(localized: "Test pattern 60 fps")
            case .fps30in60: return String(localized: "Test pattern 30 fps in a 60 fps stream")
            case .fps24in60: return String(localized: "Test pattern 24 fps in a 60 fps stream")
            case .fps40in60: return String(localized: "Test pattern 40 fps in a 60 fps stream")
            case .fps50in60: return String(localized: "Test pattern 50 fps in a 60 fps stream")
            }
        }
    }

    var onFrame: ((SourceFrame) -> Void)?
    var onStop: ((Error?) -> Void)?
    /// Random delay of each frame (0…`jitter` s) — as with transmission over Wi‑Fi. Smaller
    /// than the interval between frames, so the order doesn't change.
    var jitter: CFTimeInterval = 0

    private let width: Int
    private let height: Int
    private let cadence: Cadence
    private let queue = DispatchQueue(label: "veyramac.testpattern", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var backgroundLuma: [UInt8] = []
    private var tick = 0

    init(width: Int = 1920, height: Int = 1080, cadence: Cadence) {
        self.width = width
        self.height = height
        self.cadence = cadence
    }

    func start() async throws {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        self.pool = pool
        backgroundLuma = Self.makeBackground(width: width, height: height)

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / cadence.deliveryRate, leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.emit() }
        self.timer = timer
        timer.resume()
    }

    func stop() async {
        timer?.cancel()
        timer = nil
    }

    private static func makeBackground(width: Int, height: Int) -> [UInt8] {
        var luma = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowShade = 40 + (y * 50) / height
            for x in 0..<width {
                // A subtle grid so the interpolator has texture to track.
                let grid = ((x / 60) + (y / 60)) % 2 == 0 ? 10 : 0
                luma[y * width + x] = UInt8(rowShade + grid)
            }
        }
        return luma
    }

    private func emit() {
        guard let pool, let onFrame else { return }
        // The latest game frame finished at send time.
        let uniqueIndex = Int((Double(tick) * cadence.gameRate / cadence.deliveryRate + 1e-9).rounded(.down))
        tick += 1

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        draw(into: buffer, index: uniqueIndex)
        let limit = min(jitter, 0.9 / cadence.deliveryRate)
        guard limit > 0 else {
            onFrame(SourceFrame(buffer: buffer, time: CACurrentMediaTime(), contentWidth: width, contentHeight: height))
            return
        }
        let (width, height) = (self.width, self.height)
        queue.asyncAfter(deadline: .now() + Double.random(in: 0...limit)) {
            onFrame(SourceFrame(buffer: buffer, time: CACurrentMediaTime(), contentWidth: width, contentHeight: height))
        }
    }

    private func draw(into buffer: CVPixelBuffer, index: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        backgroundLuma.withUnsafeBufferPointer { background in
            for y in 0..<height {
                memcpy(luma + y * lumaStride, background.baseAddress! + y * width, width)
            }
        }
        memset(chroma, 128, chromaStride * chromaHeight)

        // Game time counted in its own frames, independent of repeats in the stream.
        let seconds = Double(index) / cadence.gameRate

        // A vertical bar moving horizontally — the easiest way to judge smoothness.
        let barWidth = width / 24
        let travel = Double(width - barWidth)
        let phase = (seconds * 0.35).truncatingRemainder(dividingBy: 2)
        let barX = Int((phase < 1 ? phase : 2 - phase) * travel)
        fillRect(luma: luma, lumaStride: lumaStride, chroma: chroma, chromaStride: chromaStride,
                 x: barX, y: height / 8, w: barWidth, h: height / 3, yValue: 235, cb: 128, cr: 128)

        // A colored square moving in a circle.
        let radius = Double(height) * 0.22
        let side = height / 7
        let cx = Double(width) * 0.5 + cos(seconds * 2.2) * radius * 1.6
        let cy = Double(height) * 0.68 + sin(seconds * 2.2) * radius * 0.7
        fillRect(luma: luma, lumaStride: lumaStride, chroma: chroma, chromaStride: chromaStride,
                 x: Int(cx) - side / 2, y: Int(cy) - side / 2, w: side, h: side, yValue: 150, cb: 60, cr: 200)
    }

    private func fillRect(luma: UnsafeMutablePointer<UInt8>, lumaStride: Int,
                          chroma: UnsafeMutablePointer<UInt8>, chromaStride: Int,
                          x: Int, y: Int, w: Int, h: Int, yValue: UInt8, cb: UInt8, cr: UInt8) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return }
        for row in y0..<y1 {
            memset(luma + row * lumaStride + x0, Int32(yValue), x1 - x0)
        }
        for row in (y0 / 2)..<(y1 / 2) {
            var p = chroma + row * chromaStride + (x0 / 2) * 2
            for _ in (x0 / 2)..<(x1 / 2) {
                p[0] = cb
                p[1] = cr
                p += 2
            }
        }
    }
}
