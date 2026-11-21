import CoreVideo
import Foundation
import QuartzCore

/// Loads a processor in the background (starting a VideoToolbox session takes seconds) and provides it once ready.
/// Used only from the pipeline's worker task.
private final class LazyProcessor<Value> {
    enum State {
        case idle, loading, ready(Value), failed(String)
    }

    private(set) var state: State = .idle
    private var key: String?
    private var box: Locked<Result<Value, Error>?>?

    func resolve(key: String, make: @escaping () async throws -> Value) -> Value? {
        if key != self.key {
            self.key = key
            state = .loading
            let box = Locked<Result<Value, Error>?>(nil)
            self.box = box
            Task.detached(priority: .userInitiated) {
                do {
                    box.set(.success(try await make()))
                } catch {
                    box.set(.failure(error))
                }
            }
            return nil
        }
        if case .ready(let value) = state { return value }
        if case .loading = state, let result = box?.get() {
            box = nil
            switch result {
            case .success(let value):
                state = .ready(value)
                return value
            case .failure(let error):
                state = .failed(error.localizedDescription)
            }
        }
        return nil
    }

    func reset() {
        key = nil
        box = nil
        state = .idle
    }
}

/// Image enhancement pipeline: duplicate detection → frame generation → super resolution → scheduling.
///
/// Frame generation works like resampling: every display refresh gets a frame with content
/// from the right instant — a real one if it happens to fall on it, or one computed between two real ones.
/// This way a game at 24, 30, 40 or 50 fps gives an even 60 fps on a 60 Hz display.
final class FramePipeline {
    struct Config: Equatable {
        var frameGen: FrameGenMode = .auto
        var dedupe = true
        var mlSuperRes = false
        /// Refresh rate of the display showing the image.
        var displayHz: Double = 60
    }

    enum FrameGenState: Equatable {
        case off
        case measuring
        case loading
        /// The source is already so fast that the display won't show extra frames.
        case bypass(sourceFps: Double)
        /// The Mac can't keep up computing frames at this game frame rate (interpolation time in ms).
        case tooSlow(sourceFps: Double, costMs: Double)
        case active(sourceFps: Double)
        case failed(String)
    }

    enum SuperResState: Equatable {
        case off
        case loading
        case active(width: Int, height: Int, scale: Float)
        case unsupported
        case failed(String)
    }

    struct Stats {
        var captureFps = 0.0
        var uniqueFps = 0.0
        var emittedFps = 0.0
        var interpolateMs = 0.0
        var superResMs = 0.0
        var addedLatencyMs = 0.0
        var inputWidth = 0
        var inputHeight = 0
        var contentWidth = 0
        var contentHeight = 0
        var outputWidth = 0
        var outputHeight = 0
        var frameGen: FrameGenState = .off
        var superRes: SuperResState = .off
        var duplicates = 0
        var generated = 0
        var emitted = 0
    }

    /// Receiver of finished frames (called from the worker task).
    var output: ((VideoFrame) -> Void)?
    let config = Locked(Config())
    let stats = Locked(Stats())
    /// Refresh cadence of the display showing the image (set by the pipeline's owner).
    let displayClock = Locked<DisplayClock?>(nil)
    /// Warm-up call times of the most recently loaded interpolator (ms) — for diagnostics.
    let warmupTimes = Locked<[Double]>([])

    /// Saves the measured generation cost (set by the worker task).
    private let saveCost = Locked<(() -> Void)?>(nil)
    private let continuation: AsyncStream<SourceFrame>.Continuation
    private var worker: Task<Void, Never>?
    private let monitor: SessionMonitor?

    // Worker task state.
    private var detector = DuplicateDetector()
    private let interpolatorLoader = LazyProcessor<FrameInterpolator>()
    private let superResLoader = LazyProcessor<SuperResolver>()
    private var previous: CVPixelBuffer?
    private var previousTime: CFTimeInterval = 0
    private var lastUniqueTime: CFTimeInterval?
    private var smoothedInterval: CFTimeInterval?
    private var size = (0, 0)
    private var superResSupported: Bool?
    private var engaged = false
    /// Auto mode decision awaiting confirmation (so game frame rate fluctuations don't toggle the mode).
    private var pendingEngaged: Bool?
    private var pendingSince: CFTimeInterval = 0
    private var interpolationFailures = 0
    private var failedInterpolatorKey: String?
    /// Recent times from capture to frame readiness (non-generating mode).
    private var lagSamples: [CFTimeInterval] = []
    /// Display timeline delay without generation; follows the 90th percentile, not a single spike.
    private var targetLag: CFTimeInterval = 0
    private var lastDue: CFTimeInterval = 0
    private var captureMeter = RateMeter()
    private var uniqueMeter = RateMeter()
    private var emittedMeter = RateMeter()
    private var local = Stats()

