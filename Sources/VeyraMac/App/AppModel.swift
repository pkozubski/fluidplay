import AppKit
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

struct SourceItem: Identifiable, Equatable {
    enum Kind {
        /// Built-in Remote Play client for a paired console.
        case console(RegisteredConsole)
        case window(SCWindow)
        case display(SCDisplay)
        case testPattern(TestPatternSource.Cadence)
    }

    var isConsole: Bool {
        if case .console = kind { return true }
        return false
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    /// Window of a streaming client (PS Remote Play, Chiaki, PXPlay, Moonlight…).
    let isStreamingClient: Bool
    let processID: pid_t?

    static func == (lhs: SourceItem, rhs: SourceItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
    }
}

/// Availability of a paired console on the local network.
enum ConsoleAvailability: Equatable {
    case searching, ready, standby, offline
}

enum SessionState: Equatable {
    case idle
    case starting
    case running(String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Stats snapshot shown in the HUD.
struct DisplayStats: Equatable {
    var inputSize = ""
    var captureFps = 0.0
    var uniqueFps = 0.0
    var presentedFps = 0.0
    var frameGen: FramePipeline.FrameGenState = .off
    var interpolateMs = 0.0
    var superRes: FramePipeline.SuperResState = .off
    var superResMs = 0.0
    var metalFX = false
    var processedSize = ""
    var drawableSize = ""
    var addedLatencyMs = 0.0
    var displayHz = 60.0
    var smoothness = SessionMonitor.Summary()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [SourceItem] = []
    @Published var selectedSourceID: String?
    @Published var state: SessionState = .idle
    @Published var stats = DisplayStats()
    @Published var overlayActive = false
    @Published var needsScreenPermission = false
    @Published var consoles: [RegisteredConsole] = ConsoleStore.load()
    /// The main window is in full screen.
    @Published private(set) var isFullScreen = false
    /// Source of the current session (also while connecting).
    @Published private(set) var activeItem: SourceItem?
    @Published private(set) var consoleAvailability: [String: ConsoleAvailability] = [:]
    /// Short message shown at the top of the picture.
    @Published private(set) var toast: String?
    /// Progress message while connecting to the console.
    @Published var statusText = ""
    @Published var showPairing = false
    /// The console asks for the account login PIN; the value says whether the previous PIN was wrong.
    @Published var loginPinIncorrect: Bool?
    @Published var controllerName: String?
    @Published var settings = EnhanceSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            applyLiveSettings()
            let captureChanged = settings.resolution != oldValue.resolution || settings.cropTitleBar != oldValue.cropTitleBar
            let streamChanged = settings.streamHeight != oldValue.streamHeight || settings.streamHEVC != oldValue.streamHEVC
                || settings.dualSenseMode != oldValue.dualSenseMode || settings.streamBitrateMbps != oldValue.streamBitrateMbps
            let isConsole = activeItem?.isConsole == true
            if state.isRunning, (captureChanged && !isConsole) || (streamChanged && isConsole) {
                Task { await start() }
            }
        }
    }

    /// Title of the game running on the console (from discovery), keyed by console ID.
    @Published private(set) var runningApps: [String: String] = [:]
    /// Session snapshots and recently played games.
    let library = GameLibrary()

    let core: RenderCore?
    let queue = PresentQueue()
    let previewView: VideoLayerView?
    /// Last real (not generated) frame — for the console card snapshot.
    private let latestFrame = Locked<CVPixelBuffer?>(nil)
    private var snapshotTask: Task<Void, Never>?

    private var overlay: OverlayController?
    private var pipeline: FramePipeline?
    private var source: FrameSource?
    private var statsTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private var monitor: SessionMonitor?
    private var monitorSummary = SessionMonitor.Summary()
    /// The app's main window (provided by the view once it appears).
    weak var mainWindow: NSWindow?
    private var ownApplication: SCRunningApplication?
    private var ticks = 0
    private var awakeActivity: NSObjectProtocol?
    private var fullScreenObservers: [NSObjectProtocol] = []

    private static let streamingClientHints = [
        "remoteplay", "remote play", "chiaki", "pxplay", "moonlight", "steam link", "steamlink",
        "geforce now", "xbox", "greenlight", "parsec",
    ]

