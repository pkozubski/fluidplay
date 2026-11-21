import SwiftUI

/// Home screen styled like the console's home screen: paired consoles with a frame from the last game,
/// recently played games and other video sources, over a background with a flowing ribbon.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: GameLibrary
    @State private var showAllWindows = false

    init(model: AppModel) {
        self.model = model
        self.library = model.library
    }

    var body: some View {
        ZStack {
            ConsoleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    topBar
                    if case .failed(let text) = model.state {
                        ErrorBanner(text: text) { model.dismissError() }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    consolesSection
                    if !library.recentGames.isEmpty {
                        recentSection
                    }
                    otherSourcesSection
                }
                .padding(.horizontal, 40)
                .padding(.top, 44)
                .padding(.bottom, 40)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .animation(.spring(duration: 0.35), value: model.state)
        .task {
            await model.refreshSources()
            while !Task.isCancelled {
                await model.refreshConsoleStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    AppMark(size: 30)
                    HStack(spacing: 5) {
                        Text(verbatim: "Fluid")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        Text(verbatim: "Play")
                            .font(.system(size: 17, weight: .light, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .foregroundStyle(.white)
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .frame(height: 46)
                .glassEffect(.regular, in: Capsule())

                HStack(spacing: 2) {
                    TopBarButton(symbol: "link.badge.plus", help: String(localized: "Link console")) { model.showPairing = true }
                    TopBarButton(symbol: "arrow.clockwise", help: String(localized: "Find consoles and refresh sources")) {
                        Task {
                            await model.refreshSources()
                            await model.refreshConsoleStatus()
                        }
                    }
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 42, height: 42)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")
                }
                .padding(.horizontal, 4)
                .frame(height: 46)
                .glassEffect(.regular, in: Capsule())

                Spacer()

                ControllerPill(name: model.controllerName)
            }
        }
    }

    // MARK: Consoles

    private var consolesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: String(localized: "Your consoles"))
            if model.consoles.isEmpty {
                EmptyConsolesCard { model.showPairing = true }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400, maximum: 520), spacing: 20)], alignment: .leading, spacing: 20) {
                    ForEach(model.consoles) { console in
                        ConsoleTile(
                            console: console,
                            availability: model.consoleAvailability[console.id] ?? .searching,
                            game: model.runningApp(of: console),
                            artwork: library.consoleImage(console.id),
                            busy: model.state == .starting,
                            onPlay: { play(console) },
                            onRemove: { model.removeConsole(console) })
                    }
                    AddConsoleTile { model.showPairing = true }
                }
                // A frame saved in the background swaps the tile images.
                .id(library.revision)
            }
        }
    }

    // MARK: Recently played

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: String(localized: "Recently played"))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 18) {
                    ForEach(library.recentGames) { game in
                        GameTile(game: game, artwork: library.gameImage(game),
                                 disabled: model.state == .starting || console(for: game) == nil) {
                            if let console = console(for: game) { play(console) }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .id(library.revision)
        }
    }

    private func console(for game: RecentGame) -> RegisteredConsole? {
        model.consoles.first { $0.id == game.consoleID } ?? model.consoles.first
    }

    private func play(_ console: RegisteredConsole) {
        guard let item = model.sources.first(where: { $0.id == "console-\(console.id)" }) else { return }
        model.play(item)
    }

    // MARK: Other sources

    private var otherSourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: String(localized: "Other sources"))
                Text("streaming app windows, displays and demo")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if hiddenWindowCount > 0 || showAllWindows {
                    Button(showAllWindows ? String(localized: "Show less") : String(localized: "All windows (\(hiddenWindowCount))")) {
                        withAnimation(.spring(duration: 0.3)) { showAllWindows.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                }
                Button {
                    Task { await model.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(CircleIconButtonStyle(size: 28))
                .help("Refresh list")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(otherSources) { item in
                    SourceTile(item: item, disabled: model.state == .starting) { model.play(item) }
                }
            }

            if model.needsScreenPermission {
                PermissionNote { model.openScreenRecordingSettings() }
            }
        }
    }

    private var otherSources: [SourceItem] {
        model.sources.filter { item in
            switch item.kind {
            case .console:
                return false
            case .window:
                return item.isStreamingClient || showAllWindows || model.settings.showDiagnosticSources
            case .display:
                return true
            case .testPattern(let cadence):
                return cadence == .fps30in60 || model.settings.showDiagnosticSources
            }
        }
    }

    private var hiddenWindowCount: Int {
        guard !model.settings.showDiagnosticSources else { return 0 }
        return model.sources.filter { item in
            if case .window = item.kind { return !item.isStreamingClient }
            return false
        }.count
    }
}