    // Resampling onto the refresh grid.
    /// Estimated game instant shown in `previous`. The console streams at 60 fps, so frames of a 40 fps game
    /// arrive alternately 17 and 33 ms apart, although the game renders them evenly every 25 ms — we smooth that out.
    private var contentTime: CFTimeInterval = 0
    /// Deadline of the next refresh waiting for a frame (0 = grid not set up yet).
    private var nextSlot: CFTimeInterval = 0
    /// Interval between a content instant and its on-screen deadline.
    private var displayDelay: CFTimeInterval = 0
    /// Slack of the latest-ready frame of each pair relative to its refresh (recent pairs).
    private var gridSlack: [CFTimeInterval] = []
    /// Timeline shift still to be applied (gradually, so it doesn't jerk).
    private var pendingShift: CFTimeInterval = 0
    private var slotPeriod: CFTimeInterval = 1.0 / 60.0
    /// How many consecutive pairs had no refresh close to a real frame.
    private var pairsWithoutLock = 0
    /// When the display timeline last yielded to late frames.
    private var lastRaise: CFTimeInterval = 0
    /// Average time to compute one intermediate frame (ms). Remembered across sessions so we don't
    /// enable generation "on trial" at a frame rate this Mac can't handle.
    private var frameMs = 0.0
    /// Recent per-frame cost measurements — the median is robust to single spikes.
    private var frameCosts: [Double] = []
    private static func costKey(_ width: Int, _ height: Int) -> String { "frameGenCostMs.\(width)x\(height)" }
    /// How many initial calls of a new interpolator to skip in the cost measurement (model warm-up).
    private var warmupCalls = 0
    private var warmedInterpolator: ObjectIdentifier?
    /// Since when the Mac has been too slow to generate at this game frame rate (0 = it isn't).
    private var tooSlowSince: CFTimeInterval = 0

    /// Margin for processing time fluctuations.
    private let margin: CFTimeInterval = 0.003
    /// Maximum allowed display timeline delay.
    private let maxTargetLag: CFTimeInterval = 0.1
    /// After this many seconds without change we pass a frame through despite similarity (refreshes a static scene).
    private let maxDuplicateHold: CFTimeInterval = 0.25
    /// Interpolation point resolution: 1 = halfway only, 2 = every quarter.
    private let interpolationLevels = ProcessInfo.processInfo.environment["VEYRAMAC_FG_LEVELS"].flatMap(Int.init) ?? 2

