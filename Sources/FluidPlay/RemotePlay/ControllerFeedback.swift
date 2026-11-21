// SPDX-License-Identifier: AGPL-3.0-only

import CoreHaptics
import Foundation
import GameController
import QuartzCore

/// Everything the console sends to the controller: vibration (DualSense haptics or simple DualShock 4 rumble),
/// adaptive triggers, light bar color and player number.
final class ControllerFeedback {
    struct Settings: Equatable {
        /// 0 = off, 1 = normal, 2 = strong.
        var vibration: Float = 1
        var adaptiveTriggers = true
    }

    let settings = Locked(Settings())

    private let queue = DispatchQueue(label: "fluidplay.feedback", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // State owned by `queue`.
    private weak var controller: GCController?
    private var motors: [Motor] = []
    private var rumble: (left: Float, right: Float) = (0, 0)
    private var hapticSum: (left: Float, right: Float) = (0, 0)
    private var hapticCount = 0
    private var haptic: (left: Float, right: Float) = (0, 0)
    private var lastHapticPacket: CFTimeInterval = 0

    // Main thread state.
    private var triggerEffects: (left: (UInt8, [UInt8]), right: (UInt8, [UInt8]))?
    private var lightColor: (Float, Float, Float)?
    private var playerIndex: Int?
    private weak var styledController: GCController?

    /// DualSense haptics is an audio-like signal; its average amplitude is small,
    /// so we amplify it to match the strength of regular rumble.
    private let hapticGain: Float = 4

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.updateMotors() }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
    }

    // MARK: Input from the session (any thread)

    /// The controller currently in use. Called on every controller change.
    func bind(_ controller: GCController?) {
        queue.async { [weak self] in
            guard let self, self.controller !== controller else { return }
            self.motors.forEach { $0.stop() }
            self.motors = []
            self.controller = controller
            if let controller { self.motors = Motor.make(for: controller) }
        }
        DispatchQueue.main.async { [weak self] in self?.restyle(controller) }
    }

    /// Simple DualShock 4 rumble (strength 0…255).
    func setRumble(left: UInt8, right: UInt8) {
        queue.async { [weak self] in
            self?.rumble = (Float(left) / 255, Float(right) / 255)
        }
    }

    /// DualSense haptics packet (10 ms): average amplitude of the left and right side, 0…1.
    func pushHaptics(left: Float, right: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.hapticSum.left += left
            self.hapticSum.right += right
            self.hapticCount += 1
            self.lastHapticPacket = CACurrentMediaTime()
        }
    }

    func setTriggerEffects(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.triggerEffects = ((typeLeft, left), (typeRight, right))
            self.applyTriggers()
        }
    }

    func setLight(red: UInt8, green: UInt8, blue: UInt8) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lightColor = (Float(red) / 255, Float(green) / 255, Float(blue) / 255)
            self.applyLight()
        }
    }

    func setPlayerIndex(_ index: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playerIndex = index
            self.applyPlayerIndex()
        }
    }

    /// Settings changed during play (vibration strength, triggers).
    func settingsChanged() {
        DispatchQueue.main.async { [weak self] in self?.applyTriggers() }
    }

    /// End of session: turns off vibration and triggers, releases the haptic engines.
    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            motors.forEach { $0.stop() }
            motors = []
            controller = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let gamepad = self.styledController?.extendedGamepad as? GCDualSenseGamepad else { return }
            gamepad.leftTrigger.setModeOff()
            gamepad.rightTrigger.setModeOff()
            self.styledController?.playerIndex = .indexUnset
        }
    }

    // MARK: Vibration (`queue`, 100 times per second)

    private func updateMotors() {
        let strength = settings.get().vibration
        if hapticCount > 0 {
            haptic = (hapticSum.left / Float(hapticCount), hapticSum.right / Float(hapticCount))
            hapticSum = (0, 0)
            hapticCount = 0
        } else if CACurrentMediaTime() - lastHapticPacket > 0.05 {
            haptic = (0, 0)
        }
        guard !motors.isEmpty else { return }
        let left = min(1, max(rumble.left, haptic.left * hapticGain) * strength)
        let right = min(1, max(rumble.right, haptic.right * hapticGain) * strength)
        if motors.count == 1 {
            motors[0].set(max(left, right))
        } else {
            motors[0].set(left)
            motors[1].set(right)
        }
    }

    // MARK: Triggers, light bar, player number (main thread)

    private func restyle(_ controller: GCController?) {
        styledController = controller
        applyTriggers()
        applyLight()
        applyPlayerIndex()
    }

    private func applyLight() {
        guard let lightColor, let light = styledController?.light else { return }
        light.color = GCColor(red: lightColor.0, green: lightColor.1, blue: lightColor.2)
    }

    private func applyPlayerIndex() {
        guard let playerIndex, let controller = styledController else { return }
        controller.playerIndex = GCControllerPlayerIndex(rawValue: playerIndex - 1) ?? .indexUnset
    }

    private func applyTriggers() {
        guard let gamepad = styledController?.extendedGamepad as? GCDualSenseGamepad else { return }
        guard settings.get().adaptiveTriggers, let effects = triggerEffects else {
            gamepad.leftTrigger.setModeOff()
            gamepad.rightTrigger.setModeOff()
            return
        }
        TriggerEffect.apply(type: effects.left.0, data: effects.left.1, to: gamepad.leftTrigger)
        TriggerEffect.apply(type: effects.right.0, data: effects.right.1, to: gamepad.rightTrigger)
    }
}

// MARK: Haptic engine for one side of the controller

