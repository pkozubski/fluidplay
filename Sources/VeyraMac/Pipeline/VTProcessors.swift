import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

enum ProcessorError: LocalizedError {
    case unsupported(String)
    case allocationFailed

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): return what
        case .allocationFailed: return String(localized: "Couldn't allocate an output buffer.")
        }
    }
}

private func makePool(attributes: [String: Any]) -> CVPixelBufferPool? {
    var attrs = attributes
    attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
    if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
        attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
    }
    let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, attrs as CFDictionary, &pool)
    return pool
}

private func makeBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
        throw ProcessorError.allocationFailed
    }
    return buffer
}

private func time(_ seconds: CFTimeInterval) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000)
}

/// Intermediate frame generation: `VTLowLatencyFrameInterpolation` (VideoToolbox, macOS 26+).
/// Apple's ML model computes frames at selected points between two source frames. The points are
/// spaced every `phaseStep` (with `levels` = 2: 0.25 / 0.5 / 0.75), and a single call can
/// compute several of them at once.
final class FrameInterpolator {
    let width: Int
    let height: Int
    /// Spacing between available interpolation points (fraction of the interval between source frames).
    let phaseStep: Double

    private let processor = VTFrameProcessor()
    private let pool: CVPixelBufferPool
    private let sourceAttributes: [String: Any]

    static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    /// Starts the session. Loading the model takes 1–3 s — call off the main thread.
    /// `levels` is VideoToolbox's `numberOfInterpolatedFrames`: there are 2^levels − 1 available points.
    init(width: Int, height: Int, levels: Int = 2) throws {
        guard Self.isSupported else {
            throw ProcessorError.unsupported(String(localized: "This Mac doesn't support VideoToolbox frame interpolation."))
        }
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: max(1, levels))
        else {
            throw ProcessorError.unsupported(String(localized: "Interpolation doesn't support the size \(String(width))×\(String(height))."))
        }
        guard let pool = makePool(attributes: configuration.destinationPixelBufferAttributes) else {
            throw ProcessorError.allocationFailed
        }
        try processor.startSession(configuration: configuration)
        self.width = width
        self.height = height
        self.phaseStep = 1 / Double(1 << max(1, levels))
        self.pool = pool
        self.sourceAttributes = configuration.sourcePixelBufferAttributes
    }

    deinit { processor.endSession() }

    /// The first calls after the session starts are several times slower (up to ~140 ms) — the model is
    /// still warming up. We run them on dummy frames before the pipeline starts using it, so that
    /// generation doesn't begin with a series of late frames. Returns the call times (ms).
    @discardableResult
    func warmUp(calls: Int = 6) async -> [Double] {
        guard let sourcePool = makePool(attributes: sourceAttributes),
              let first = try? makeBuffer(from: sourcePool),
              let second = try? makeBuffer(from: sourcePool)
        else { return [] }
        fillGray(first, luma: 60)
        fillGray(second, luma: 70)
        var times: [Double] = []
        for index in 0..<calls {
            let started = CACurrentMediaTime()
            let t0 = Double(index) / 30
            guard (try? await interpolate(previous: first, previousTime: t0, current: second,
                                          currentTime: t0 + 1.0 / 30, phases: [0.5])) != nil
            else { break }
            times.append((CACurrentMediaTime() - started) * 1000)
        }
        return times
    }

    private func fillGray(_ buffer: CVPixelBuffer, luma: Int32) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        memset(lumaBase, luma, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
        memset(chromaBase, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    }

    /// The nearest available interpolation point (always strictly between 0 and 1).
    func quantize(_ phase: Double) -> Double {
        let steps = 1 / phaseStep
        let index = min(steps - 1, max(1, (phase / phaseStep).rounded()))
        return index * phaseStep
    }

    /// Frames at the given points (values from `quantize`, no duplicates), in the same order.
    func interpolate(previous: CVPixelBuffer, previousTime: CFTimeInterval,
                     current: CVPixelBuffer, currentTime: CFTimeInterval,
                     phases: [Double]) async throws -> [CVPixelBuffer] {
        guard !phases.isEmpty else { return [] }
        let outputs = try phases.map { _ in try makeBuffer(from: pool) }
        let span = currentTime - previousTime
        let destinations = zip(phases, outputs).compactMap { phase, output in
            VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time(previousTime + span * phase))
        }
        guard destinations.count == phases.count,
              let source = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: time(currentTime)),
              let reference = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: time(previousTime)),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: source, previousFrame: reference,
                interpolationPhase: phases.map { Float($0) }, destinationFrames: destinations)
        else { throw ProcessorError.allocationFailed }
        _ = try await processor.process(parameters: parameters)
        outputs.forEach(repairBottomEdge)
        return outputs
    }

    /// With a height not divisible by 16 (1080p) the model leaves the last two luma rows
    /// and the last chroma row corrupted — a greenish line would flicker on screen. We duplicate
    /// the last valid rows.
    private func repairBottomEdge(_ buffer: CVPixelBuffer) {
        guard height % 16 != 0, height >= 8 else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let goodLuma = lumaBase + (height - 3) * lumaStride
        memcpy(lumaBase + (height - 2) * lumaStride, goodLuma, width)
        memcpy(lumaBase + (height - 1) * lumaStride, goodLuma, width)
        memcpy(chromaBase + (chromaHeight - 1) * chromaStride, chromaBase + (chromaHeight - 2) * chromaStride, width)
    }
}

/// ML super resolution: `VTLowLatencySuperResolutionScaler` (VideoToolbox, macOS 26+).
/// Works only for small inputs (on M3: 1280×720 and 1024×576 at 1.5×, 848×480 at 2×).
final class SuperResolver {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let scale: Float

    private let processor = VTFrameProcessor()
    private let pool: CVPixelBufferPool

    /// The largest supported scale factor for the given input size, or `nil`.
    static func bestScale(width: Int, height: Int) -> Float? {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else { return nil }
        return VTLowLatencySuperResolutionScalerConfiguration
            .supportedScaleFactors(frameWidth: width, frameHeight: height)
            .filter { Float(width) * $0 * Float(height) * $0 <= 3840 * 2160 }
            .max()
    }

    init(width: Int, height: Int) throws {
        guard let scale = Self.bestScale(width: width, height: height) else {
            throw ProcessorError.unsupported(String(localized: "ML super resolution doesn't support the input \(String(width))×\(String(height))."))
        }
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: scale)
        guard let pool = makePool(attributes: configuration.destinationPixelBufferAttributes) else {
            throw ProcessorError.allocationFailed
        }
        try processor.startSession(configuration: configuration)
        self.inputWidth = width
        self.inputHeight = height
        self.scale = scale
        self.pool = pool
        let attributes = configuration.destinationPixelBufferAttributes
        self.outputWidth = attributes[kCVPixelBufferWidthKey as String] as? Int ?? Int((Float(width) * scale).rounded())
        self.outputHeight = attributes[kCVPixelBufferHeightKey as String] as? Int ?? Int((Float(height) * scale).rounded())
    }

    deinit { processor.endSession() }

    func upscale(_ input: CVPixelBuffer, time seconds: CFTimeInterval) async throws -> CVPixelBuffer {
        let output = try makeBuffer(from: pool)
        guard let source = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: time(seconds)),
              let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time(seconds))
        else { throw ProcessorError.allocationFailed }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: source, destinationFrame: destination)
        _ = try await processor.process(parameters: parameters)
        return output
    }
}