    init(monitor: SessionMonitor? = nil) {
        self.monitor = monitor
        // Two slots: with a 30 fps game in a 60 fps stream, a unique frame is followed by its duplicate.
        // With a single slot, a longer generation (a spike >33 ms) ended with the unique frame being
        // overwritten by its duplicate; the pipeline discards duplicates in a fraction of a millisecond, so the backlog doesn't grow.
        let (stream, continuation) = AsyncStream<SourceFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        self.continuation = continuation
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            for await input in stream {
                guard let self else { return }
                await self.process(input)
            }
        }
    }

    deinit { stop() }

    /// Accepts a frame from the source. When the pipeline can't keep up, the oldest pending frame is dropped.
    func submit(_ frame: SourceFrame) {
        if case .dropped = continuation.yield(frame) {
            monitor?.recordPipelineDrop()
        }
    }

    func stop() {
        saveCost.get()?()
        continuation.finish()
        worker?.cancel()
        worker = nil
    }

    // MARK: Processing

    private func process(_ input: SourceFrame) async {
        let cfg = config.get()
        let buffer = input.buffer
        let time = input.time
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        captureMeter.tick()
        monitor?.recordSourceFrame()

        local.contentWidth = input.contentWidth
        local.contentHeight = input.contentHeight

        if size != (width, height) {
            size = (width, height)
            interpolationFailures = 0
            lagSamples.removeAll()
            targetLag = 0
            previous = nil
            lastUniqueTime = nil
            smoothedInterval = nil
            superResSupported = nil
            // The remembered cost is treated as a hint; a nonsensical value (e.g. from an overloaded Mac) is ignored.
            let remembered = UserDefaults.standard.double(forKey: Self.costKey(width, height))
            frameMs = remembered > 0 && remembered < 40 ? remembered : 0
            frameCosts.removeAll()
            resetGrid()
            detector.reset()
        }

        let wantFrameGen = cfg.frameGen != .off && FrameInterpolator.isSupported

        if wantFrameGen, cfg.dedupe {
            if detector.isDuplicate(buffer), let last = lastUniqueTime, time - last < maxDuplicateHold {
                local.duplicates += 1
                monitor?.recordDuplicate()
                if !engaged {
                    // Without generation we show the duplicate anyway: nothing changes to the eye, and a detector
                    // mistake won't freeze small motion on screen.
                    // The content didn't change, so the content instant is still the one from the last new frame.
                    let out = await upscale(buffer, time: time, resolver: nil)
                    emit(out, source: input, captureTime: contentTime > 0 ? contentTime : time,
                         due: bypassDue(time: time, displayHz: cfg.displayHz), generated: false)
                }
                publish(width: width, height: height)
                return
            }
        } else {
            detector.reset()
        }

        var discontinuity = previous == nil
        if let last = lastUniqueTime {
            let delta = time - last
            if delta > 0.004, delta < 0.12 {
                smoothedInterval = smoothedInterval.map { $0 * 0.9 + delta * 0.1 } ?? delta
            } else {
                discontinuity = true
            }
        }
        lastUniqueTime = time
        uniqueMeter.tick()

        // Game instant shown in this frame (phase-locked loop over arrival times).
        let estimated: CFTimeInterval
        if discontinuity || contentTime == 0 {
            estimated = time
        } else {
            let interval = smoothedInterval ?? (time - previousTime)
            let predicted = contentTime + interval
            let error = time - predicted
            estimated = abs(error) > interval ? time : predicted + error * 0.1
        }

        // --- Frame generation
        var frameGenState: FrameGenState = .off
        var interpolator: FrameInterpolator?
        if !wantFrameGen {
            engaged = false
            if cfg.frameGen != .off { frameGenState = .failed(String(localized: "Not supported on this Mac")) }
        } else if let interval = smoothedInterval {
            let sourceFps = 1 / interval
            updateEngaged(mode: cfg.frameGen, sourceFps: sourceFps, displayHz: cfg.displayHz, now: time)
            let key = "\(width)x\(height)"
            if engaged, failedInterpolatorKey == key {
                frameGenState = .failed(String(localized: "The interpolator rejects the size \(String(width))×\(String(height))"))
            } else if engaged {
                let levels = interpolationLevels
                let warmupTimes = self.warmupTimes
                interpolator = interpolatorLoader.resolve(key: key) {
                    let made = try FrameInterpolator(width: width, height: height, levels: levels)
                    // Warm-up in the background — until then the image goes through without generation.
                    warmupTimes.set(await made.warmUp())
                    return made
                }
                if let interpolator {
                    frameGenState = .active(sourceFps: sourceFps)
                    if warmedInterpolator != ObjectIdentifier(interpolator) {
                        warmedInterpolator = ObjectIdentifier(interpolator)
                        // The model is already warmed up; the first real call can still be a bit slower.
                        warmupCalls = 1
                    }
                } else if case .failed(let message) = interpolatorLoader.state {
                    frameGenState = .failed(message)
                } else {
                    frameGenState = .loading
                }
            } else if frameMs > budgetMs(sourceFps: sourceFps, engaged: false) {
                frameGenState = .tooSlow(sourceFps: sourceFps, costMs: frameMs)
                // The cost may have been temporary (e.g. another app was using the GPU) — retry every so often.
                if tooSlowSince == 0 { tooSlowSince = time }
                if time - tooSlowSince > 120 {
                    frameMs = 0
                    frameCosts.removeAll()
                    tooSlowSince = 0
                }
            } else {
                frameGenState = .bypass(sourceFps: sourceFps)
            }
        } else {
            frameGenState = .measuring
        }

        // --- ML super resolution
        var resolver: SuperResolver?
        var superResState: SuperResState = .off
        if cfg.mlSuperRes {
            if superResSupported == nil {
                superResSupported = SuperResolver.bestScale(width: width, height: height) != nil
            }
            if superResSupported == true {
                resolver = superResLoader.resolve(key: "\(width)x\(height)") {
                    try SuperResolver(width: width, height: height)
                }
                if let resolver {
                    superResState = .active(width: resolver.outputWidth, height: resolver.outputHeight, scale: resolver.scale)
                } else if case .failed(let message) = superResLoader.state {
                    superResState = .failed(message)
                } else {
                    superResState = .loading
                }
            } else {
                superResState = .unsupported
            }
        }

        // --- Display scheduling
        var outputSize = (width, height)
        if let interpolator {
            slotPeriod = 1 / max(24, cfg.displayHz)
            let span = estimated - contentTime
            if discontinuity || nextSlot == 0 || previous == nil || span < 0.004 {
                outputSize = await startGrid(buffer, contentAt: estimated, source: input, resolver: resolver)
            } else if let previous {
                outputSize = await resample(previous: previous, current: buffer, from: contentTime, to: estimated,
                                            interpolator: interpolator, resolver: resolver, source: input)
            }
            smooth(&local.addedLatencyMs, (displayDelay + slotPeriod / 2) * 1000)
        } else {
            resetGrid()
            let currentOut = await upscale(buffer, time: time, resolver: resolver)
            updateTargetLag(CACurrentMediaTime() - time)
            let due = bypassDue(time: time, displayHz: cfg.displayHz)
            emit(currentOut, source: input, captureTime: estimated, due: due, generated: false)
            outputSize = (CVPixelBufferGetWidth(currentOut), CVPixelBufferGetHeight(currentOut))
            smooth(&local.addedLatencyMs, ((due > 0 ? due : CACurrentMediaTime()) - time) * 1000)
        }
        monitor?.recordAddedLatency(ms: local.addedLatencyMs)

        previous = buffer
        previousTime = time
        contentTime = estimated
        local.frameGen = frameGenState
        local.superRes = superResState
        local.outputWidth = outputSize.0
        local.outputHeight = outputSize.1
        publish(width: width, height: height)
    }

    /// Time within which the Mac must compute at least one frame per pair so it doesn't fall behind.
    private func budgetMs(sourceFps: Double, engaged: Bool) -> Double {
        1000 / max(sourceFps, 1) * (engaged ? 0.9 : 0.85)
    }

    /// When to generate: when the game doesn't fill the display refresh rate and the Mac can keep up computing
    /// frames at its frame rate. The change takes effect only once the condition holds for a while.
    private func updateEngaged(mode: FrameGenMode, sourceFps: Double, displayHz: Double, now: CFTimeInterval) {
        // Auto leaves the game alone when it falls only slightly short of the full refresh rate (small gain,
        // and every generated frame means minor artifacts); "Max" generates almost always.
        let factor = mode == .always ? (engaged ? 0.97 : 0.93) : (engaged ? 0.9 : 0.85)
        var wanted = sourceFps <= displayHz * factor
        if frameMs > 0, frameMs > budgetMs(sourceFps: sourceFps, engaged: engaged) { wanted = false }
        if wanted { tooSlowSince = 0 }
        guard wanted != engaged else {
            pendingEngaged = nil
            return
        }
        if pendingEngaged != wanted {
            pendingEngaged = wanted
            pendingSince = now
        } else if now - pendingSince >= (wanted ? 1.0 : 2.0) {
            engaged = wanted
            pendingEngaged = nil
            lagSamples.removeAll()
            resetGrid()
            monitor?.recordModeSwitch()
        }
    }

    // MARK: Refresh grid

    private func resetGrid() {
        nextSlot = 0
        pairsWithoutLock = 0
        pendingShift = 0
        gridSlack.removeAll()
    }

    /// The nearest deadline on the grid: halfway between display link callbacks.
    private func snap(_ time: CFTimeInterval) -> CFTimeInterval {
        guard let clock = displayClock.get()?.snapshot() else { return time }
        slotPeriod = clock.period
        let base = clock.anchor - clock.period / 2
        return base + ((time - base) / clock.period).rounded() * clock.period
    }

    /// First frame after a gap: show it on the nearest free refresh.
    private func startGrid(_ buffer: CVPixelBuffer, contentAt: CFTimeInterval, source: SourceFrame,
                           resolver: SuperResolver?) async -> (Int, Int) {
        let out = await upscale(buffer, time: contentAt, resolver: resolver)
        let now = CACurrentMediaTime()
        if displayDelay == 0 { displayDelay = 0.03 }
        var slot = snap(max(contentAt + displayDelay, now + slotPeriod / 2))
        if slot <= lastDue { slot = snap(lastDue + slotPeriod) }
        // This frame's content should match its deadline.
        displayDelay = min(maxTargetLag, max(0.005, slot - contentAt))
        emitOnGrid(out, source: source, contentAt: contentAt, due: slot, generated: false)
        nextSlot = snap(slot + slotPeriod)
        return (CVPixelBufferGetWidth(out), CVPixelBufferGetHeight(out))
    }

    /// Fills the refreshes whose content lies between two game frames.
    private func resample(previous: CVPixelBuffer, current: CVPixelBuffer, from t0: CFTimeInterval, to t1: CFTimeInterval,
                          interpolator: FrameInterpolator, resolver: SuperResolver?, source: SourceFrame) async -> (Int, Int) {
        let span = t1 - t0
        let step = interpolator.phaseStep
        let period = slotPeriod

        // After a stall the grid may have fallen far behind — start from the nearest refresh of this pair.
        if nextSlot - displayDelay < t0 - period {
            nextSlot = snap(max(t0 + displayDelay + period / 2, lastDue + period))
        }

        // Refreshes of this pair and where their content lies between the frames (0 = previous, 1 = current).
        var slots: [(due: CFTimeInterval, phase: Double)] = []
        while slots.count < 6 {
            let phase = (nextSlot - displayDelay - t0) / span
            if phase > 1 + step / 2 { break }
            slots.append((nextSlot, phase))
            nextSlot = snap(nextSlot + period)
        }

        // Frames to compute: only those that can still make their refresh. Each one costs the same
        // (computing several in one call isn't cheaper), so we compute as many as the Mac can manage
        // before the next game frame — those farthest from real frames first. The remaining
        // refreshes get the nearest real frame.
        let now = CACurrentMediaTime()
        let affordable = frameMs > 0 ? max(1, Int(span * 1000 * 0.75 / frameMs)) : 1
        var phases: [Double] = []
        let candidates = slots
            .filter { $0.phase < 1 - step / 2 && $0.due + period / 2 > now }
            .sorted { abs($0.phase - 0.5) < abs($1.phase - 0.5) }
        for slot in candidates where phases.count < affordable {
            let phase = interpolator.quantize(slot.phase)
            if !phases.contains(phase) { phases.append(phase) }
        }
        phases.sort()

        var generated: [Double: CVPixelBuffer] = [:]
        if !phases.isEmpty {
            let started = CACurrentMediaTime()
            do {
                let outputs = try await interpolator.interpolate(
                    previous: previous, previousTime: t0, current: current, currentTime: t1, phases: phases)
                for (phase, buffer) in zip(phases, outputs) { generated[phase] = buffer }
                interpolationFailures = 0
                let elapsed = (CACurrentMediaTime() - started) * 1000
                smooth(&local.interpolateMs, elapsed)
                monitor?.recordInterpolation(ms: elapsed)
                // The first calls after loading the model are several times slower — they don't count toward the cost.
                if warmupCalls > 0 {
                    warmupCalls -= 1
                } else {
                    frameCosts.append(elapsed / Double(phases.count))
                    if frameCosts.count > 31 { frameCosts.removeFirst(frameCosts.count - 31) }
                    if frameCosts.count >= 5 {
                        frameMs = frameCosts.sorted()[frameCosts.count / 2]
                        let cost = frameMs, key = Self.costKey(interpolator.width, interpolator.height)
                        saveCost.set { UserDefaults.standard.set(cost, forKey: key) }
                    }
                }
            } catch {
                // A single error is ignored; a series means the model doesn't support this size.
                interpolationFailures += 1
                if interpolationFailures >= 5 { failedInterpolatorKey = "\(interpolator.width)x\(interpolator.height)" }
            }
        }

        var outputSize = (CVPixelBufferGetWidth(current), CVPixelBufferGetHeight(current))
        var currentOut: CVPixelBuffer?
        var nearest: CFTimeInterval?
        var pairSlack: CFTimeInterval?
        for slot in slots {
            let contentAt = slot.due - displayDelay
            let buffer: CVPixelBuffer
            let isGenerated: Bool
            /// Game instant actually shown in this frame.
            let shown: CFTimeInterval
            let phase = interpolator.quantize(slot.phase)
            if slot.phase < 1 - step / 2, let frame = generated[phase] {
                buffer = await upscale(frame, time: contentAt, resolver: resolver)
                isGenerated = true
                shown = t0 + span * phase
            } else {
                // The refresh falls on the current frame — or the generated one wasn't ready in time, so we show
                // the nearest real one.
                if slot.phase < 0.5 {
                    buffer = await upscale(previous, time: contentAt, resolver: resolver)
                    shown = t0
                } else {
                    if currentOut == nil { currentOut = await upscale(current, time: t1, resolver: resolver) }
                    buffer = currentOut!
                    shown = t1
                }
                isGenerated = false
            }
            emitOnGrid(buffer, source: source, contentAt: shown, due: slot.due, generated: isGenerated)
            outputSize = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
            // The frame is on time if it's queued before the display link callback (half a period after the deadline).
            let slack = slot.due + period / 2 - CACurrentMediaTime()
            pairSlack = min(pairSlack ?? slack, slack)

            for anchor in [t0, t1] {
                let error = contentAt - anchor
                if abs(error) < abs(nearest ?? .infinity) { nearest = error }
            }
        }

        // A refresh close to one of the real frames: nudge the timeline so it hits it
        // exactly — then with a 30 fps game every other on-screen frame is real. The narrow window
        // prevents tugging the timeline between two positions (40 fps: real frames fall
        // alternately on a refresh and between refreshes); a wider one is allowed only when nothing
        // has hit the window for a longer while.
        var lockError: CFTimeInterval?
        if let nearest {
            if abs(nearest) < period * 0.25 {
                lockError = nearest
                pairsWithoutLock = 0
            } else {
                pairsWithoutLock += 1
                if pairsWithoutLock >= 8, abs(nearest) <= period * 0.5 { lockError = nearest }
            }
        }

        // Frames from the model warm-up are slower than usual — they must not shift the timeline permanently.
        if let slack = pairSlack, warmupCalls == 0 { gridSlack.append(slack) }
        if gridSlack.count > 60 { gridSlack.removeFirst(gridSlack.count - 60) }
        updateDisplayDelay(lockError: lockError)
        return outputSize
    }

    /// Image delay driven by slack: how far ahead of the display link callback the frames were ready.
    /// Slack (rather than content-to-ready time) doesn't depend on the delay itself, so the control loop
    /// doesn't run away. With a game at a steady cadence (30 fps) the timeline holds the position where real
    /// frames hit refreshes, and shifts by a whole refresh when frames are late or there's
    /// more slack than one refresh. Every change is applied gradually — a jump would be a hitch.
    private func updateDisplayDelay(lockError: CFTimeInterval?) {
        let period = slotPeriod
        if pendingShift != 0 {
            let step = pendingShift > 0 ? min(pendingShift, 0.0015) : max(pendingShift, -0.0005)
            displayDelay += step
            pendingShift -= step
            if abs(pendingShift) < 0.0001 { pendingShift = 0 }
            return
        }
        if let lockError {
            displayDelay += max(-0.0005, min(0.0005, lockError * 0.3))
        }
        // Decide on a shift only after collecting samples at the current position.
        guard gridSlack.count >= 20 else { return }
        let sorted = gridSlack.sorted()
        let locked = lockError != nil
        let now = CACurrentMediaTime()
        var shift: CFTimeInterval = 0
        // A late frame is a visible hitch. Previously the timeline yielded only when 5% of pairs
        // were late (at 30 fps as many as one and a half frames per second) — now already at the second
        // late one in the window (about 2 s).
        if sorted[1] < 0 {
            shift = locked ? period : min(-sorted[1] + margin, period)
            lastRaise = now
        } else if gridSlack.count >= 60, now - lastRaise > 10 {
            // Down only when even the worst pair would have had slack throughout the window, and not right
            // after a raise — otherwise the timeline would oscillate between two positions.
            let worst = sorted[0]
            if locked, worst > period + margin {
                shift = -period
            } else if !locked, worst > margin * 2 {
                shift = -min(worst - margin * 2, 0.002)
            }
        }
        if shift != 0 {
            let limited = min(maxTargetLag + period, max(0.005, displayDelay + shift))
            pendingShift = limited - displayDelay
            gridSlack.removeAll()
        }
    }

    private func emitOnGrid(_ buffer: CVPixelBuffer, source: SourceFrame, contentAt: CFTimeInterval,
                            due: CFTimeInterval, generated: Bool) {
        let value = max(due, lastDue + 0.0005)
        lastDue = value
        emit(buffer, source: source, captureTime: contentAt, due: value, generated: generated, onGrid: true)
    }

    // MARK: Without generation

    /// Display deadline without frame generation. Frames from the network arrive at a cadence independent of
    /// the display refresh; shown immediately they would collide (two in one refresh = one
    /// is lost). A small buffer (90th percentile of the delay) lets them be shown one after another, one per
    /// refresh. A source faster than the display is shown immediately (the newest frame wins).
    private func bypassDue(time: CFTimeInterval, displayHz: Double) -> CFTimeInterval {
        let sourceFps = smoothedInterval.map { 1 / $0 } ?? 60
        guard sourceFps <= displayHz * 1.2, targetLag > 0 else {
            lastDue = 0
            return 0
        }
        return monotonic(time + targetLag)
    }

    private func updateTargetLag(_ lag: CFTimeInterval) {
        lagSamples.append(lag)
        if lagSamples.count > 120 { lagSamples.removeFirst(lagSamples.count - 120) }
        let sorted = lagSamples.sorted()
        // Upper bound: on an overloaded Mac it's better to show a single frame too late than
        // to delay the whole image (without it the delay could grow to half a second).
        let goal = min(maxTargetLag, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))] + margin)
        if targetLag == 0 {
            targetLag = goal
        } else if goal > targetLag {
            targetLag = min(goal, targetLag + 0.002)
        } else {
            targetLag = max(goal, targetLag - 0.0005)
        }
    }

    private func upscale(_ buffer: CVPixelBuffer, time: CFTimeInterval, resolver: SuperResolver?) async -> CVPixelBuffer {
        guard let resolver else { return buffer }
        let started = CACurrentMediaTime()
        guard let result = try? await resolver.upscale(buffer, time: time) else { return buffer }
        smooth(&local.superResMs, (CACurrentMediaTime() - started) * 1000)
        return result
    }

    private func monotonic(_ due: CFTimeInterval) -> CFTimeInterval {
        let value = max(due, lastDue + 0.0005)
        lastDue = value
        return value
    }

    private func emit(_ buffer: CVPixelBuffer, source: SourceFrame, captureTime: CFTimeInterval, due: CFTimeInterval,
                      generated: Bool, onGrid: Bool = false) {
        // On the grid a frame is on time if it's ready before the display link callback (half a period after the deadline).
        let deadline = onGrid ? due + slotPeriod / 2 : due
        if due > 0, deadline < CACurrentMediaTime() { monitor?.recordLate() }
        local.emitted += 1
        if generated { local.generated += 1 }
        emittedMeter.tick()
        // Super resolution scales the whole canvas, so the image area grows in the same proportion.
        let inputWidth = CVPixelBufferGetWidth(source.buffer)
        let inputHeight = CVPixelBufferGetHeight(source.buffer)
        let outputWidth = CVPixelBufferGetWidth(buffer)
        let outputHeight = CVPixelBufferGetHeight(buffer)
        let contentWidth = min(outputWidth, source.contentWidth * outputWidth / max(inputWidth, 1))
        let contentHeight = min(outputHeight, source.contentHeight * outputHeight / max(inputHeight, 1))
        output?(VideoFrame(pixelBuffer: buffer, contentWidth: contentWidth, contentHeight: contentHeight,
                           captureTime: captureTime, dueTime: due, isGenerated: generated, onDisplayGrid: onGrid))
    }

    private func smooth(_ value: inout Double, _ sample: Double) {
        value = value == 0 ? sample : value * 0.9 + sample * 0.1
    }

    private func publish(width: Int, height: Int) {
        local.captureFps = captureMeter.value()
        local.uniqueFps = uniqueMeter.value()
        local.emittedFps = emittedMeter.value()
        local.inputWidth = width
        local.inputHeight = height
        stats.set(local)
    }
}
