import AppKit
import SwiftUI

/// Shows the controls when the mouse moves and hides them (along with the cursor) after a moment of inactivity.
@MainActor
final class ChromeController: ObservableObject {
    @Published private(set) var visible = true

    /// Cursor over the island or a panel open — the controls stay on screen.
    var islandHovered = false { didSet { restartTimer() } }
    var panelOpen = false { didSet { restartTimer() } }
    weak var window: NSWindow?

    private var timer: Timer?
    private var lastPoint: CGPoint?
    private let hideDelay: TimeInterval = 2.0

    func pointerMoved(to point: CGPoint) {
        // During animations the system can report “movement” in place — only a real change of position counts.
        if let lastPoint, abs(lastPoint.x - point.x) < 1, abs(lastPoint.y - point.y) < 1 { return }
        lastPoint = point
        show()
    }

    /// The cursor left the window. Hide with a short delay, because the same event arrives
    /// when the cursor moves over the island's popover panel.
    func pointerExited() {
        lastPoint = nil
        restartTimer(delay: 0.5)
    }

    func show() {
        if !visible {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { visible = true }
        }
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer(delay: TimeInterval? = nil) {
        timer?.invalidate()
        // Default run loop mode: the timer pauses while a menu is open, so the menu doesn't vanish from under the cursor.
        let timer = Timer(timeInterval: delay ?? hideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func timerFired() {
        if islandHovered || panelOpen || UITest.keepsChromeVisible {
            restartTimer()
            return
        }
        hide()
    }

    private func hide() {
        guard visible else { return }
        withAnimation(.easeOut(duration: 0.4)) { visible = false }
        if pointerIsOverWindow, NSApp.isActive, window?.isKeyWindow == true {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Checked directly, because after clicking “Play” the cursor sits over the window without moving.
    private var pointerIsOverWindow: Bool {
        guard let window, let content = window.contentView else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return content.bounds.contains(point)
    }
}

enum IslandPanel {
    case image, stream, volume
}

/// Game screen: video filling the window, stats, and the settings island at the bottom.
struct PlayerView: View {
    @ObservedObject var model: AppModel
    @StateObject private var chrome = ChromeController()
    @State private var panel: IslandPanel?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black
            if let view = model.previewView {
                VideoSurface(view: view)
            }

            // Layer that captures mouse movement, double-click (full screen) and the keyboard.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.toggleFullScreen() }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(phases: .down) { press in
                    if press.key == .escape, model.state == .starting {
                        Task { await model.stop() }
                    } else if press.key == .escape, model.isFullScreen {
                        model.setFullScreen(false)
                    }
                    // The keyboard doesn't control the game; swallow key presses so the system doesn't beep.
                    return .handled
                }

            if model.settings.showHUD, model.state.isRunning, !model.overlayActive {
                HUDView(stats: model.stats)
                    .padding(.leading, 18)
                    .padding(.top, model.isFullScreen ? 18 : 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            centerContent

            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, model.isFullScreen ? 20 : 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            // The bar leaves the hierarchy while hidden — its blur then doesn't occupy the GPU,
            // which is computing in-between frames during play.
            if model.state.isRunning, chrome.visible || panel != nil {
                GameBar(model: model, panel: $panel, onHover: { chrome.islandHovered = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): chrome.pointerMoved(to: point)
            case .ended: chrome.pointerExited()
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .animation(.easeInOut(duration: 0.2), value: model.settings.showHUD)
        .background(WindowReader { chrome.window = $0 })
        .onAppear {
            focused = true
            chrome.show()
        }
        .onDisappear {
            chrome.stop()
            chrome.window?.setTrafficLightsVisible(true, animated: false)
        }
        .onChange(of: chrome.visible) { _, visible in
            guard !model.isFullScreen else { return }
            chrome.window?.setTrafficLightsVisible(visible)
        }
        .onChange(of: model.isFullScreen) { _, fullScreen in
            chrome.window?.setTrafficLightsVisible(fullScreen || chrome.visible, animated: false)
            chrome.show()
        }
        .onChange(of: panel) { _, panel in
            chrome.panelOpen = panel != nil
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        if model.state == .starting {
            ConnectingScreen(consoleName: connectingName, status: model.statusText,
                             isConsole: model.activeItem?.isConsole ?? false) {
                Task { await model.stop() }
            }
            .transition(.opacity)
        } else if model.overlayActive {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text("Video is shown in an overlay above the source window")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Button("Turn off overlay") { model.toggleOverlay() }
                    .buttonStyle(.bordered)
                Text("⌃⌥⌘O also works when another app is active")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        } else if model.state.isRunning, model.stats.inputSize.isEmpty {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for video…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .allowsHitTesting(false)
        }
    }

    private var connectingName: String {
        guard let item = model.activeItem else { return "" }
        if case .console(let console) = item.kind { return console.nickname }
        return item.title
    }
}

struct VideoSurface: NSViewRepresentable {
    let view: VideoLayerView

    func makeNSView(context: Context) -> VideoLayerView { view }
    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}

// MARK: In-game bar

/// Bar at the bottom of the video, like the console's menu: source and frame generation on the left,
/// console buttons in the middle, settings and exit on the right — over a blur that builds toward the bottom.
private struct GameBar: View {
    @ObservedObject var model: AppModel
    @Binding var panel: IslandPanel?
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ProgressiveBlur()
                .frame(height: 200)
            GlassEffectContainer(spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            badge
                            frameGen
                        }
                        frameGen
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if model.activeItem?.isConsole == true || UITest.showsConsoleControls {
                        consoleButtons
                    }

                    settingsButtons
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 22)
            .onHover(perform: onHover)
        }
    }

    private var badge: some View {
        SourceBadge(model: model)
            .padding(.vertical, 6)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .glassEffect(.regular, in: Capsule())
    }

    private var frameGen: some View {
        FrameGenSwitch(selection: $model.settings.frameGen)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
    }

    /// Controller buttons you don't always have at hand (or for playing without a controller).
    private var consoleButtons: some View {
        HStack(spacing: 6) {
            BarIconButton(symbol: "hand.tap", help: String(localized: "Touchpad — click")) { model.press(.touchpad) }
            BarIconButton(symbol: "square.and.arrow.up", help: "Create") { model.press(.create) }
            PSButton { model.press(.ps) }
            BarIconButton(symbol: "line.3.horizontal", help: "Options") { model.press(.options) }
            BarIconButton(symbol: volumeSymbol, help: String(localized: "Volume"), active: panel == .volume) { toggle(.volume) }
                .popover(isPresented: binding(for: .volume), arrowEdge: .top) {
                    VolumePanel(volume: $model.settings.volume, muted: $model.settings.muted)
                }
        }
        .padding(5)
        .glassEffect(.regular, in: Capsule())
    }

    private var settingsButtons: some View {
        HStack(spacing: 4) {
            BarIconButton(symbol: "wand.and.sparkles", help: String(localized: "Image"), active: panel == .image) { toggle(.image) }
                .popover(isPresented: binding(for: .image), arrowEdge: .top) {
                    ImagePanel(model: model)
                }
            if model.activeItem?.isConsole == true {
                BarIconButton(symbol: "antenna.radiowaves.left.and.right", help: String(localized: "Stream quality and controller"),
                              active: panel == .stream) { toggle(.stream) }
                    .popover(isPresented: binding(for: .stream), arrowEdge: .top) {
                        StreamPanel(model: model)
                    }
            }
            BarIconButton(symbol: "chart.xyaxis.line", help: String(localized: "Stats"), active: model.settings.showHUD) {
                model.settings.showHUD.toggle()
            }
            if model.canUseOverlay {
                BarIconButton(symbol: "rectangle.on.rectangle", help: String(localized: "Overlay"), active: model.overlayActive) {
                    model.toggleOverlay()
                }
            }
            BarIconButton(symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          help: model.isFullScreen ? String(localized: "Window") : String(localized: "Full screen")) {
                model.toggleFullScreen()
            }
            EndButton { Task { await model.stop() } }
                .padding(.leading, 4)
        }
        .padding(5)
        .glassEffect(.regular, in: Capsule())
    }

    private var volumeSymbol: String {
        let volume = model.settings.muted ? 0 : model.settings.volume
        switch volume {
        case 0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func toggle(_ target: IslandPanel) {
        panel = panel == target ? nil : target
    }

    private func binding(for target: IslandPanel) -> Binding<Bool> {
        Binding(get: { panel == target }, set: { if !$0, panel == target { panel = nil } })
    }
}

/// Pressing slightly shrinks the button — like a physical controller button.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}

private struct BarIconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(active ? Theme.glow : .white.opacity(hovered ? 1 : 0.85))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(active ? 0.14 : hovered ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(help)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct PSButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "playstation.logo")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Theme.accentWide).opacity(hovered ? 1 : 0.85))
                .shadow(color: Theme.accentTo.opacity(hovered ? 0.8 : 0.45), radius: hovered ? 14 : 8)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help("PS button — console menu")
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

private struct VolumePanel: View {
    @Binding var volume: Float
    @Binding var muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Volume")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(muted ? String(localized: "muted") : "\(Int((volume * 100).rounded()))%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    muted.toggle()
                } label: {
                    Image(systemName: muted || volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help(muted ? String(localized: "Unmute") : String(localized: "Mute"))
                Slider(value: $volume, in: 0...1)
                    .controlSize(.small)
                    .onChange(of: volume) { _, _ in muted = false }
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 280)
    }
}

private struct SourceBadge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.accentWide))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if model.activeItem?.isConsole == true, model.controllerName == nil {
                        Label("no controller", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warn)
                    }
                    Text(liveLine)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            }
            .frame(maxWidth: 190, alignment: .leading)
        }
    }

    private var symbol: String {
        switch model.activeItem?.kind {
        case .console?: return "playstation.logo"
        case .testPattern?: return "sparkles.tv"
        case .display?: return "display"
        default: return "macwindow"
        }
    }

    private var title: String {
        guard let item = model.activeItem else { return "" }
        if case .console(let console) = item.kind { return model.runningApp(of: console) ?? console.nickname }
        if case .testPattern = item.kind { return String(localized: "Demo") }
        return item.title
    }

    private var liveLine: String {
        let stats = model.stats
        var parts: [String] = []
        if let height = stats.inputSize.split(separator: "×").last { parts.append("\(height)p") }
        switch stats.frameGen {
        case .active(let fps):
            parts.append(String(localized: "\(Int(fps.rounded())) → \(Int(stats.displayHz.rounded())) fps"))
        case .bypass(let fps), .tooSlow(let fps, _):
            parts.append(String(localized: "\(Int(fps.rounded())) fps"))
        case .loading:
            parts.append(String(localized: "loading model…"))
        case .measuring:
            parts.append(String(localized: "measuring…"))
        case .failed:
            parts.append(String(localized: "generation unavailable"))
        case .off:
            if stats.presentedFps > 0 { parts.append(String(localized: "\(Int(stats.presentedFps.rounded())) fps")) }
        }
        return parts.joined(separator: " · ")
    }
}