/// Continuous vibration of variable strength on one area of the controller (left or right grip).
///
/// A regular player (`makePlayer`) with on-the-fly intensity changes, as in Moonlight. The advanced player
/// (`makeAdvancedPlayer`) on macOS 27 breaks the connection to `gamecontrollerd` — the daemon rejects its
/// pattern ("unexpected class 'AVHapticEvent'") and the controller stops vibrating.
private final class Motor {
    private let engine: CHHapticEngine
    private let sharpness: Float
    private var player: CHHapticPatternPlayer?
    private var current: Float = 0
    private var retryAfter: CFTimeInterval = 0

    private init(engine: CHHapticEngine, sharpness: Float) {
        self.engine = engine
        self.sharpness = sharpness
        engine.isAutoShutdownEnabled = false
        engine.stoppedHandler = { [weak self] _ in
            self?.player = nil
            self?.current = 0
        }
        engine.resetHandler = { [weak self] in
            guard let self else { return }
            self.player = nil
            self.current = 0
            try? self.engine.start()
        }
    }

    /// Left and right grips if the controller distinguishes them; otherwise one engine for the whole controller.
    static func make(for controller: GCController) -> [Motor] {
        guard let haptics = controller.haptics else { return [] }
        let localities = haptics.supportedLocalities
        // Left side: low frequency (strong "rumble"), right: high (fine buzz).
        if localities.contains(.leftHandle), localities.contains(.rightHandle),
           let left = Motor.start(haptics, .leftHandle, sharpness: 0.3),
           let right = Motor.start(haptics, .rightHandle, sharpness: 0.8) {
            return [left, right]
        }
        if let single = Motor.start(haptics, .default, sharpness: 0.5) {
            return [single]
        }
        return []
    }

    private static func start(_ haptics: GCDeviceHaptics, _ locality: GCHapticsLocality, sharpness: Float) -> Motor? {
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        let motor = Motor(engine: engine, sharpness: sharpness)
        do {
            try engine.start()
        } catch {
            return nil
        }
        return motor
    }

    func set(_ intensity: Float) {
        guard CACurrentMediaTime() >= retryAfter else { return }
        let target = intensity < 0.02 ? 0 : intensity
        guard abs(target - current) > 0.02 || (target == 0) != (current == 0) else { return }
        current = target
        do {
            if target == 0 {
                try player?.stop(atTime: CHHapticTimeImmediate)
                player = nil
                return
            }
            if player == nil {
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ], relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                self.player = player
            }
            try player?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: target, relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
        } catch {
            // The engine may have stopped (e.g. the controller disconnected): restart it and try
            // again no sooner than in a second.
            player = nil
            current = 0
            try? engine.start()
            retryAfter = CACurrentMediaTime() + 1
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine.stop()
    }
}

// MARK: Adaptive trigger effects

/// Translates a trigger effect in DualSense format (type + 10 bytes, as sent by the console) to the
/// GameController API. Zones are 10 equal segments of the trigger travel.
enum TriggerEffect {
    static func apply(type: UInt8, data: [UInt8], to trigger: GCDualSenseAdaptiveTrigger) {
        guard data.count >= 10 else { return }
        func u16(_ i: Int) -> UInt32 { UInt32(data[i]) | UInt32(data[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { u16(i) | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24 }
        func byte(_ i: Int) -> Float { Float(data[i]) / 255 }

        switch type {
        case 0x01: // Simple resistance from a position.
            trigger.setModeFeedbackWithStartPosition(byte(0), resistiveStrength: byte(1))
        case 0x02: // Simple "weapon trigger": resistance between positions, then a snap.
            trigger.setModeWeaponWithStartPosition(byte(0), endPosition: max(byte(0), byte(1)), resistiveStrength: byte(2))
        case 0x06: // Simple vibration: frequency, amplitude, position.
            trigger.setModeVibrationWithStartPosition(byte(2), amplitude: byte(1), frequency: byte(0))
        case 0x21: // Zoned resistance: zone mask + strength (3 bits per zone).
            let zones = u16(0)
            let forces = u32(2)
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            withUnsafeMutableBytes(of: &strengths.values) { raw in
                let values = raw.bindMemory(to: Float.self)
                for zone in 0..<10 where zones & (1 << zone) != 0 {
                    values[zone] = Float(((forces >> (3 * UInt32(zone))) & 7) + 1) / 8
                }
            }
            trigger.setModeFeedback(resistiveStrengths: strengths)
        case 0x22, 0x25: // Bow and weapon: start and end zone + strength.
            let zones = u16(0)
            guard zones != 0 else { trigger.setModeOff(); return }
            let start = zones.trailingZeroBitCount
            let end = 31 - zones.leadingZeroBitCount
            let strength = Float((data[2] & 7) + 1) / 8
            trigger.setModeWeaponWithStartPosition(Float(start) / 9, endPosition: Float(max(start, end)) / 9, resistiveStrength: strength)
        case 0x26: // Zoned vibration: mask + amplitude (3 bits per zone) + frequency.
            let zones = u16(0)
            let amplitudes = u32(2)
            var positional = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
            withUnsafeMutableBytes(of: &positional.values) { raw in
                let values = raw.bindMemory(to: Float.self)
                for zone in 0..<10 where zones & (1 << zone) != 0 {
                    values[zone] = Float(((amplitudes >> (3 * UInt32(zone))) & 7) + 1) / 8
                }
            }
            trigger.setModeVibration(amplitudes: positional, frequency: byte(8))
        case 0x23, 0x27: // Galloping and "machine": vibration over a zone range.
            let zones = u16(0)
            guard zones != 0 else { trigger.setModeOff(); return }
            let start = zones.trailingZeroBitCount
            trigger.setModeVibrationWithStartPosition(Float(start) / 9, amplitude: 0.6, frequency: byte(type == 0x23 ? 3 : 4))
        default: // 0x00, 0x05 and unknown: no effect.
            trigger.setModeOff()
        }
    }
}
