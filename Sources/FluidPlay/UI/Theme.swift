import AppKit
import SwiftUI

/// Colors and small elements shared across screens (dark navy fading into purple, purple accent).
enum Theme {
    static let background = Color(red: 0.035, green: 0.027, blue: 0.075)
    /// Top and bottom background colors of the home screen (like the console's home screen).
    static let backgroundTop = Color(red: 0.075, green: 0.047, blue: 0.157)
    static let backgroundBottom = Color(red: 0.027, green: 0.024, blue: 0.067)
    static let card = Color.white.opacity(0.045)
    static let cardHover = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.14)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.4)

    static let accentFrom = Color(red: 0.69, green: 0.52, blue: 1.0)
    static let accentTo = Color(red: 0.51, green: 0.31, blue: 0.97)
    static let accentFar = Color(red: 0.36, green: 0.40, blue: 0.98)
    static let accentInk = Color.white
    /// Light purple for lines, glow and active icons.
    static let glow = Color(red: 0.76, green: 0.62, blue: 1.0)
    /// Glass tint of primary buttons.
    static let glassTint = Color(red: 0.45, green: 0.25, blue: 0.95)

    static let ok = Color(red: 0.239, green: 0.863, blue: 0.518)
    static let warn = Color(red: 0.961, green: 0.784, blue: 0.294)
    static let error = Color(red: 1, green: 0.365, blue: 0.365)

    static let accent = LinearGradient(colors: [accentFrom, accentTo], startPoint: .leading, endPoint: .trailing)
    static let accentWide = LinearGradient(colors: [accentFrom, accentTo, accentFar], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Primary button with the accent gradient.
struct AccentButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 15, weight: .semibold))
            .foregroundStyle(Theme.accentInk)
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? 30 : 42)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(Theme.accent, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: Theme.accentTo.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Round icon-only button.
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .overlay(Circle().strokeBorder(Theme.stroke))
            .contentShape(Circle())
    }
}

/// Small status indicator: dot + text.
struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 4)
                .opacity(pulsing ? 0.5 : 1)
                .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulsing)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Provides access to the window that hosts the view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

extension NSWindow {
    /// Shows or hides the close, minimize and full-screen buttons.
    func setTrafficLightsVisible(_ visible: Bool, animated: Bool = true) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.25 : 0
            for type in buttons {
                standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }
}
