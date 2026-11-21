// SPDX-License-Identifier: AGPL-3.0-only

import CoreVideo
import Foundation
import QuartzCore

struct DiscoveredConsole: Identifiable, Equatable {
    enum State: Int {
        case unknown = 0, ready = 1, standby = 2
    }

    let id: String
    let address: String
    let name: String
    let isPS5: Bool
    let state: State
    /// Title of the running game (empty on the console's home screen and in rest mode).
    var runningApp = ""
}

/// Console discovery, waking and pairing — blocking chiaki calls wrapped in `async`.
enum RemotePlayClient {
    private final class DiscoveryBox {
        var hosts: [String: DiscoveredConsole] = [:]
    }

    /// Looks for consoles on the local network. `target` narrows the query to a single address.
    static func discover(target: String? = nil, duration: TimeInterval = 2.5) async -> [DiscoveredConsole] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let box = DiscoveryBox()
                let pointer = Unmanaged.passUnretained(box).toOpaque()
                _ = vrp_discover(target, Int32(duration * 1000), { host, user in
                    guard let host, let user else { return }
                    let box = Unmanaged<DiscoveryBox>.fromOpaque(user).takeUnretainedValue()
                    let value = host.pointee
                    let address = CTuple.string(value.address)
                    let hostID = CTuple.string(value.host_id)
                    let console = DiscoveredConsole(
                        id: hostID.isEmpty ? address : hostID, address: address,
                        name: CTuple.string(value.name), isPS5: value.ps5,
                        state: DiscoveredConsole.State(rawValue: Int(value.state)) ?? .unknown,
                        runningApp: CTuple.string(value.running_app))
                    box.hosts[console.id] = console
                }, pointer)
                continuation.resume(returning: box.hosts.values.sorted { $0.name < $1.name })
            }
        }
    }

    /// Pairs the Mac with the console. The console must be showing the "Link Device" screen with a PIN.
    static func pair(host: String, accountText: String, pinText: String) async throws -> RegisteredConsole {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw RemotePlayError.invalidHost }
        guard let accountID = AccountID.parse(accountText) else { throw RemotePlayError.invalidAccountID }
        let digits = pinText.filter(\.isNumber)
        guard digits.count == 8, let pin = UInt32(digits) else { throw RemotePlayError.invalidPin }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var registration = VRPRegistration()
                let result = accountID.withUnsafeBytes { raw in
                    vrp_register(address, raw.bindMemory(to: UInt8.self).baseAddress, pin, 30_000, &registration)
                }
                switch result {
                case 0:
                    let mac = CTuple.data(registration.mac).map { String(format: "%02x", $0) }.joined()
                    let nickname = CTuple.string(registration.nickname)
                    continuation.resume(returning: RegisteredConsole(
                        id: mac, nickname: nickname.isEmpty ? "PS5" : nickname, host: address,
                        registKey: CTuple.data(registration.regist_key),
                        rpKey: CTuple.data(registration.rp_key), accountID: accountID))
                case 1:
                    continuation.resume(throwing: RemotePlayError.pairingRejected)
                case 2:
                    continuation.resume(throwing: RemotePlayError.pairingTimedOut)
                default:
                    continuation.resume(throwing: RemotePlayError.pairingFailed(result))
                }
                _ = withUnsafeMutableBytes(of: &registration) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            }
        }
    }

    static func wake(_ console: RegisteredConsole) {
        console.registKey.withUnsafeBytes { raw in
            _ = vrp_wakeup(console.host, raw.bindMemory(to: CChar.self).baseAddress)
        }
    }
}

/// Built-in PS Remote Play client: the console stream decoded on the Mac, audio and controller.
final class RemotePlaySource: FrameSource {
    struct Options {
        /// 1080, 720 or 540
        var height = 1080
        var hevc = false
        /// Bitrate requested from the console; 0 = default for the resolution (15 Mbps at 1080p).
        var bitrateKbps = 0
        /// The console sees a DualSense: haptics, adaptive triggers, light bar color.
        var dualSense = true
        var verboseLog = false
    }

