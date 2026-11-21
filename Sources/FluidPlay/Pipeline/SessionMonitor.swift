import Foundation
import QuartzCore

/// Collects events along the whole image path (network → decoder → pipeline → display) so it's clear
/// where each hitch comes from. The `record…` methods are thread-safe and cheap.
final class SessionMonitor: @unchecked Sendable {
    /// Counters for one second.
    struct Second {
        // Network (built-in Remote Play)
        var networkFrames = 0
        var networkBytes = 0
        var framesLost = 0
        var framesRecovered = 0
        /// Longest gap between frames from the network (ms).
        var maxNetworkGapMs = 0.0
        /// Gaps longer than 2.5 stream periods.
        var networkStalls = 0
        // Decoder
        var decodeErrors = 0
        var keyframeRequests = 0
        var maxDecodeMs = 0.0
        // Pipeline
        /// Frames that came from the source (including duplicates).
        var sourceFrames = 0
        var pipelineDropped = 0
        var duplicates = 0
        var interpolations = 0
        var interpolateTotalMs = 0.0
        var maxInterpolateMs = 0.0
        var late = 0
        var modeSwitches = 0
        /// Image latency added by the pipeline at the end of the second (ms).
        var addedLatencyMs = 0.0
        // Display
        var refreshesWithNewFrame = 0
        /// Gaps between new frames on screen, in refreshes: [1, 2, 3+].
        var presentGaps = [0, 0, 0]
    }

    /// Whole-session summary for the on-screen stats.
    struct Summary: Equatable {
        var seconds = 0
        var hitches = 0
        var hitchesNetwork = 0
        var hitchesMac = 0
        var hitchesSource = 0
        var smoothness = 100.0
        /// Video bitrate over the last second (Mbps); 0 when the source isn't a network stream.
        var streamMbps = 0.0
    }

    private let lock = NSLock()
    private var current = Second()
    private var lastNetworkArrival: CFTimeInterval = 0
    private var summary = Summary()
    private var smoothSum = 0.0
    private var smoothCount = 0
    private let logHandle: FileHandle?
    let logURL: URL?

    init(title: String, log: Bool = true) {
        if log, let url = Self.makeLogURL() {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            logURL = url
        } else {
            logHandle = nil
            logURL = nil
        }
        write("# FluidPlay — session: \(title)")
        write("# t  | network: frames lost recovered maxGap[ms] stalls Mbps | decoder: errors IDR max[ms] | pipeline: dropped dup interp avg/max[ms] late switches latency[ms] | display: new gaps1/2/3+ | score")
    }

    deinit {
        try? logHandle?.close()
    }

    private static func makeLogURL() -> URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let directory = library.appendingPathComponent("Logs/FluidPlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return directory.appendingPathComponent("session_\(formatter.string(from: Date())).log")
    }

    // MARK: Events

    func recordNetworkFrame(framesLost: Int, recovered: Bool, bytes: Int = 0, expectedInterval: CFTimeInterval) {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        current.networkFrames += 1
        current.networkBytes += bytes
        current.framesLost += framesLost
        if recovered { current.framesRecovered += 1 }
        if lastNetworkArrival > 0 {
            let gap = now - lastNetworkArrival
            current.maxNetworkGapMs = max(current.maxNetworkGapMs, gap * 1000)
            if gap > expectedInterval * 2.5 { current.networkStalls += 1 }
        }
        lastNetworkArrival = now
    }

    func recordDecode(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        current.maxDecodeMs = max(current.maxDecodeMs, ms)
    }

    func recordDecodeError() {
        lock.lock(); defer { lock.unlock() }
        current.decodeErrors += 1
    }

    func recordKeyframeRequest() {
        lock.lock(); defer { lock.unlock() }
        current.keyframeRequests += 1
    }

    func recordSourceFrame() {
        lock.lock(); defer { lock.unlock() }
        current.sourceFrames += 1
    }

    func recordPipelineDrop() {
        lock.lock(); defer { lock.unlock() }
        current.pipelineDropped += 1
    }

    func recordDuplicate() {
        lock.lock(); defer { lock.unlock() }
        current.duplicates += 1
    }

    func recordInterpolation(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        current.interpolations += 1
        current.interpolateTotalMs += ms
        current.maxInterpolateMs = max(current.maxInterpolateMs, ms)
    }

    func recordLate() {
        lock.lock(); defer { lock.unlock() }
        current.late += 1
    }

    func recordModeSwitch() {
        lock.lock(); defer { lock.unlock() }
        current.modeSwitches += 1
    }

    func recordAddedLatency(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        current.addedLatencyMs = ms
    }

