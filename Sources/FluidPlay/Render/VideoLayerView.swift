import AppKit
import Metal
import QuartzCore

/// A Metal-layer view that, on every display refresh, takes the frame with the matching deadline from the queue.
final class VideoLayerView: NSView, CAMetalDisplayLinkDelegate {
    let renderer: MetalRenderer
    let metalLayer = CAMetalLayer()

    /// Number of new frames actually sent to the screen per second.
    let presentMeter = Locked(RateMeter())
    /// Drawable size in pixels.
    let drawablePixels = Locked((width: 0, height: 0))
    /// Smoothness measurement of the current session (gaps between new frames on screen).
    let monitor = Locked<SessionMonitor?>(nil)

    private let queue: PresentQueue
    private let pendingRedraw = Locked(true)
    private let pendingReset = Locked(false)
    private var link: CAMetalDisplayLink?
    private var renderThread: Thread?

    // Render thread state.
    private var current: VideoFrame?
    private var lastNewFrameTarget: CFTimeInterval = 0
    private weak var lastMonitor: SessionMonitor?
    private var lastDrawableSize = (0, 0)

    /// A paused view doesn't take frames from the queue (the other view is active then).
    var isActive = true {
        didSet {
            link?.isPaused = !isActive
            if isActive { setNeedsRedraw() }
        }
    }

    init(core: RenderCore, queue: PresentQueue, opaque: Bool) {
        self.renderer = MetalRenderer(core: core)
        self.queue = queue
        super.init(frame: .zero)
        metalLayer.device = core.device
        metalLayer.pixelFormat = RenderCore.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.isOpaque = opaque
        metalLayer.backgroundColor = opaque ? NSColor.black.cgColor : NSColor.clear.cgColor
        metalLayer.maximumDrawableCount = 3
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { stopLink() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    /// Refresh rate of the display the view is on.
    var displayHz: Double {
        let hz = Double(window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        displayHzCached = hz
        return hz
    }

    /// Copy of `displayHz` for the render thread (the window may only be read from the main thread).
    private var displayHzCached: Double = 60

    /// Forces the current frame to be redrawn (e.g. after a settings change).
    func setNeedsRedraw() { pendingRedraw.set(true) }

    /// Clears the image after the source stops.
    func reset() {
        pendingReset.set(true)
        pendingRedraw.set(true)
    }

    // MARK: Size

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateDrawableSize()
            startLink()
        } else {
            stopLink()
        }
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            setNeedsRedraw()
        }
    }

    // MARK: Display link

    private func startLink() {
        guard link == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 1
        let hz = Float(displayHz)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, hz), maximum: hz, preferred: hz)
        link.isPaused = !isActive
        self.link = link

        let thread = Thread {
            link.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled, RunLoop.current.run(mode: .default, before: .distantFuture) {}
        }
        thread.name = "fluidplay.render"
        thread.qualityOfService = .userInteractive
        renderThread = thread
        thread.start()
    }

    private func stopLink() {
        renderThread?.cancel()
        renderThread = nil
        link?.invalidate()
        link = nil
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        var changed = pendingRedraw.with { flag -> Bool in
            defer { flag = false }
            return flag
        }
        if pendingReset.with({ flag -> Bool in defer { flag = false }; return flag }) {
            current = nil
        }
        // A frame's deadline means "show at the first refresh after this instant".
        let now = CACurrentMediaTime()
        queue.clock.tick(now: now, nominalHz: displayHzCached)
        if let frame = queue.pop(now: now + 0.001) {
            current = frame
            changed = true
            presentMeter.with { $0.tick() }
            if let monitor = monitor.get() {
                let target = update.targetPresentationTimestamp
                if lastMonitor === monitor, lastNewFrameTarget > 0 {
                    let refresh = 1 / max(30, displayHzCached)
                    monitor.recordPresent(gap: Int(((target - lastNewFrameTarget) / refresh).rounded()))
                }
                lastMonitor = monitor
                lastNewFrameTarget = target
            }
        }

        let drawable = update.drawable
        let size = (drawable.texture.width, drawable.texture.height)
        if size != lastDrawableSize {
            lastDrawableSize = size
            drawablePixels.set((width: size.0, height: size.1))
            changed = true
        }
        // Without new content we don't use the GPU.
        guard changed, let commandBuffer = renderer.core.commandQueue.makeCommandBuffer() else { return }

        var drawn = false
        if let current {
            drawn = renderer.encode(frame: current, into: drawable.texture, commandBuffer: commandBuffer)
        }
        if !drawn {
            renderer.encodeClear(into: drawable.texture, commandBuffer: commandBuffer)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