// MARK: Components
/// App mark: the app icon itself (our own artwork — no third-party logos in the brand).
struct AppMark: View {
    var size: CGFloat = 30

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1.25, height: size * 1.25)
            .shadow(color: Theme.accentTo.opacity(0.5), radius: 8)
    }
}

private struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.white.opacity(0.95))
    }
}

private struct TopBarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.88))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.white.opacity(hovered ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct ControllerPill: View {
    let name: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 14))
                .foregroundStyle(name == nil ? Theme.textTertiary : Theme.ok)
            Text(name ?? String(localized: "Connect a controller"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .glassEffect(.regular, in: Capsule())
        .help(name == nil ? String(localized: "Connect a DualSense via Bluetooth or USB") : String(localized: "Controller ready to play"))
    }
}

/// Console tile like on the console's home screen: a frame from the last game in the background, glass labels on top.
private struct ConsoleTile: View {
    let console: RegisteredConsole
    let availability: ConsoleAvailability
    let game: String?
    let artwork: NSImage?
    let busy: Bool
    let onPlay: () -> Void
    let onRemove: () -> Void
    @State private var hovered = false
    @State private var confirmRemove = false

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    identity
                    Spacer(minLength: 12)
                    Menu {
                        Button("Unpair…", role: .destructive) { confirmRemove = true }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .fixedSize()
                    .help("Console settings")
                }
                Spacer(minLength: 16)
                HStack(spacing: 10) {
                    Button(action: onPlay) {
                        Label(availability == .standby ? String(localized: "Wake & play") : String(localized: "Play"), systemImage: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.glassTint)
                    .controlSize(.extraLarge)
                    .disabled(busy)
                    StatusPill(text: statusText, color: statusColor, pulsing: availability == .searching)
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(hovered ? Theme.glow.opacity(0.7) : Theme.strokeStrong, lineWidth: hovered ? 1.5 : 1)
        }
        .shadow(color: Theme.accentTo.opacity(hovered ? 0.45 : 0.15), radius: hovered ? 26 : 14, y: 8)
        .scaleEffect(hovered ? 1.012 : 1)
        .animation(.spring(duration: 0.3), value: hovered)
        .onHover { hovered = $0 }
        .confirmationDialog("Unpair \(console.nickname)?", isPresented: $confirmRemove) {
            Button("Unpair", role: .destructive, action: onRemove)
        } message: {
            Text("To play on this console again, you'll need to pair it again with the PIN shown on the PS5.")
        }
    }

    @ViewBuilder
    private var background: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                }
        } else {
            ZStack(alignment: .trailing) {
                LinearGradient(colors: [Theme.accentTo.opacity(0.55), Theme.backgroundTop, Theme.backgroundBottom],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                Image(systemName: "gamecontroller")
                    .font(.system(size: 130, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.08))
                    .padding(.trailing, 30)
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            Image(systemName: "playstation.logo")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.accentWide))
            VStack(alignment: .leading, spacing: 2) {
                Text(console.nickname)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 18)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
    }

    private var subtitle: String {
        if let game, availability == .ready { return game }
        return "PS5 · \(console.host)"
    }

    private var statusText: String {
        switch availability {
        case .searching: return String(localized: "Searching…")
        case .ready: return String(localized: "Ready")
        case .standby: return String(localized: "Rest mode")
        case .offline: return String(localized: "Unavailable")
        }
    }

    private var statusColor: Color {
        switch availability {
        case .searching: return Theme.textTertiary
        case .ready: return Theme.ok
        case .standby: return Theme.warn
        case .offline: return Theme.error
        }
    }
}