    /// A new frame reached the screen `gap` refreshes after the previous one.
    func recordPresent(gap: Int) {
        lock.lock(); defer { lock.unlock() }
        current.refreshesWithNewFrame += 1
        current.presentGaps[min(max(gap, 1), 3) - 1] += 1
    }

    // MARK: Every second

    /// Closes the current second: scores hitches, appends a line to the log and returns the summary.
    /// `targetFps` is the frame rate the display should show (e.g. 60 when generating 30 → 60).
    @discardableResult
    func rollSecond(targetFps: Double, displayHz: Double, visible: Bool = true) -> Summary {
        lock.lock()
        let second = current
        current = Second()
        lock.unlock()

        let mbps = Double(second.networkBytes) * 8 / 1_000_000
        let network = String(format: "%3d %2d %2d %5.0f %2d %5.1f", second.networkFrames, second.framesLost,
                             second.framesRecovered, second.maxNetworkGapMs, second.networkStalls, mbps)
        // Occluded window: the system doesn't draw, so these aren't hitches. Static image (menu, loading,
        // pause): the console sends repeats of the same frame, so there's nothing new to show on screen.
        // Both kinds of seconds are only logged, without a smoothness score.
        let unique = second.sourceFrames - second.duplicates
        // The duplicate condition tells a static image from a network stall (then there are few frames, but each is new).
        let still = second.sourceFrames > 0 && unique < 12 && second.duplicates * 2 >= second.sourceFrames
        guard visible, !still else {
            lock.lock()
            summary.seconds += 1
            summary.streamMbps = mbps
            let result = summary
            lock.unlock()
            write(String(format: "%4d | %@ | %@", result.seconds, network,
                         visible ? "static image (\(unique) new frames)" : "window hidden"))
            return result
        }

        // Hitch = a gap between new frames longer than expected. At 60 fps on 60 Hz
        // the expected gap is 1 refresh; at 30 fps without generation — 2.
        let expectedGap = max(1, Int((displayHz / max(targetFps, 1)).rounded()))
        var hitches = 0
        if expectedGap == 1 {
            hitches = second.presentGaps[1] + second.presentGaps[2]
        } else if expectedGap == 2 {
            hitches = second.presentGaps[2]
        }
        let presented = second.refreshesWithNewFrame
        let smoothness = targetFps > 0 ? min(100, Double(presented) / targetFps * 100) : 100

        lock.lock()
        summary.seconds += 1
        if hitches > 0 {
            summary.hitches += hitches
            // Cause: network, if there were losses or stalls in this second; Mac, if the pipeline couldn't
            // keep up; otherwise the source (the game slowed down or the console sent fewer frames).
            if second.framesLost > 0 || second.networkStalls > 0 || second.framesRecovered > 0 || second.decodeErrors > 0 {
                summary.hitchesNetwork += hitches
            } else if second.late > 0 || second.pipelineDropped > 0 || second.modeSwitches > 0 {
                summary.hitchesMac += hitches
            } else {
                summary.hitchesSource += hitches
            }
        }
        smoothSum += smoothness
        smoothCount += 1
        summary.smoothness = smoothSum / Double(smoothCount)
        summary.streamMbps = mbps
        let result = summary
        lock.unlock()

        let interpAvg = second.interpolations > 0 ? second.interpolateTotalMs / Double(second.interpolations) : 0
        write(String(format: "%4d | %@ | %2d %2d %4.1f | %2d %3d %4.1f/%4.1f %2d %d %3.0f | %3d %3d/%d/%d | %.0f%%%@",
                     result.seconds, network,
                     second.decodeErrors, second.keyframeRequests, second.maxDecodeMs,
                     second.pipelineDropped, second.duplicates, interpAvg, second.maxInterpolateMs, second.late, second.modeSwitches,
                     second.addedLatencyMs,
                     second.refreshesWithNewFrame, second.presentGaps[0], second.presentGaps[1], second.presentGaps[2],
                     smoothness, hitches > 0 ? "  ← hitches: \(hitches)" : ""))
        return result
    }

    func finish() {
        lock.lock()
        let result = summary
        lock.unlock()
        write(String(format: "# End: %d s, smoothness %.1f%%, hitches %d (network %d, Mac %d, source %d)",
                     result.seconds, result.smoothness, result.hitches, result.hitchesNetwork, result.hitchesMac, result.hitchesSource))
    }

    private func write(_ line: String) {
        guard let logHandle, let data = (line + "\n").data(using: .utf8) else { return }
        try? logHandle.write(contentsOf: data)
    }
}