    init() {
        let core = RenderCore.shared
        self.core = core
        if let core {
            previewView = VideoLayerView(core: core, queue: queue, opaque: true)
        } else {
            previewView = nil
        }
        applyLiveSettings()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        for (name, value) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
            fullScreenObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                Task { @MainActor in
                    guard let self, window == nil || window === self.mainWindow else { return }
                    self.isFullScreen = value
                }
            })
        }
    }

    var selectedSource: SourceItem? {
        sources.first { $0.id == selectedSourceID }
    }

    // MARK: Sources

    func refreshSources() async {
        var items: [SourceItem] = consoles.map { console in
            SourceItem(id: "console-\(console.id)", title: "\(console.nickname) (PS5)",
                       subtitle: String(localized: "Built-in Remote Play · \(console.host)"), kind: .console(console),
                       isStreamingClient: true, processID: nil)
        }
        // Without permission we don't ask ScreenCaptureKit for windows — the query alone shows the system prompt.
        // Playing from the console doesn't need this permission; we only ask for it after "Allow…" is clicked.
        let hasScreenAccess = CGPreflightScreenCaptureAccess()
        needsScreenPermission = !hasScreenAccess
        if hasScreenAccess { do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            needsScreenPermission = false
            let ownBundle = Bundle.main.bundleIdentifier
            ownApplication = content.applications.first { $0.bundleIdentifier == ownBundle && ownBundle != nil }

            var windows: [SourceItem] = []
            for window in content.windows {
                guard window.windowLayer == 0, window.frame.width >= 320, window.frame.height >= 240,
                      let app = window.owningApplication, !app.applicationName.isEmpty,
                      app.bundleIdentifier != ownBundle
                else { continue }
                let haystack = (app.applicationName + " " + app.bundleIdentifier).lowercased()
                let streaming = Self.streamingClientHints.contains { haystack.contains($0) }
                // Windows on other Spaces (e.g. full-screen Remote Play) aren't "on screen",
                // but we always show a streaming client.
                guard window.isOnScreen || streaming else { continue }
                let title = window.title?.isEmpty == false ? window.title! : app.applicationName
                windows.append(SourceItem(
                    id: "window-\(window.windowID)",
                    title: title == app.applicationName ? title : "\(app.applicationName) — \(title)",
                    subtitle: String(localized: "Window \(String(Int(window.frame.width)))×\(String(Int(window.frame.height)))"),
                    kind: .window(window), isStreamingClient: streaming, processID: app.processID))
            }
            windows.sort { ($0.isStreamingClient ? 0 : 1, $0.title) < ($1.isStreamingClient ? 0 : 1, $1.title) }
            items += windows

            for (index, display) in content.displays.enumerated() {
                items.append(SourceItem(
                    id: "display-\(display.displayID)",
                    title: String(localized: "Display \(index + 1)"),
                    subtitle: String(localized: "Entire display \(String(display.width))×\(String(display.height))"),
                    kind: .display(display), isStreamingClient: false, processID: nil))
            }
        } catch {
            needsScreenPermission = true
        } }

        for cadence in TestPatternSource.Cadence.allCases {
            items.append(SourceItem(id: "pattern-\(cadence.rawValue)", title: cadence.label,
                                    subtitle: String(localized: "Synthetic 1080p source"), kind: .testPattern(cadence),
                                    isStreamingClient: false, processID: nil))
        }
        sources = items
        if selectedSource == nil {
            selectedSourceID = items.first { $0.isStreamingClient }?.id ?? items.first?.id
        }
    }

    /// Checks which paired consoles respond on the network. When a console got a new IP address,
    /// saves it (the console is recognized by its MAC address).
    /// UI tests only: shows a sample console instead of the user's (nothing is saved, nothing is
    /// looked up on the network), so screenshots don't reveal real consoles or addresses.
    func showDemoConsole() {
        demoMode = true
        consoles = [RegisteredConsole(id: "demo", nickname: "PS5", host: "192.168.1.20",
                                      registKey: Data(), rpKey: Data(), accountID: Data())]
        consoleAvailability = ["demo": .ready]
        runningApps = [:]
    }

    private var demoMode = false

    func refreshConsoleStatus() async {
        guard !demoMode, !consoles.isEmpty, !state.isRunning, state != .starting else { return }
        let found = await RemotePlayClient.discover(duration: 1.2)
        guard !state.isRunning, state != .starting else { return }
        var availability: [String: ConsoleAvailability] = [:]
        var apps: [String: String] = [:]
        var updated = consoles
        var addressChanged = false
        for index in updated.indices {
            let console = updated[index]
            let match = found.first { $0.id.lowercased() == console.id.lowercased() }
                ?? found.first { $0.address == console.host }
            if let app = match?.runningApp, !app.isEmpty { apps[console.id] = app }
            switch match?.state {
            case .ready?: availability[console.id] = .ready
            case .standby?: availability[console.id] = .standby
            case .unknown?: availability[console.id] = .ready
            case nil: availability[console.id] = .offline
            }
            if let match, match.id.lowercased() == console.id.lowercased(), match.address != console.host {
                updated[index].host = match.address
                addressChanged = true
            }
        }
        if addressChanged, (try? ConsoleStore.save(updated)) != nil {
            consoles = updated
            await refreshSources()
        }
        if availability != consoleAvailability { consoleAvailability = availability }
        if apps != runningApps { runningApps = apps }
    }

    /// Selects the source and starts the game. A console goes straight to full screen (if enabled).
    func play(_ item: SourceItem) {
        selectedSourceID = item.id
        if item.isConsole, settings.autoFullScreen { setFullScreen(true) }
        Task { await start() }
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Session

    func start() async {
        guard let item = selectedSource else { return }
        let keepFullScreen = isFullScreen
        await stopSession(exitFullScreen: false)
        if !keepFullScreen, isFullScreen { setFullScreen(false) }
        activeItem = item
        state = .starting

        let monitor = SessionMonitor(title: item.title)
        self.monitor = monitor
        monitorSummary = SessionMonitor.Summary()
        previewView?.monitor.set(monitor)
        overlay?.videoView.monitor.set(monitor)
        let pipeline = FramePipeline(monitor: monitor)
        pipeline.displayClock.set(queue.clock)
        latestFrame.set(nil)
        pipeline.output = { [queue, latestFrame] frame in
            queue.push(frame)
            if !frame.isGenerated { latestFrame.set(frame.pixelBuffer) }
        }

        let source: FrameSource
        switch item.kind {
        case .console(let console):
            let remote = RemotePlaySource(console: console, options: RemotePlaySource.Options(
                height: settings.streamHeight, hevc: settings.streamHEVC,
                bitrateKbps: min(100, max(2, settings.streamBitrateMbps)) * 1000, dualSense: settings.dualSenseMode,
                verboseLog: ProcessInfo.processInfo.environment["VEYRAMAC_RP_VERBOSE"] != nil))
            remote.monitor = monitor
            remote.onEvent = { [weak self] event in
                Task { @MainActor in
                    guard let self, self.source === remote else { return }
                    switch event {
                    case .status(let text): self.statusText = text
                    case .loginPinRequested(let incorrect): self.loginPinIncorrect = incorrect
                    }
                }
            }
            source = remote
        case .testPattern(let cadence):
            source = TestPatternSource(cadence: cadence)
        case .window(let window):
            source = ScreenCaptureSource(target: .window(window), options: captureOptions)
        case .display(let display):
            source = ScreenCaptureSource(target: .display(display, excluding: ownApplication.map { [$0] } ?? []),
                                         options: captureOptions)
        }
        source.onFrame = { [weak pipeline] frame in pipeline?.submit(frame) }
        source.onStop = { [weak self] error in
            Task { @MainActor in
                guard let self, self.source === source else { return }
                await self.stopSession()
                self.state = .failed(error.map { String(localized: "The source stopped: \($0.localizedDescription)") } ?? String(localized: "The source stopped."))
            }
        }

        self.pipeline = pipeline
        self.source = source
        applyLiveSettings()

        // The display must not sleep during play (the controller doesn't count as user activity).
        // `latencyCritical`: the system doesn't coalesce the app's timers and wakeups (less timing jitter).
        awakeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical], reason: "Video streaming")

        do {
            try await source.start()
            guard self.source === source else { return }
            statusText = ""
            state = .running(item.title)
            if case .console(let console) = item.kind { startSnapshots(of: console) }
        } catch {
            guard self.source === source else { return }
            await stopSession()
            state = .failed(item.isConsole ? error.localizedDescription : String(localized: "Couldn't start the source: \(error.localizedDescription)"))
        }
    }

    func submitLoginPin(_ pin: String) {
        loginPinIncorrect = nil
        (source as? RemotePlaySource)?.submitLoginPin(pin)
    }

    // MARK: Consoles

    func pairConsole(host: String, accountID: String, pin: String) async throws {
        let console = try await RemotePlayClient.pair(host: host, accountText: accountID, pinText: pin)
        var updated = consoles.filter { $0.id != console.id }
        updated.append(console)
        try ConsoleStore.save(updated)
        consoles = updated
        await refreshSources()
        selectedSourceID = "console-\(console.id)"
    }

    func removeConsole(_ console: RegisteredConsole) {
        let updated = consoles.filter { $0.id != console.id }
        guard (try? ConsoleStore.save(updated)) != nil else { return }
        consoles = updated
        library.forget(consoleID: console.id)
        Task { await refreshSources() }
    }

    /// Game on the console: title from the latest discovery.
    func runningApp(of console: RegisteredConsole) -> String? {
        runningApps[console.id]
    }

    // MARK: Console buttons from the toolbar

    enum ConsoleButton {
        case ps, touchpad, create, options

        var flag: Int32 {
            switch self {
            case .ps: return Int32(VRP_BUTTON_PS)
            case .touchpad: return Int32(VRP_BUTTON_TOUCHPAD)
            case .create: return Int32(VRP_BUTTON_SHARE)
            case .options: return Int32(VRP_BUTTON_OPTIONS)
            }
        }
    }

    /// Presses a controller button on the console (e.g. PS, when it's not at hand or playing without a controller).
    func press(_ button: ConsoleButton) {
        (source as? RemotePlaySource)?.press(button: button.flag)
    }

    // MARK: Game snapshots

    /// Snapshot for the console card: shortly after play starts, then every minute and a half, and at the end of the session.
    /// Along the way we ask the console for the game title (discovery also works during streaming).
    private func startSnapshots(of console: RegisteredConsole) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                await self?.takeSnapshot(of: console, askTitle: true)
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    private func takeSnapshot(of console: RegisteredConsole, askTitle: Bool) async {
        if askTitle {
            let found = await RemotePlayClient.discover(target: console.host, duration: 0.8)
            if let app = found.first?.runningApp, !app.isEmpty { runningApps[console.id] = app }
        }
        guard let buffer = latestFrame.get() else { return }
        library.saveSnapshot(buffer, consoleID: console.id, title: runningApps[console.id])
    }

    func stop() async {
        await stopSession()
        state = .idle
    }

    func toggleRunning() {
        Task {
            if state.isRunning || state == .starting { await stop() } else { await start() }
        }
    }

    private func stopSession(exitFullScreen: Bool = true) async {
        hideOverlay()
        if exitFullScreen, isFullScreen { setFullScreen(false) }
        statusText = ""
        loginPinIncorrect = nil
        if let awakeActivity {
            ProcessInfo.processInfo.endActivity(awakeActivity)
            self.awakeActivity = nil
        }
        snapshotTask?.cancel()
        snapshotTask = nil
        if state.isRunning, case .console(let console)? = activeItem?.kind {
            await takeSnapshot(of: console, askTitle: false)
        }
        latestFrame.set(nil)
        let source = self.source
        self.source = nil
        await source?.stop()
        pipeline?.stop()
        monitor?.finish()
        monitor = nil
        previewView?.monitor.set(nil)
        overlay?.videoView.monitor.set(nil)
        pipeline = nil
        activeItem = nil
        queue.clear()
        previewView?.reset()
        stats = DisplayStats()
    }

    private var captureOptions: ScreenCaptureSource.Options {
        ScreenCaptureSource.Options(
            resolution: settings.resolution, cropTitleBar: settings.cropTitleBar,
            maxFrameRate: max(60, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60))
    }

    private var activeView: VideoLayerView? {
        overlayActive ? overlay?.videoView : previewView
    }

    private func applyLiveSettings() {
        let render = RenderSettings(metalFX: settings.metalFX, sharpness: settings.sharpness)
        for view in [previewView, overlay?.videoView] {
            view?.renderer.settings.set(render)
            view?.setNeedsRedraw()
        }
        if let remote = source as? RemotePlaySource {
            remote.setVolume(settings.muted ? 0 : settings.volume)
            let feedback = ControllerFeedback.Settings(vibration: settings.vibration, adaptiveTriggers: settings.adaptiveTriggers)
            if remote.feedback.settings.get() != feedback {
                remote.feedback.settings.set(feedback)
                remote.feedback.settingsChanged()
            }
        }
        pipeline?.config.set(FramePipeline.Config(
            frameGen: settings.frameGen, dedupe: settings.dedupe, mlSuperRes: settings.mlSuperRes,
            displayHz: activeView?.displayHz ?? 60))
    }

    // MARK: Overlay

    /// Overlay above another app's window. For built-in Remote Play and test patterns it toggles full screen.
    var canUseOverlay: Bool {
        switch (activeItem ?? selectedSource)?.kind {
        case .window?, .display?: return true
        default: return false
        }
    }

    func toggleOverlay() {
        guard canUseOverlay else {
            toggleFullScreen()
            return
        }
        if overlayActive {
            hideOverlay()
        } else {
            Task { await showOverlay() }
        }
    }

    private func showOverlay() async {
        guard let core else { return }
        if !state.isRunning { await start() }
        guard state.isRunning, let item = activeItem else { return }

        if overlay == nil {
            overlay = OverlayController(core: core, queue: queue, hud: OverlayHUD(model: self))
        }
        guard let overlay else { return }
        previewView?.isActive = false
        overlay.videoView.isActive = true
        overlay.show(on: screen(for: item))
        overlayActive = true
        applyLiveSettings()

        // Hand focus back to the source app — it should receive the controller and keyboard.
        if let pid = item.processID, let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    private func hideOverlay() {
        guard overlayActive else { return }
        overlay?.videoView.isActive = false
        overlay?.hide()
        overlayActive = false
        previewView?.isActive = true
        applyLiveSettings()
    }

    func toggleFullScreen() {
        setFullScreen(!isFullScreen)
    }

    func setFullScreen(_ on: Bool) {
        guard let window = mainWindow else { return }
        if window.styleMask.contains(.fullScreen) != on {
            window.toggleFullScreen(nil)
        }
    }

    /// Screen the source is on (SCK coordinates originate at the top-left corner of the main screen).
    private func screen(for item: SourceItem) -> NSScreen {
        let fallback = NSScreen.main ?? NSScreen.screens[0]
        switch item.kind {
        case .testPattern, .console:
            return NSApp.mainWindow?.screen ?? fallback
        case .display(let display):
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            } ?? fallback
        case .window(let window):
            guard let primary = NSScreen.screens.first else { return fallback }
            let frame = window.frame
            let flipped = CGRect(x: frame.minX, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height)
            let best = NSScreen.screens.max { a, b in
                area(a.frame.intersection(flipped)) < area(b.frame.intersection(flipped))
            }
            return best ?? fallback
        }
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    // MARK: Stats

    private func tick() {
        ticks += 1
        if ticks % 4 == 0 {
            let name = GamepadInput.connectedName
            if name != controllerName { controllerName = name }
        }
        guard let pipeline, state.isRunning else { return }
        // Every 2 s check whether the source window changed size (e.g. full screen).
        if ticks % 8 == 0, let capture = source as? ScreenCaptureSource {
            Task { await capture.refreshGeometry() }
        }
        let view = activeView
        let displayHz = view?.displayHz ?? 60
        if pipeline.config.get().displayHz != displayHz { applyLiveSettings() }

        let raw = pipeline.stats.get()
        // Once per second: smoothness score and a line in the session log.
        if ticks % 4 == 0, let monitor {
            let target: Double
            switch raw.frameGen {
            case .active: target = displayHz
            case .bypass(let fps): target = min(displayHz, fps)
            default: target = min(displayHz, raw.uniqueFps)
            }
            let window = overlayActive ? overlay?.videoView.window : previewView?.window
            let visible = window?.occlusionState.contains(.visible) ?? false
            monitorSummary = monitor.rollSecond(targetFps: target, displayHz: displayHz, visible: visible)
        }
        var next = DisplayStats()
        next.smoothness = monitorSummary
        next.inputSize = raw.contentWidth > 0 ? "\(raw.contentWidth)×\(raw.contentHeight)" : ""
        next.captureFps = raw.captureFps
        next.uniqueFps = raw.uniqueFps
        next.presentedFps = view?.presentMeter.get().value() ?? 0
        next.frameGen = raw.frameGen
        next.interpolateMs = raw.interpolateMs
        next.superRes = raw.superRes
        next.superResMs = raw.superResMs
        next.metalFX = view?.renderer.usedMetalFX ?? false
        next.processedSize = raw.outputWidth > 0 ? "\(raw.outputWidth)×\(raw.outputHeight)" : ""
        if let drawable = view?.drawablePixels.get(), drawable.width > 0 {
            next.drawableSize = "\(drawable.width)×\(drawable.height)"
        }
        next.addedLatencyMs = raw.addedLatencyMs
        next.displayHz = displayHz
        if next != stats { stats = next }
    }
}