private struct AddConsoleTile: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.glow)
                    .frame(width: 84, height: 84)
                    .glassEffect(.regular.tint(Theme.glassTint.opacity(hovered ? 0.45 : 0.25)), in: Circle())
                Text("Link console")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.glow)
                Text("Pair with the PIN shown on your PS5")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.accentTo.opacity(hovered ? 0.12 : 0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    .foregroundStyle(Theme.glow.opacity(hovered ? 0.8 : 0.45))
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.18), value: hovered)
    }
}

/// Tile for a recently played game: a frame from the session, the title and when it was played.
private struct GameTile: View {
    let game: RecentGame
    let artwork: NSImage?
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Theme.accentTo.opacity(0.5), Theme.backgroundBottom],
                                       startPoint: .topTrailing, endPoint: .bottomLeading)
                    }
                }
                .frame(width: 256, height: 144)
                .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(game.lastPlayed, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(12)
                if hovered, !disabled {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(Theme.glassTint.opacity(0.5)), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(width: 256, height: 144)
            .clipShape(shape)
            .overlay(shape.strokeBorder(hovered ? Theme.glow.opacity(0.7) : Theme.stroke, lineWidth: hovered ? 1.5 : 1))
            .shadow(color: Theme.accentTo.opacity(hovered ? 0.4 : 0), radius: 18, y: 6)
            .scaleEffect(hovered ? 1.03 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .animation(.spring(duration: 0.28), value: hovered)
        .help(disabled ? game.title : String(localized: "Play on console — \(game.title)"))
    }
}

private struct EmptyConsolesCard: View {
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Link your PS5 and play more smoothly")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                Text("The console stream goes straight into frame generation and upscaling on your Mac — 30 fps games look like 60.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    step(1, String(localized: "On your PS5: Settings → System → Remote Play → Link Device"))
                    step(2, String(localized: "Here: enter the PIN from the console screen and your PSN account ID"))
                    step(3, String(localized: "Click “Play” — the cursor and controls hide while you play"))
                }
                .padding(.top, 4)
                Button(action: action) {
                    Label("Add console", systemImage: "plus")
                }
                .buttonStyle(AccentButtonStyle(compact: true))
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            Image(systemName: "gamecontroller")
                .font(.system(size: 100, weight: .ultraLight))
                .foregroundStyle(Theme.accentWide)
                .opacity(0.8)
                .padding(.trailing, 20)
        }
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentTo.opacity(0.12), Theme.card], startPoint: .topTrailing, endPoint: .bottomLeading))
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accentInk)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.78))
        }
    }
}

private struct SourceTile: View {
    let item: SourceItem
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(hovered ? 0.8 : 0))
            }
            .padding(.horizontal, 12)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hovered ? Theme.cardHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }

    private var symbol: String {
        switch item.kind {
        case .console: return "playstation.logo"
        case .window: return item.isStreamingClient ? "gamecontroller" : "macwindow"
        case .display: return "display"
        case .testPattern: return "sparkles.tv"
        }
    }

    private var title: String {
        if case .testPattern(let cadence) = item.kind {
            return cadence == .fps30in60 ? String(localized: "Demo · 30 fps game") : cadence.label
        }
        return item.title
    }

    private var subtitle: String {
        if case .testPattern = item.kind { return String(localized: "Try it without a console") }
        return item.subtitle
    }
}

private struct PermissionNote: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 11))
            Text("Windows from PXPlay, Moonlight and other apps appear here once you allow Screen Recording.")
            Button("Allow…", action: action)
                .buttonStyle(.link)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textTertiary)
    }
}

private struct ErrorBanner: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.error)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't connect")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleIconButtonStyle(size: 24))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.error.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.error.opacity(0.3)))
    }
}
