import AppKit
import CoreVideo
import Foundation
import ImageIO
import Metal
import QuartzCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Command-line diagnostics — lets you check the pipeline without the UI.
///
///     FluidPlay --selftest [fps30|fps60|fps30in60|fps24in60|fps40in60|fps50in60] [--seconds 6] [--size 1920x1080] [--sr] [--always]
///              [--render] [--jitter ms] [--dump directory]
///       --render draws every new frame through MetalFX like the full-screen view (GPU shared as in a game),
///       --jitter delays every frame randomly by 0…ms (like Wi‑Fi).
///     FluidPlay --capture-test <window name fragment> [--seconds 6] [--height 1080] [--dump directory]
///     FluidPlay --list-windows
///     FluidPlay --discover                      (looks for PlayStation consoles on the local network)
///     FluidPlay --decode-test <Annex B file> [--hevc] [--decode-size 1024x576] [--seconds 6] [--dump directory]
///     FluidPlay --rp-dry-run                    (session attempt with empty keys: checks handling of the console's refusal)
enum SelfTest {
    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains { ["--selftest", "--capture-test", "--list-windows", "--discover", "--decode-test", "--rp-dry-run",
                              "--motion-test"].contains($0) }
    }

    static func run(_ arguments: [String]) -> Never {
        Task {
            do {
                if arguments.contains("--list-windows") {
                    try await listWindows()
                } else if arguments.contains("--discover") {
                    let consoles = await RemotePlayClient.discover(duration: 3)
                    print(consoles.isEmpty ? "No consoles found." : "Consoles found: \(consoles.count)")
                    for console in consoles {
                        print("  \(console.isPS5 ? "PS5" : "PS4")  state: \(console.state)  game: \(console.runningApp.isEmpty ? "—" : console.runningApp)")
                    }
                } else if arguments.contains("--rp-dry-run") {
                    try await remotePlayDryRun()
                } else if arguments.contains("--motion-test") {
                    try await motionTest(seconds: value("--seconds", in: arguments).flatMap(Double.init) ?? 15)
                } else if let index = arguments.firstIndex(of: "--decode-test") {
                    guard arguments.indices.contains(index + 1) else {
                        throw ProcessorError.unsupported("Specify an Annex B stream file.")
                    }
                    var decodeSize: (width: Int, height: Int)?
                    if let text = value("--decode-size", in: arguments) {
                        let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
                        if parts.count == 2 { decodeSize = (parts[0], parts[1]) }
                    }
                    let source = try FileStreamSource(path: arguments[index + 1], hevc: arguments.contains("--hevc"), outputSize: decodeSize)
                    source.jitter = (value("--jitter", in: arguments).flatMap(Double.init) ?? 0) / 1000
                    print("Source: file \(arguments[index + 1]) via the VideoToolbox decoder")
                    try await runSession(source: source, arguments: arguments)
                } else if let index = arguments.firstIndex(of: "--capture-test") {
                    let match = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
                    try await captureTest(match: match, arguments: arguments)
                } else {
                    try await patternTest(arguments: arguments)
                }
                exit(0)
            } catch {
                print("ERROR: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func value(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    // MARK: Tests

    private static func listWindows() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        for window in content.windows where window.windowLayer == 0 && window.frame.width >= 320 && window.frame.height >= 240 {
            let app = window.owningApplication?.applicationName ?? "?"
            print("\(window.windowID)\t\(window.isOnScreen ? "visible" : "hidden ")\t\(Int(window.frame.width))x\(Int(window.frame.height))\t\(app)\t\(window.title ?? "")")
        }
        for display in content.displays {
            print("display \(display.displayID)\t\(display.width)x\(display.height)")
        }
    }

    /// Connects to a discovered console using empty keys. The console must refuse — the test checks
    /// whether the refusal comes back as a readable error and whether the session cleans up after itself without hanging.
    private static func remotePlayDryRun() async throws {
        guard let console = await RemotePlayClient.discover(duration: 2).first(where: \.isPS5) else {
            throw ProcessorError.unsupported("No PS5 found on the network.")
        }
        let fake = RegisteredConsole(id: "test", nickname: "test", host: console.address,
                                     registKey: Data(count: 16), rpKey: Data(count: 16), accountID: Data(count: 8))
        let source = RemotePlaySource(console: fake, options: RemotePlaySource.Options())
        source.onEvent = { event in print("Event: \(event)") }
        let started = CACurrentMediaTime()
        do {
            try await source.start()
            print("UNEXPECTED: the console accepted a session with empty keys")
            await source.stop()
        } catch {
            print(String(format: "Refused after %.1f s: %@", CACurrentMediaTime() - started, error.localizedDescription))
        }
        print("Session closed without hanging.")
    }

    /// Prints the controller's motion sensor readings converted to the axes sent to the console (SDL).
    /// Controller lying flat: accelerometer ≈ (0, +1, 0). Rotating right around the vertical axis: gyro Y < 0.
    private static func motionTest(seconds: Double) async throws {
        let input = GamepadInput()
        let latest = Locked<VRPController?>(nil)
        input.onState = { state in latest.set(state) }
        input.start()
        print("Motion sensors: lay the controller flat, then tilt it front-down and rotate it to the right.")
        let steps = Int(seconds * 4)
        for _ in 0..<steps {
            try await Task.sleep(for: .milliseconds(250))
            guard let state = latest.get() else {
                print("  no controller")
                continue
            }
            guard state.motion else {
                print("  controller without motion data (\(GamepadInput.connectedName ?? "?"))")
                continue
            }
            print(String(format: "  accelerometer [g] x %+5.2f y %+5.2f z %+5.2f   gyro [rad/s] x %+5.2f y %+5.2f z %+5.2f",
                         state.accel.0, state.accel.1, state.accel.2, state.gyro.0, state.gyro.1, state.gyro.2))
        }
        input.stop()
    }

    private static func patternTest(arguments: [String]) async throws {
        let cadence = TestPatternSource.Cadence.allCases.first { arguments.contains($0.rawValue) } ?? .fps30
        var size = (1920, 1080)
        if let text = value("--size", in: arguments) {
            let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { size = (parts[0], parts[1]) }
        }
        let source = TestPatternSource(width: size.0, height: size.1, cadence: cadence)
        source.jitter = (value("--jitter", in: arguments).flatMap(Double.init) ?? 0) / 1000
        print("Source: \(cadence.label), \(size.0)×\(size.1)\(source.jitter > 0 ? String(format: ", arrival jitter up to %.0f ms", source.jitter * 1000) : "")")
        try await runSession(source: source, arguments: arguments)
    }

    private static func captureTest(match: String, arguments: [String]) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let needle = match.lowercased()
        let candidates = content.windows.filter { window in
            guard window.windowLayer == 0, window.frame.width >= 320, window.frame.height >= 240 else { return false }
            let text = ((window.owningApplication?.applicationName ?? "") + " " + (window.title ?? "")).lowercased()
            return needle.isEmpty || text.contains(needle)
        }
        guard let window = candidates.first(where: { $0.isOnScreen }) ?? candidates.first else {
            throw ProcessorError.unsupported("No window matching \"\(match)\" found.")
        }
        var options = ScreenCaptureSource.Options()
        if let height = value("--height", in: arguments).flatMap(Int.init),
           let resolution = ProcessingResolution(rawValue: height) {
            options.resolution = resolution
        }
        let source = ScreenCaptureSource(target: .window(window), options: options)
        print("Source: window \"\(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "")\" \(Int(window.frame.width))×\(Int(window.frame.height)) pt")
        try await runSession(source: source, arguments: arguments)
    }

    private static func runSession(source: FrameSource, arguments: [String]) async throws {
        let seconds = value("--seconds", in: arguments).flatMap(Double.init) ?? 6
        let displayHz = value("--hz", in: arguments).flatMap(Double.init) ?? 60
        let monitor = SessionMonitor(title: "autotest", log: arguments.contains("--log"))
        let pipeline = FramePipeline(monitor: monitor)
        pipeline.config.set(FramePipeline.Config(
            frameGen: arguments.contains("--off") ? .off : (arguments.contains("--always") ? .always : .auto),
            dedupe: !arguments.contains("--no-dedupe"),
            mlSuperRes: arguments.contains("--sr"),
            displayHz: displayHz))

        struct Collected {
            var frames = 0
            var generated = 0
            var late = 0
            var lastSource: VideoFrame?
            var lastGenerated: VideoFrame?
            var dueGaps: [Double] = []
            var previousDue: CFTimeInterval = 0
        }
        let collected = Locked(Collected())

        // Simulated display: on every refresh it takes a frame from the same queue the view uses.
        struct Screen {
            var refreshes = 0
            var presented = 0
            var presentedGenerated = 0
            var repeats = 0
            var lastPresent: CFTimeInterval = 0
            /// Content instant of the previous refresh (also a repeated one).
            var lastContent: CFTimeInterval = 0
            /// Content advance per refresh — always the same with even motion.
            var contentSteps: [Double] = []
        }
        let presentQueue = PresentQueue()
        pipeline.displayClock.set(presentQueue.clock)
        let screen = Locked(Screen())
        // --render: draw every new frame like the full-screen view (MetalFX to 2880×1864),
        // so interpolation shares the GPU with display the same way as in a game.
        let display = arguments.contains("--render") ? OffscreenDisplay(width: 2880, height: 1864) : nil
        if arguments.contains("--render") {
            print(display == nil ? "Rendering: unavailable (\(RenderCore.startupError ?? "no Metal"))"
                                 : "Rendering: every new frame through MetalFX to 2880×1864")
        }
        let displayTimer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "fluidplay.selftest.display", qos: .userInteractive))
        displayTimer.schedule(deadline: .now(), repeating: 1.0 / displayHz, leeway: .microseconds(100))
        displayTimer.setEventHandler {
            let now = CACurrentMediaTime()
            presentQueue.clock.tick(now: now, nominalHz: displayHz)
            let frame = presentQueue.pop(now: now + 0.001)
            if let frame { display?.draw(frame) }
            screen.with { state in
                state.refreshes += 1
                if let frame {
                    state.presented += 1
                    if frame.isGenerated { state.presentedGenerated += 1 }
                    if state.lastPresent > 0 {
                        monitor.recordPresent(gap: Int(((now - state.lastPresent) * displayHz).rounded()))
                    }
                    state.lastPresent = now
                } else {
                    state.repeats += 1
                }
                let content = frame?.captureTime ?? state.lastContent
                if state.lastContent > 0, state.refreshes > Int(displayHz * 2) {
                    state.contentSteps.append((content - state.lastContent) * 1000)
                }
                state.lastContent = content
            }
        }
        displayTimer.resume()

        pipeline.output = { frame in
            presentQueue.push(frame)
            let now = CACurrentMediaTime()
            collected.with { state in
                state.frames += 1
                if frame.isGenerated {
                    state.generated += 1
                    state.lastGenerated = frame
                } else {
                    state.lastSource = frame
                }
                if frame.dueTime > 0 {
                    let deadline = frame.onDisplayGrid ? frame.dueTime + 0.5 / displayHz : frame.dueTime
                    if deadline < now { state.late += 1 }
                    if state.previousDue > 0 { state.dueGaps.append((frame.dueTime - state.previousDue) * 1000) }
                    state.previousDue = frame.dueTime
                }
            }
        }
        source.onFrame = { frame in pipeline.submit(frame) }
        source.onStop = { error in print("Source stopped: \(error?.localizedDescription ?? "no error")") }

        try await source.start()
        let steps = max(1, Int(seconds))
        for second in 1...steps {
            try await Task.sleep(for: .seconds(seconds / Double(steps)))
            let s = pipeline.stats.get()
            let target: Double
            switch s.frameGen {
            case .active: target = displayHz
            case .bypass(let fps): target = min(displayHz, fps)
            default: target = min(displayHz, s.uniqueFps)
            }
            let smooth = monitor.rollSecond(targetFps: target, displayHz: displayHz)
            print(String(format: "       smoothness %.1f%%, hitches %d (network %d, Mac %d, source %d)",
                         smooth.smoothness, smooth.hitches, smooth.hitchesNetwork, smooth.hitchesMac, smooth.hitchesSource))
            print(String(format: "[%2d s] canvas %dx%d image %dx%d  %.1f fps (unique %.1f)  output %.1f fps %dx%d  FG %@ %.2f ms  SR %@ %.2f ms  latency +%.1f ms",
                         second, s.inputWidth, s.inputHeight, s.contentWidth, s.contentHeight, s.captureFps, s.uniqueFps, s.emittedFps,
                         s.outputWidth, s.outputHeight, describe(s.frameGen), s.interpolateMs,
                         describe(s.superRes), s.superResMs, s.addedLatencyMs))
        }
        await source.stop()
        pipeline.stop()
        displayTimer.cancel()
        let shown = screen.get()
        print(String(format: "Simulated display %.0f Hz: %d refreshes, %d new frames (%.1f fps, %d of them generated), %d refreshes without a new frame",
                     displayHz, shown.refreshes, shown.presented, Double(shown.presented) / seconds, shown.presentedGenerated, shown.repeats))
        if shown.contentSteps.count > 10 {
            // Motion evenness: how far the content advances between consecutive display refreshes.
            let steps = shown.contentSteps
            let mean = steps.reduce(0, +) / Double(steps.count)
            let deviation = steps.map { abs($0 - mean) }.sorted()
            let frozen = steps.filter { $0 < 0.5 }.count
            print(String(format: "On-screen motion: mean %.2f ms of content per refresh, deviation median %.2f ms, p95 %.2f ms, max %.2f ms; refreshes without motion %d (%.1f%%)",
                         mean, deviation[deviation.count / 2], deviation[Int(Double(deviation.count) * 0.95)],
                         deviation.last ?? 0, frozen, Double(frozen) / Double(steps.count) * 100))
        }

        let warmup = pipeline.warmupTimes.get()
        if !warmup.isEmpty {
            print("Model warm-up (in background): " + warmup.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " ms")
        }
        let result = collected.get()
        let stats = pipeline.stats.get()
        let gaps = result.dueGaps.sorted()
        print("Total: \(result.frames) output frames, \(result.generated) of them generated; skipped duplicates: \(stats.duplicates); late vs. deadline: \(result.late)")
        if !gaps.isEmpty {
            print(String(format: "Display deadline intervals: median %.2f ms, p5 %.2f ms, p95 %.2f ms",
                         gaps[gaps.count / 2], gaps[Int(Double(gaps.count) * 0.05)], gaps[Int(Double(gaps.count) * 0.95)]))
        }

        if let directory = value("--dump", in: arguments) {
            try dump(result.lastSource, name: "source", directory: directory)
            try dump(result.lastGenerated, name: "generated", directory: directory)
        }
    }

    /// Windowless display: draws frames with the same renderer as the view (MetalFX + sharpening).
    private final class OffscreenDisplay {
        private let renderer: MetalRenderer
        private let core: RenderCore
        private let targets: [MTLTexture]
        private var index = 0

        init?(width: Int, height: Int) {
            guard let core = RenderCore.shared else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: RenderCore.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            // Three targets like the layer's three buffers — consecutive frames don't wait for each other.
            let targets = (0..<3).compactMap { _ in core.device.makeTexture(descriptor: descriptor) }
            guard targets.count == 3 else { return nil }
            self.core = core
            self.targets = targets
            renderer = MetalRenderer(core: core)
            renderer.settings.set(RenderSettings(metalFX: true, sharpness: 0.5))
        }

        func draw(_ frame: VideoFrame) {
            guard let commandBuffer = core.commandQueue.makeCommandBuffer() else { return }
            index = (index + 1) % targets.count
            if renderer.encode(frame: frame, into: targets[index], commandBuffer: commandBuffer) {
                commandBuffer.commit()
            }
        }
    }

    private static func describe(_ state: FramePipeline.FrameGenState) -> String {
        switch state {
        case .off: return "off"
        case .measuring: return "measuring"
        case .loading: return "loading"
        case .bypass(let fps): return String(format: "skipped(%.0f)", fps)
        case .tooSlow(let fps, let ms): return String(format: "too slow(%.0f fps, %.0f ms)", fps, ms)
        case .active(let fps): return String(format: "active(%.0f→display)", fps)
        case .failed(let message): return "error(\(message))"
        }
    }

    private static func describe(_ state: FramePipeline.SuperResState) -> String {
        switch state {
        case .off: return "off"
        case .loading: return "loading"
        case .active(_, _, let scale): return String(format: "active(%.1f×)", scale)
        case .unsupported: return "unsupported"
        case .failed(let message): return "error(\(message))"
        }
    }

    // MARK: Dump via the renderer (checks shaders and MetalFX)

    private static func dump(_ frame: VideoFrame?, name: String, directory: String) throws {
        guard let frame else {
            print("Dump \"\(name)\": no frame")
            return
        }
        guard let core = RenderCore.shared else {
            throw ProcessorError.unsupported("Renderer unavailable: \(RenderCore.startupError ?? "no Metal device")")
        }
        let renderer = MetalRenderer(core: core)
        renderer.settings.set(RenderSettings(metalFX: true, sharpness: 0.25))

        // Target like a MacBook display in 16:10 proportions — a 16:9 frame gets black bars.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderCore.pixelFormat, width: 2880, height: 1800, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = core.device.makeTexture(descriptor: descriptor),
              let commandBuffer = core.commandQueue.makeCommandBuffer()
        else { throw ProcessorError.allocationFailed }
        guard renderer.encode(frame: frame, into: target, commandBuffer: commandBuffer) else {
            throw ProcessorError.unsupported("The renderer rejected the frame.")
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }

        let bytesPerRow = target.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * target.height)
        target.getBytes(&pixels, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: target.width, height: target.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ProcessorError.allocationFailed }

        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ProcessorError.allocationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        let w = CVPixelBufferGetWidth(frame.pixelBuffer), h = CVPixelBufferGetHeight(frame.pixelBuffer)
        print("Dump \"\(name)\": buffer \(w)×\(h), image \(frame.contentWidth)×\(frame.contentHeight) → \(target.width)×\(target.height), MetalFX: \(renderer.usedMetalFX ? "yes" : "no") → \(url.path)")
    }
}