/// Frame generation switch with a sliding highlight.
private struct FrameGenSwitch: View {
    @Binding var selection: FrameGenMode
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FRAME GENERATION")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 6)
            HStack(spacing: 2) {
                ForEach(FrameGenMode.allCases) { mode in
                    Button {
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { selection = mode }
                    } label: {
                        Text(mode.shortLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selection == mode ? Theme.accentInk : .white.opacity(0.75))
                            .frame(width: 50, height: 24)
                            .background {
                                if selection == mode {
                                    Capsule()
                                        .fill(Theme.accent)
                                        .matchedGeometryEffect(id: "selection", in: namespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(mode.help)
                }
            }
            .padding(2)
            .background(Capsule().fill(.white.opacity(0.07)))
        }
    }
}

private struct EndButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label("End", systemImage: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(Theme.error.opacity(hovered ? 0.5 : 0.3)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("End the game and return to the home screen")
    }
}

// MARK: Island panels

private struct PanelToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

private struct ImagePanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Image")
                .font(.system(size: 15, weight: .semibold))

            PanelToggle(title: String(localized: "MetalFX upscaling"),
                        detail: String(localized: "Sharper upscaling to the display's resolution."),
                        isOn: $model.settings.metalFX)

            VStack(alignment: .leading, spacing: 6) {
                PanelToggle(title: String(localized: "ML super resolution"), detail: superResDetail, isOn: $model.settings.mlSuperRes)
                if model.settings.mlSuperRes, model.activeItem?.isConsole == true, model.settings.streamHeight > 720 {
                    Button("Switch stream to 720p") { model.settings.streamHeight = 720 }
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sharpening")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int((model.settings.sharpness * 100).rounded()))%")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.sharpness, in: 0...1)
                    .controlSize(.small)
            }

