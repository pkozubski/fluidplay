import GameController
import SwiftUI

// MARK: Connecting screen

/// Full-screen connecting view: the console and the Mac joined by flowing dots.
/// Cancelled by the button, Esc (handled in the game view) or SHARE + OPTIONS on the controller.
struct ConnectingScreen: View {
    let consoleName: String
    let status: String
    let isConsole: Bool
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ConsoleBackground(dimmed: true)
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 28) {
                    EndpointBadge(symbol: isConsole ? "playstation.logo" : "macwindow",
                                  accessory: isConsole ? "gamecontroller.fill" : nil)
                    ConnectionDots()
                    EndpointBadge(symbol: "laptopcomputer", accessory: "play.fill")
                }
                VStack(spacing: 10) {
                    Text(consoleName.isEmpty ? String(localized: "Connecting…") : String(localized: "Connecting to \(consoleName)…"))
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(status.isEmpty ? String(localized: "This may take a moment") : status)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.7))
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: status)
                }
                .padding(.top, 52)
                Spacer()
                VStack(spacing: 14) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.extraLarge)
                    Text(isConsole ? String(localized: "Press Esc or SHARE + OPTIONS on the controller to cancel") : String(localized: "Press Esc to cancel"))
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.bottom, 54)
            }
            .padding(.horizontal, 40)
        }
        .task {
            // SHARE (Create) + OPTIONS on the controller — as in Remote Play apps.
            while !Task.isCancelled {
                if let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad,
                   pad.buttonMenu.isPressed, pad.buttonOptions?.isPressed == true {
                    onCancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

/// Glass circle with a large icon and a small accessory in the corner.
private struct EndpointBadge: View {
    let symbol: String
    let accessory: String?

    var body: some View {
        ZStack {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white)
            if let accessory {
                Image(systemName: accessory)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: 34, y: 34)
            }
        }
        .frame(width: 150, height: 150)
        .glassEffect(.regular.tint(Theme.glassTint.opacity(0.18)), in: Circle())
    }
}

/// Dots with a bright wave travelling from the console to the Mac.
private struct ConnectionDots: View {
    private let count = 7

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            // The wave sweeps through the dots in 1.6 s, with a brief pause before the next pass.
            let position = (time.truncatingRemainder(dividingBy: 1.6) / 1.6) * Double(count + 2) - 1.5
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.glow.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 34))
                    .frame(width: 70, height: 70)
                    .offset(x: CGFloat(position - Double(count - 1) / 2) * 30)
                    .blendMode(.plusLighter)
                HStack(spacing: 16) {
                    ForEach(0..<count, id: \.self) { index in
                        let distance = abs(Double(index) - position)
                        let lit = max(0, 1 - distance / 1.6)
                        Circle()
                            .fill(.white.opacity(0.35 + 0.65 * lit))
                            .frame(width: 14, height: 14)
                            .scaleEffect(0.85 + 0.45 * lit)
                            .shadow(color: Theme.glow.opacity(lit), radius: 8 * lit)
                    }
                }
            }
            .frame(width: Double(count) * 30)
        }
    }
}

// MARK: Blur under the bar

/// Blur that builds toward the bottom of the screen (in-game bar). Materials blur the game video underneath,
/// and masks make the blur and darkening fade in gently, without a visible edge.
struct ProgressiveBlur: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.55), location: 0.35),
                    .init(color: .black, location: 0.7),
                ], startPoint: .top, endPoint: .bottom))
            Rectangle()
                .fill(.thinMaterial)
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom))
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: Theme.backgroundBottom.opacity(0.35), location: 0.5),
                .init(color: Theme.backgroundBottom.opacity(0.7), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}
