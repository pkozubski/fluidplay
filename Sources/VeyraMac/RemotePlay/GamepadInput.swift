// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GameController
import QuartzCore

/// Reads controllers (DualSense, DualShock, Xbox…) via GameController and passes their state to the session.
final class GamepadInput {
    /// Called on every controller state change (from the polling queue).
    var onState: ((VRPController) -> Void)?
    /// Called when the controller in use changes (also to `nil` after a disconnect).
    var onController: ((GCController?) -> Void)?
    /// Buttons pressed from the app (in-game bar) — added to the real controller's state.
    let virtualButtons = Locked<UInt32>(0)

    private let queue = DispatchQueue(label: "veyramac.gamepad", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var last = VRPController()
    private var preparedController: ObjectIdentifier?
    /// Controller with motion sensors enabled — we turn them off when the session ends.
    private weak var motionController: GCController?
    private var boundController: ObjectIdentifier?
    private var hadController = false

    // Trigger resending: the console receives triggers as events without acknowledgment. When a trigger
    // stays still there are no new events, so a packet lost over Wi‑Fi would leave the console with a
    // stale value (e.g. a released brake). For a short while after every change we send the value
    // alternating with its neighbour (±1 out of 255 — imperceptible), so it reaches the console many times.
    private var lastRawTriggers: (UInt8, UInt8) = (0, 0)
    private var refreshUntil: (CFTimeInterval, CFTimeInterval) = (0, 0)
    private var nudgePhase = false
    private var lastNudge: CFTimeInterval = 0
    private let refreshWindow: CFTimeInterval = 0.4
    private let nudgeInterval: CFTimeInterval = 0.035

    /// Name of the connected controller, or `nil`.
    static var connectedName: String? {
        (GCController.current ?? GCController.controllers().first)?.vendorName
    }

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            if let motion = motionController?.motion, motion.sensorsRequireManualActivation {
                motion.sensorsActive = false
            }
            motionController = nil
            preparedController = nil
        }
    }

    private func poll() {
        guard let controller = GCController.current ?? GCController.controllers().first,
              let pad = controller.extendedGamepad
        else {
            if hadController {
                hadController = false
                boundController = nil
                onController?(nil)
            }
            var idle = VRPController()
            idle.buttons = virtualButtons.get()
            send(idle)
            return
        }
        prepare(controller)
        let identifier = ObjectIdentifier(controller)
        if boundController != identifier {
            boundController = identifier
            hadController = true
            onController?(controller)
        }

        var state = VRPController()
        var buttons: Int32 = 0
        func set(_ button: GCControllerButtonInput?, _ flag: Int) {
            if button?.isPressed == true { buttons |= Int32(flag) }
        }
        set(pad.buttonA, VRP_BUTTON_CROSS)
        set(pad.buttonB, VRP_BUTTON_CIRCLE)
        set(pad.buttonX, VRP_BUTTON_SQUARE)
        set(pad.buttonY, VRP_BUTTON_TRIANGLE)
        set(pad.dpad.left, VRP_BUTTON_DPAD_LEFT)
        set(pad.dpad.right, VRP_BUTTON_DPAD_RIGHT)
        set(pad.dpad.up, VRP_BUTTON_DPAD_UP)
        set(pad.dpad.down, VRP_BUTTON_DPAD_DOWN)
        set(pad.leftShoulder, VRP_BUTTON_L1)
        set(pad.rightShoulder, VRP_BUTTON_R1)
        set(pad.leftThumbstickButton, VRP_BUTTON_L3)
        set(pad.rightThumbstickButton, VRP_BUTTON_R3)
        set(pad.buttonMenu, VRP_BUTTON_OPTIONS)
        set(pad.buttonOptions, VRP_BUTTON_SHARE)
        set(pad.buttonHome, VRP_BUTTON_PS)

        state.l2 = UInt8(max(0, min(1, pad.leftTrigger.value)) * 255)
        state.r2 = UInt8(max(0, min(1, pad.rightTrigger.value)) * 255)
        // GameController: the Y axis grows upward; PS protocol: downward.
        state.left_x = Self.axis(pad.leftThumbstick.xAxis.value)
        state.left_y = Self.axis(-pad.leftThumbstick.yAxis.value)
        state.right_x = Self.axis(pad.rightThumbstick.xAxis.value)
        state.right_y = Self.axis(-pad.rightThumbstick.yAxis.value)

        var primary: GCControllerDirectionPad?
        var secondary: GCControllerDirectionPad?
        if let dualSense = pad as? GCDualSenseGamepad {
            set(dualSense.touchpadButton, VRP_BUTTON_TOUCHPAD)
            primary = dualSense.touchpadPrimary
            secondary = dualSense.touchpadSecondary
        } else if let dualShock = pad as? GCDualShockGamepad {
            set(dualShock.touchpadButton, VRP_BUTTON_TOUCHPAD)
            primary = dualShock.touchpadPrimary
            secondary = dualShock.touchpadSecondary
        }
        state.touch.0 = Self.touch(primary)
        state.touch.1 = Self.touch(secondary)
        state.buttons = UInt32(bitPattern: buttons) | virtualButtons.get()
        readMotion(controller, into: &state)
        refreshTriggers(&state)
        send(state)
    }

    /// Gyroscope and accelerometer (motion aiming, gestures). GameController reports them in different axes than
    /// SDL, which chiaki-ng uses — we convert the same way as SDL's Apple driver:
    /// gyro (x, z, −y), accelerometer with inverted signs.
    private func readMotion(_ controller: GCController, into state: inout VRPController) {
        guard let motion = controller.motion, motion.sensorsActive || !motion.sensorsRequireManualActivation,
              motion.hasRotationRate
        else { return }
        let rate = motion.rotationRate
        let accel = motion.acceleration
        state.motion = true
        state.gyro = (Float(rate.x), Float(rate.z), Float(-rate.y))
        state.accel = (Float(-accel.x), Float(-accel.y), Float(-accel.z))
        state.motion_timestamp_us = UInt32(truncatingIfNeeded: UInt64(CACurrentMediaTime() * 1_000_000))
    }

    private func refreshTriggers(_ state: inout VRPController) {
        let now = CACurrentMediaTime()
        if state.l2 != lastRawTriggers.0 {
            lastRawTriggers.0 = state.l2
            refreshUntil.0 = now + refreshWindow
        }
        if state.r2 != lastRawTriggers.1 {
            lastRawTriggers.1 = state.r2
            refreshUntil.1 = now + refreshWindow
        }
        if now - lastNudge >= nudgeInterval {
            lastNudge = now
            nudgePhase.toggle()
        }
        guard nudgePhase else { return }
        if now < refreshUntil.0 { state.l2 = Self.neighbour(state.l2) }
        if now < refreshUntil.1 { state.r2 = Self.neighbour(state.r2) }
    }

    private static func neighbour(_ value: UInt8) -> UInt8 {
        value == 0 ? 1 : value - 1
    }

    /// Disables the controller's system gestures (PS button opening Launchpad, Share taking a screenshot)
    /// so the buttons reach the game.
    private func prepare(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        guard preparedController != identifier else { return }
        preparedController = identifier
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }
        // DualSense enables motion sensors only on request (saves battery).
        if let motion = controller.motion, motion.sensorsRequireManualActivation {
            motion.sensorsActive = true
        }
        motionController = controller
    }

    private func send(_ state: VRPController) {
        var current = state
        var previous = last
        let changed = withUnsafeBytes(of: &current) { a in
            withUnsafeBytes(of: &previous) { b in !a.elementsEqual(b) }
        }
        guard changed else { return }
        last = state
        onState?(state)
    }

    private static func axis(_ value: Float) -> Int16 {
        Int16(max(-1, min(1, value)) * 32767)
    }

    /// The touchpad reports (0, 0) when nobody is touching it; the range is −1…1 with the Y axis up.
    private static func touch(_ pad: GCControllerDirectionPad?) -> VRPTouch {
        guard let pad else { return VRPTouch(active: false, x: 0, y: 0) }
        let x = pad.xAxis.value
        let y = pad.yAxis.value
        guard x != 0 || y != 0 else { return VRPTouch(active: false, x: 0, y: 0) }
        return VRPTouch(active: true, x: (x + 1) / 2, y: (1 - y) / 2)
    }
}