    enum Event {
        case status(String)
        /// The console asks for the account login PIN. `true` when the previous one was wrong.
        case loginPinRequested(incorrect: Bool)
    }

    var onFrame: ((SourceFrame) -> Void)?
    var onStop: ((Error?) -> Void)?
    var onEvent: ((Event) -> Void)?
    /// Set before `start()`.
    var monitor: SessionMonitor?

    private let console: RegisteredConsole
    private let options: Options
    private let decoder: VideoDecoder
    private let audio = AudioPlayer()
    private let gamepad = GamepadInput()
    /// Controller vibration, triggers and light bar.
    let feedback = ControllerFeedback()
    private var session: OpaquePointer?
    private var retained: Unmanaged<RemotePlaySource>?

    /// Result of establishing the connection. The console can refuse within a few milliseconds, before `start()`
    /// starts waiting, so we store the result regardless of whether anyone is waiting for it yet.
    private struct Connection {
        var continuation: CheckedContinuation<Void, Error>?
        var result: Result<Void, Error>?
    }

    private let connection = Locked(Connection())
    private let stopping = Locked(false)

    // chiaki video thread state.
    private var smoothedTime: CFTimeInterval = 0
    private let lastKeyframeRequest = Locked<CFTimeInterval>(0)
    private let frameInterval: CFTimeInterval = 1.0 / 60.0

    init(console: RegisteredConsole, options: Options) {
        self.console = console
        self.options = options
        // A 540p stream is 960×540, which the interpolator doesn't accept — the decoder scales it to 1024×576.
        let outputSize: (width: Int, height: Int)? = options.height == 540 ? (1024, 576) : nil
        decoder = VideoDecoder(codec: options.hevc ? .h265 : .h264, outputSize: outputSize)
    }

