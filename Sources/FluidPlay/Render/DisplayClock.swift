import Foundation
import QuartzCore

/// The display refresh cadence as seen by the display link. The pipeline sets frame deadlines by it
/// so each one hits a separate refresh — a deadline halfway between two display link callbacks
/// is robust to their small fluctuations in either direction.
final class DisplayClock: @unchecked Sendable {
    struct Snapshot {
        /// Time of the last display link callback (`CACurrentMediaTime` clock).
        var anchor: CFTimeInterval
        /// Measured refresh period.
        var period: CFTimeInterval
    }

    private let state = Locked<Snapshot?>(nil)

    /// Called from the display link thread on every refresh.
    func tick(now: CFTimeInterval, nominalHz: Double) {
        let nominalPeriod = 1 / max(24, nominalHz)
        state.with { snapshot in
            guard var value = snapshot, abs(value.period - nominalPeriod) < nominalPeriod * 0.05 else {
                snapshot = Snapshot(anchor: now, period: nominalPeriod)
                return
            }
            let delta = now - value.anchor
            let cycles = (delta / value.period).rounded()
            // The period is measured only from consecutive callbacks; skipped refreshes (e.g. a busy thread)
            // move the anchor without spoiling the measurement.
            if cycles == 1, abs(delta - value.period) < value.period * 0.25 {
                value.period += (delta - value.period) * 0.01
            }
            value.anchor = now
            snapshot = value
        }
    }

    /// The latest state, provided the display link ran within the last 0.5 s.
    func snapshot(now: CFTimeInterval = CACurrentMediaTime()) -> Snapshot? {
        guard let value = state.get(), now - value.anchor < 0.5 else { return nil }
        return value
    }

    func reset() { state.set(nil) }
}
