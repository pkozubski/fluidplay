import SwiftUI

/// Background styled like the console's home screen: dark navy fading into purple, twinkling stars and a slowly
/// twisting ribbon of thin lines.
struct ConsoleBackground: View {
    /// Dimmed background (e.g. behind the connecting screen) — fewer lines and darker.
    var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accentTo.opacity(0.22), .clear], center: UnitPoint(x: 0.15, y: 0.0),
                           startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Theme.accentFar.opacity(0.14), .clear], center: UnitPoint(x: 0.95, y: 0.85),
                           startRadius: 0, endRadius: 800)
            // 30 fps is enough for slow motion and saves GPU.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas(rendersAsynchronously: true) { context, size in
                    Self.drawStars(in: &context, size: size, time: time)
                    Self.drawRibbon(in: &context, size: size, time: time, lines: dimmed ? 22 : 34)
                }
            }
            .opacity(dimmed ? 0.55 : 1)
        }
        .ignoresSafeArea()
    }

    // MARK: Drawing

    private struct Star {
        let x: Double, y: Double, size: Double, phase: Double, speed: Double
    }

    /// Fixed star positions (the same “sky map” on every launch).
    private static let stars: [Star] = {
        var generator = SeededGenerator(seed: 0x5EED)
        return (0..<110).map { _ in
            Star(x: .random(in: 0...1, using: &generator), y: .random(in: 0...1, using: &generator),
                 size: .random(in: 0.8...2.0, using: &generator), phase: .random(in: 0...(2 * .pi), using: &generator),
                 speed: .random(in: 0.3...1.1, using: &generator))
        }
    }()

    private static func drawStars(in context: inout GraphicsContext, size: CGSize, time: Double) {
        for star in stars {
            let twinkle = 0.25 + 0.55 * (0.5 + 0.5 * sin(time * star.speed + star.phase))
            let rect = CGRect(x: star.x * size.width, y: star.y * size.height, width: star.size, height: star.size)
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(twinkle * 0.55)))
        }
    }

    /// Ribbon: each line deviates from the center by cos(line angle + twist), and the twist grows along
    /// the width — the lines converge where the ribbon is turned edge-on.
    private static func drawRibbon(in context: inout GraphicsContext, size: CGSize, time: Double, lines: Int) {
        let width = size.width, height = size.height
        let step = max(8, width / 140)
        let slow = time * 0.18
        for line in 0..<lines {
            let angle = Double(line) / Double(lines) * .pi
            var path = Path()
            var x = -step
            var first = true
            while x <= width + step {
                let u = x / max(width, 1)
                let center = height * (0.64 + 0.07 * sin(u * 4.2 + slow * 1.3) - 0.10 * u)
                let spread = height * (0.11 + 0.06 * sin(u * 2.6 - slow))
                let twist = u * 5.0 + slow * 2.0
                let y = center + spread * cos(angle + twist)
                if first {
                    path.move(to: CGPoint(x: x, y: y))
                    first = false
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                x += step
            }
            // Lines at the front of the ribbon are brighter, those at the back darker.
            let depth = 0.5 + 0.5 * sin(angle + slow)
            let alpha = 0.08 + 0.22 * depth
            let gradient = Gradient(stops: [
                .init(color: Theme.glow.opacity(0), location: 0),
                .init(color: Theme.glow.opacity(alpha * 0.7), location: 0.25),
                .init(color: Color.white.opacity(alpha), location: 0.62),
                .init(color: Theme.accentFar.opacity(alpha * 0.6), location: 0.85),
                .init(color: Theme.accentFar.opacity(0), location: 1),
            ])
            context.stroke(path, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: width, y: 0)),
                           lineWidth: 0.8)
        }
    }
}

/// Simple fixed-seed pseudo-random number generator (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