    func start() async throws {
        try await wakeIfNeeded()

        decoder.onFrame = { [weak self] buffer, time in
            self?.onFrame?(SourceFrame(buffer: buffer, time: time,
                                       contentWidth: CVPixelBufferGetWidth(buffer),
                                       contentHeight: CVPixelBufferGetHeight(buffer)))
        }
        decoder.onDecodeError = { [weak self] _ in
            guard let self else { return }
            self.monitor?.recordDecodeError()
            guard let session = self.session, !self.stopping.get() else { return }
            // At most once per second: every keyframe is a bandwidth spike that can itself
            // cause further packet loss.
            let now = CACurrentMediaTime()
            let allowed = self.lastKeyframeRequest.with { last -> Bool in
                guard now - last > 1 else { return false }
                last = now
                return true
            }
            if allowed {
                self.monitor?.recordKeyframeRequest()
                vrp_session_request_keyframe(session)
            }
        }
        decoder.onDecodeTime = { [weak self] seconds in
            self?.monitor?.recordDecode(ms: seconds * 1000)
        }

        var config = VRPConfig()
        CTuple.copy(console.registKey, into: &config.regist_key)
        CTuple.copy(console.rpKey, into: &config.rp_key)
        CTuple.copy(console.accountID, into: &config.account_id)
        config.height = Int32(options.height)
        config.fps = 60
        config.bitrate_kbps = Int32(options.bitrateKbps)
        config.codec = Int32(options.hevc ? VRP_CODEC_H265 : VRP_CODEC_H264)
        config.dualsense = options.dualSense
        config.verbose_log = options.verboseLog

        // The session holds a pointer to this object, so we keep it alive until `stop()`.
        let retained = Unmanaged.passRetained(self)
        self.retained = retained
        var callbacks = VRPCallbacks()
        callbacks.user = retained.toOpaque()
        callbacks.video = { data, size, framesLost, recovered, user in
            guard let data, let user else { return true }
            let source = Unmanaged<RemotePlaySource>.fromOpaque(user).takeUnretainedValue()
            return source.handleVideo(UnsafeBufferPointer(start: data, count: size), framesLost: Int(framesLost), recovered: recovered)
        }
        callbacks.audio = { samples, frames, channels, rate, user in
            guard let samples, let user else { return }
            let source = Unmanaged<RemotePlaySource>.fromOpaque(user).takeUnretainedValue()
            source.audio.push(samples, frames: frames, channels: Int(channels), rate: Double(rate))
        }
        callbacks.event = { type, code, text, user in
            guard let user else { return }
            let source = Unmanaged<RemotePlaySource>.fromOpaque(user).takeUnretainedValue()
            source.handleEvent(type: Int(type), code: code, text: text.map { String(cString: $0) })
        }
        callbacks.haptics = { left, right, user in
            guard let user else { return }
            Unmanaged<RemotePlaySource>.fromOpaque(user).takeUnretainedValue().feedback.pushHaptics(left: left, right: right)
        }
        callbacks.trigger_effects = { typeLeft, left, typeRight, right, user in
            guard let user, let left, let right else { return }
            let source = Unmanaged<RemotePlaySource>.fromOpaque(user).takeUnretainedValue()
            source.feedback.setTriggerEffects(
                typeLeft: typeLeft, left: Array(UnsafeBufferPointer(start: left, count: 10)),
                typeRight: typeRight, right: Array(UnsafeBufferPointer(start: right, count: 10)))
        }
        callbacks.log = { level, message, _ in
            guard let message else { return }
            NSLog("chiaki[%d] %@", level, String(cString: message))
        }

        onEvent?(.status(String(localized: "Connecting to the console…")))
        var errorCode: Int32 = 0
        let started = console.host.withCString { host -> OpaquePointer? in
            config.host = host
            return vrp_session_start(&config, &callbacks, &errorCode)
        }
        _ = withUnsafeMutableBytes(of: &config) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        guard let started else {
            retained.release()
            self.retained = nil
            throw RemotePlayError.sessionStartFailed(String(cString: vrp_error_string(errorCode)))
        }
        session = started

        gamepad.onController = { [weak self] controller in
            self?.feedback.bind(controller)
        }
        gamepad.onState = { [weak self] state in
            guard let self, let session = self.session, !self.stopping.get() else { return }
            var copy = state
            vrp_session_set_controller(session, &copy)
        }
        gamepad.start()

        // Wait for the connection to be confirmed or refused by the console.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early = connection.with { state -> Result<Void, Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 45) { [weak self] in
                    self?.resolveConnection(.failure(RemotePlayError.consoleNotResponding))
                }
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        guard !stopping.with({ flag -> Bool in
            let was = flag
            flag = true
            return was
        }) else { return }
        gamepad.stop()
        feedback.stop()
        resolveConnection(.failure(CancellationError()))
        if let session {
            self.session = nil
            // Stopping waits for the session threads; after it no more callbacks arrive.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    vrp_session_stop(session)
                    continuation.resume()
                }
            }
        }
        decoder.invalidate()
        audio.stop()
        retained?.release()
        retained = nil
    }

    func submitLoginPin(_ pin: String) {
        guard let session, !stopping.get() else { return }
        vrp_session_set_login_pin(session, pin)
    }

    /// A short controller button press sent from the app (PS, touchpad, Create, Options).
    func press(button: Int32, duration: TimeInterval = 0.15) {
        let bit = UInt32(bitPattern: button)
        gamepad.virtualButtons.with { $0 |= bit }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [gamepad] in
            gamepad.virtualButtons.with { $0 &= ~bit }
        }
    }

    func setVolume(_ volume: Float) {
        audio.setVolume(volume)
    }

    // MARK: chiaki threads

    private func handleVideo(_ bytes: UnsafeBufferPointer<UInt8>, framesLost: Int, recovered: Bool) -> Bool {
        monitor?.recordNetworkFrame(framesLost: max(0, framesLost), recovered: recovered,
                                    bytes: bytes.count, expectedInterval: frameInterval)
        // Packets arrive unevenly from the network; we smooth frame times so the display
        // schedule doesn't inherit these fluctuations.
        let now = CACurrentMediaTime()
        if smoothedTime == 0 || abs(now - smoothedTime) > 0.08 {
            smoothedTime = now
        } else {
            smoothedTime += frameInterval * Double(1 + max(0, framesLost))
            smoothedTime += (now - smoothedTime) * 0.05
        }
        return decoder.decode(bytes, time: smoothedTime)
    }

    private func handleEvent(type: Int, code: Int32, text: String?) {
        switch type {
        case VRP_EVENT_CONNECTED:
            resolveConnection(.success(()))
        case VRP_EVENT_LOGIN_PIN:
            onEvent?(.loginPinRequested(incorrect: code != 0))
        case VRP_EVENT_RUMBLE:
            feedback.setRumble(left: UInt8(truncatingIfNeeded: code >> 8), right: UInt8(truncatingIfNeeded: code))
        case VRP_EVENT_LED_COLOR:
            feedback.setLight(red: UInt8(truncatingIfNeeded: code >> 16), green: UInt8(truncatingIfNeeded: code >> 8),
                              blue: UInt8(truncatingIfNeeded: code))
        case VRP_EVENT_PLAYER_INDEX:
            feedback.setPlayerIndex(Int(code))
        case VRP_EVENT_QUIT:
            let error = vrp_quit_is_error(code) ? RemotePlayError.connectionFailed(Self.describeQuit(code, text)) : nil
            if !resolveConnection(.failure(error ?? RemotePlayError.connectionFailed(String(localized: "The console ended the session.")))) {
                if !stopping.get() { onStop?(error) }
            }
        default:
            break
        }
    }

    /// Resolves connection establishment. Returns `true` if this is the first resolution
    /// (later ones — e.g. a disconnect after a successful start — no longer concern `start()`).
    @discardableResult
    private func resolveConnection(_ result: Result<Void, Error>) -> Bool {
        let (continuation, first) = connection.with { state -> (CheckedContinuation<Void, Error>?, Bool) in
            guard state.result == nil else { return (nil, false) }
            state.result = result
            let waiting = state.continuation
            state.continuation = nil
            return (waiting, true)
        }
        continuation?.resume(with: result)
        return first
    }

    private static func describeQuit(_ reason: Int32, _ text: String?) -> String {
        // ChiakiQuitReason values.
        switch reason {
        case 3: return String(localized: "The console rejected the connection. Pair it again.")
        case 4: return String(localized: "Remote Play is already in use on this console (e.g. by the official app).")
        case 5: return String(localized: "Remote Play on the console crashed. Restart the console.")
        case 6: return String(localized: "This console's Remote Play version isn't supported.")
        case 8, 9: return String(localized: "Couldn't connect to the console. Check the IP address and network.")
        case 11: return String(localized: "The console disconnected the session.")
        default:
            let detail = text ?? String(localized: "unknown reason")
            return String(localized: "Session ended: \(detail) (code \(String(reason))).")
        }
    }

    // MARK: Waking

    private func wakeIfNeeded() async throws {
        onEvent?(.status(String(localized: "Looking for the console…")))
        let found = await RemotePlayClient.discover(target: console.host, duration: 1.2).first
        guard let found else { return } // no reply to discovery doesn't rule out connecting
        guard found.state == .standby else { return }

        onEvent?(.status(String(localized: "Waking the console…")))
        RemotePlayClient.wake(console)
        for _ in 0..<25 {
            try await Task.sleep(for: .seconds(1))
            if let state = await RemotePlayClient.discover(target: console.host, duration: 1.0).first?.state, state == .ready {
                try await Task.sleep(for: .seconds(2))
                return
            }
        }
        throw RemotePlayError.consoleNotResponding
    }
}
