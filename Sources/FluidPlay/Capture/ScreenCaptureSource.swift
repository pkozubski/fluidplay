import AppKit
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ScreenCaptureKit

/// Captures a window (e.g. PS Remote Play) or an entire display via ScreenCaptureKit.
final class ScreenCaptureSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    enum Target {
        case window(SCWindow)
        /// A display excluding the windows of the given apps (our own — so the overlay isn't recorded).
        case display(SCDisplay, excluding: [SCRunningApplication])
    }

    struct Options {
        var resolution: ProcessingResolution = .auto
        var cropTitleBar = true
        var maxFrameRate = 120
    }

    var onFrame: ((SourceFrame) -> Void)?
    var onStop: ((Error?) -> Void)?

    private let target: Target
    private let options: Options
    private let queue = DispatchQueue(label: "fluidplay.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var pixelScale: CGFloat = 2
    private var trackedWindowSize: CGSize?
    /// Image size within the canvas for the current configuration (read from the capture queue).
    private let content = Locked((width: 0, height: 0))

    init(target: Target, options: Options) {
        self.target = target
        self.options = options
    }

    /// Height of the standard title bar on the current system (points).
    static var titleBarHeight: CGFloat {
        let content = NSRect(x: 0, y: 0, width: 400, height: 300)
        let frame = NSWindow.frameRect(forContentRect: content, styleMask: [.titled])
        return frame.height - content.height
    }

    func start() async throws {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        switch target {
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            pixelScale = CGFloat(max(filter.pointPixelScale, 1))
            trackedWindowSize = window.frame.size
            configuration = makeConfiguration(contentPoints: window.frame.size, isWindow: true)
        case .display(let display, let excluded):
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            pixelScale = CGFloat(max(filter.pointPixelScale, 1))
            configuration = makeConfiguration(contentPoints: filter.contentRect.size, isWindow: false)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// Checks whether the window changed size (e.g. went full screen) and adjusts the capture.
    /// Call every second or two.
    func refreshGeometry() async {
        guard case .window(let window) = target, let stream,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let fresh = content.windows.first(where: { $0.windowID == window.windowID })
        else { return }
        let size = fresh.frame.size
        guard let tracked = trackedWindowSize, abs(tracked.width - size.width) > 1 || abs(tracked.height - size.height) > 1 else { return }
        trackedWindowSize = size
        try? await stream.updateConfiguration(makeConfiguration(contentPoints: size, isWindow: true))
    }

    private func makeConfiguration(contentPoints: CGSize, isWindow: Bool) -> SCStreamConfiguration {
        // In full screen the window has no title bar — only crop windows in normal mode.
        var content = contentPoints
        var sourceRect: CGRect?
        if isWindow, options.cropTitleBar {
            let isFullScreen = NSScreen.screens.contains {
                abs($0.frame.width - contentPoints.width) < 2 && abs($0.frame.height - contentPoints.height) < 2
            }
            let bar = Self.titleBarHeight
            if !isFullScreen, contentPoints.height > bar + 64 {
                content = CGSize(width: contentPoints.width, height: contentPoints.height - bar)
                sourceRect = CGRect(x: 0, y: bar, width: content.width, height: content.height)
            }
        }

        // Capture onto a canvas of a size the interpolator accepts; an image with a different
        // aspect ratio lands in its top-left corner, and the renderer crops just that part.
        let pixels = CGSize(width: content.width * pixelScale, height: content.height * pixelScale)
        let canvas = options.resolution.resolved(contentPixelHeight: pixels.height).canvas
        let fitted = FrameGeometry.fit(content: pixels, canvasWidth: canvas.width, canvasHeight: canvas.height)
        self.content.set(fitted)

        let config = SCStreamConfiguration()
        config.width = canvas.width
        config.height = canvas.height
        config.destinationRect = CGRect(x: 0, y: 0, width: fitted.width, height: fitted.height)
        config.backgroundColor = CGColor.black
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.maxFrameRate))
        config.queueDepth = 5
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = true
        config.captureResolution = .best
        if let sourceRect { config.sourceRect = sourceRect }
        return config
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        let now = CACurrentMediaTime()
        var time = sampleBuffer.presentationTimeStamp.seconds
        // The SCK timestamp is in host clock; if it were invalid, we use the receive time.
        if !time.isFinite || abs(now - time) > 1 { time = now }
        // After a configuration change, frames in the old size may still arrive for a moment.
        let fitted = content.get()
        let width = min(fitted.width, CVPixelBufferGetWidth(pixelBuffer))
        let height = min(fitted.height, CVPixelBufferGetHeight(pixelBuffer))
        onFrame?(SourceFrame(buffer: pixelBuffer, time: time, contentWidth: width, contentHeight: height))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
