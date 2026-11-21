import Foundation
import QuartzCore

/// Queue of frames waiting for their display moment. Thread-safe.
final class PresentQueue: @unchecked Sendable {
    /// Refresh cadence of the active view — the pipeline sets frame deadlines by it.
    let clock = DisplayClock()

    private var frames: [VideoFrame] = []
    private let lock = NSLock()
    private let capacity = 12

    func push(_ frame: VideoFrame) {
        lock.lock(); defer { lock.unlock() }
        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    /// Returns the frame to show at the current display refresh, or `nil` when nothing new is ready.
    ///
    /// - Frames without a deadline (`dueTime == 0`) are shown immediately: the newest wins, older ones are dropped.
    /// - Frames on the refresh grid (`onDisplayGrid`) have one deadline per refresh, so
    ///   the newest due one wins — a late frame is dropped instead of shifting all the following ones.
    /// - Other frames with a deadline are shown in order, one per refresh. The source and display
    ///   clocks aren't synchronized, so at times two frames become due at once — the second then waits
    ///   one refresh instead of being dropped. Only a backlog of more than two frames is discarded.
    func pop(now: CFTimeInterval) -> VideoFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let lastDue = frames.lastIndex(where: { $0.dueTime <= now }) else { return nil }
        if frames[lastDue].dueTime == 0 || frames[lastDue].onDisplayGrid {
            let frame = frames[lastDue]
            frames.removeFirst(lastDue + 1)
            return frame
        }
        let dueCount = lastDue + 1
        if dueCount > 2 {
            frames.removeFirst(dueCount - 2)
        }
        return frames.removeFirst()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
    }
}