/// Diagnostic source: feeds an Annex B stream from a file into the same decoder the built-in
/// Remote Play uses. Access units must be separated by AUD delimiters.
private final class FileStreamSource: FrameSource {
    var onFrame: ((SourceFrame) -> Void)?
    var onStop: ((Error?) -> Void)?

    private let units: [[UInt8]]
    private let decoder: VideoDecoder
    private let queue = DispatchQueue(label: "fluidplay.selftest.stream", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var index = 0
    private var failures = 0
    /// Random delivery delay of each frame (s) — simulates uneven Wi‑Fi.
    var jitter: Double = 0

    init(path: String, hevc: Bool, outputSize: (width: Int, height: Int)?) throws {
        let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        // Split into access units: each starts with an AUD delimiter (H.264 type 9, H.265 type 35).
        var starts: [Int] = []
        var i = 0
        while i + 4 < data.count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                let header = data[i + 3]
                let isDelimiter = hevc ? ((header >> 1) & 0x3F) == 35 : (header & 0x1F) == 9
                if isDelimiter { starts.append(i > 0 && data[i - 1] == 0 ? i - 1 : i) }
                i += 3
            } else {
                i += 1
            }
        }
        guard starts.count > 2 else {
            throw ProcessorError.unsupported("The file has no AUD delimiters — generate it with the aud=1 option.")
        }
        var units: [[UInt8]] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : data.count
            units.append(Array(data[start..<end]))
        }
        self.units = units
        decoder = VideoDecoder(codec: hevc ? .h265 : .h264, outputSize: outputSize)
    }

    func start() async throws {
        decoder.onFrame = { [weak self] buffer, time in
            self?.onFrame?(SourceFrame(buffer: buffer, time: time,
                                       contentWidth: CVPixelBufferGetWidth(buffer),
                                       contentHeight: CVPixelBufferGetHeight(buffer)))
        }
        decoder.onDecodeError = { status in print("Decoder error: \(status)") }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.feed() }
        self.timer = timer
        timer.resume()
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        queue.sync {}
        decoder.invalidate()
        if failures > 0 { print("Rejected samples: \(failures)") }
    }

    private func feed() {
        // After reaching the end, start again from the first unit (keyframe with parameters).
        let unit = units[index % units.count]
        index += 1
        if jitter > 0 { usleep(useconds_t(Double.random(in: 0...jitter) * 1_000_000)) }
        let accepted = unit.withUnsafeBufferPointer { decoder.decode($0, time: CACurrentMediaTime()) }
        if !accepted { failures += 1 }
    }
}