            Divider()

            PanelToggle(title: String(localized: "Skip duplicate frames"),
                        detail: String(localized: "Detects 30 fps games sent in a 60 fps stream, so frames are generated between the real ones."),
                        isOn: $model.settings.dedupe)
                .disabled(model.settings.frameGen == .off)
        }
        .padding(18)
        .frame(width: 310)
    }

    private var superResDetail: String {
        switch model.stats.superRes {
        case .active(let width, let height, let scale):
            let factor = Double(scale).formatted(.number.precision(.fractionLength(1)))
            return String(localized: "Active: \(factor)× to \(width)×\(height).")
        case .unsupported:
            return String(localized: "This video is too large — it works at 720p or lower.")
        case .loading:
            return String(localized: "Loading model…")
        case .failed(let message):
            return message
        case .off:
            return String(localized: "Apple's model upscales video up to 720p by 1.5× before it reaches the display.")
        }
    }
}

private struct StreamPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stream quality")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Picker("Resolution", selection: $model.settings.streamHeight) {
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                    Text("540p").tag(540)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(resolutionDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            PanelToggle(title: String(localized: "H.265 codec"),
                        detail: String(localized: "Better quality at the same network bandwidth."),
                        isOn: $model.settings.streamHEVC)

            VStack(alignment: .leading, spacing: 6) {
                BitratePicker(value: $model.settings.streamBitrateMbps)
                Text(bitrateDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Changing quality briefly reconnects the stream.", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            Text("Controller")
                .font(.system(size: 15, weight: .semibold))
            VibrationSlider(value: $model.settings.vibration)
            PanelToggle(title: String(localized: "Adaptive triggers"),
                        detail: String(localized: "DualSense trigger resistance and vibration, set by the game."),
                        isOn: $model.settings.adaptiveTriggers)
                .disabled(!model.settings.dualSenseMode)
        }
        .padding(18)
        .frame(width: 300)
    }

    private var bitrateDetail: String {
        let measured = model.stats.smoothness.streamMbps
        guard model.activeItem?.isConsole == true, measured > 0 else {
            return String(localized: "Less blockiness in fast scenes; choose lower on weak Wi‑Fi.")
        }
        let mbps = measured.formatted(.number.precision(.fractionLength(0)))
        return String(localized: "Currently receiving \(mbps) Mbps.")
    }

    private var resolutionDetail: String {
        switch model.settings.streamHeight {
        case 720: return String(localized: "Lets you turn on ML super resolution and speeds up frame generation.")
        case 540: return String(localized: "For weaker Wi‑Fi.")
        default: return String(localized: "Sharpest picture from the console.")
        }
    }
}

/// Stream bitrate we request from the console.
struct BitratePicker: View {
    @Binding var value: Int

    static let options = [15, 30, 50, 75, 100]

    var body: some View {
        Picker("Bitrate", selection: $value) {
            ForEach(Self.options, id: \.self) { mbps in
                Text(mbps == 15 ? String(localized: "15 Mbps (same as Sony's app)") : String(localized: "\(mbps) Mbps")).tag(mbps)
            }
            if !Self.options.contains(value) {
                Text("\(value) Mbps").tag(value)
            }
        }
    }
}

/// Vibration strength: off – normal – strong.
struct VibrationSlider: View {
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Vibration")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...2, step: 0.25)
                .controlSize(.small)
        }
    }

    private var label: String {
        switch value {
        case 0: return String(localized: "off")
        case ..<0.9: return String(localized: "light")
        case ..<1.3: return String(localized: "normal")
        default: return String(localized: "strong")
        }
    }
}
