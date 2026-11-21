import CoreVideo
import Foundation

struct SourceFrame {
    let buffer: CVPixelBuffer
    /// Host time in seconds (the same clock as `CACurrentMediaTime`).
    let time: CFTimeInterval
    /// Part of the buffer occupied by the image, measured from the top-left corner.
    let contentWidth: Int
    let contentHeight: Int
}

/// A source of frames in 4:2:0 NV12 format (`420v`), with IOSurface-backed buffers.
protocol FrameSource: AnyObject {
    /// Called for every new frame (off the main thread).
    var onFrame: ((SourceFrame) -> Void)? { get set }
    /// Called when the source stops on its own (e.g. the window was closed).
    var onStop: ((Error?) -> Void)? { get set }

    func start() async throws
    func stop() async
}
