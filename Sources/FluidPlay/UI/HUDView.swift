import SwiftUI

/// Overlay with pipeline stats.
struct HUDView: View {
    let stats: DisplayStats

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(String(localized: "Source"), sourceText)
            row(String(localized: "Frames"), frameGenText)
            row(String(localized: "Scaling"), scalingText)
            row(String(localized: "Display"), displayText)
            if stats.smoothness.seconds > 0 {
                row(String(localized: "Smoothness"), smoothnessText)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fixedSize()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 72, alignment: .leading)
            Text(value)
        }
    }

    private func fps(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private var sourceText: String {
        guard !stats.inputSize.isEmpty else { return String(localized: "waiting for video…") }
        var text = String(localized: "\(stats.inputSize) · \(fps(stats.captureFps)) fps")
        if stats.captureFps - stats.uniqueFps > 3, stats.uniqueFps > 0 {
            text += " " + String(localized: "(\(fps(stats.uniqueFps)) unique)")
        }
        if stats.smoothness.streamMbps > 0 {
            let rate = stats.smoothness.streamMbps.formatted(.number.precision(.fractionLength(0)))
            text += " · " + String(localized: "\(rate) Mbps")
        }
        return text
    }

    private var frameGenText: String {
        switch stats.frameGen {
        case .off:
            return String(localized: "frame generation off")
        case .measuring:
            return String(localized: "measuring source frame rate…")
        case .loading:
            return String(localized: "loading model…")
        case .bypass(let sourceFps):
            return String(localized: "skipped — \(fps(sourceFps)) fps source already fills the \(fps(stats.displayHz)) Hz display")
        case .tooSlow(let sourceFps, let costMs):
            let cost = costMs.formatted(.number.precision(.fractionLength(0)))
            return String(localized: "skipped — Mac can't keep up at \(fps(sourceFps)) fps (\(cost) ms per frame)")
        case .active(let sourceFps):
            let ms = stats.interpolateMs.formatted(.number.precision(.fractionLength(1)))
            return String(localized: "\(fps(sourceFps)) → \(fps(stats.displayHz)) fps · \(ms) ms")
        case .failed(let message):
            return String(localized: "error: \(message)")
        }
    }

    private var scalingText: String {
        var parts: [String] = []
        switch stats.superRes {
        case .off:
            break
        case .loading:
            parts.append(String(localized: "ML: loading model…"))
        case .active(let width, let height, let scale):
            parts.append(String(format: "ML %.1f× → %d×%d · %.1f ms", scale, width, height, stats.superResMs))
        case .unsupported:
            parts.append(String(localized: "ML: input too large (max 720p)"))
        case .failed(let message):
            parts.append("ML: \(message)")
        }
        if !stats.drawableSize.isEmpty {
            parts.append("\(stats.metalFX ? "MetalFX" : String(localized: "bilinear")) → \(stats.drawableSize)")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var smoothnessText: String {
        let s = stats.smoothness
        let percent = s.smoothness.formatted(.number.precision(.fractionLength(0)))
        guard s.hitches > 0 else { return String(localized: "\(percent)% · no hitches") }
        return String(localized: "\(percent)% · hitches \(s.hitches) (network \(s.hitchesNetwork) · Mac \(s.hitchesMac) · game \(s.hitchesSource))")
    }

    private var displayText: String {
        let latency = stats.addedLatencyMs.formatted(.number.precision(.fractionLength(0)))
        return String(localized: "\(fps(stats.presentedFps)) fps at \(fps(stats.displayHz)) Hz · latency +\(latency) ms")
    }
}

/// HUD in the overlay window — observes the model so it reacts to the toggle and new stats.
struct OverlayHUD: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.settings.showHUD {
            HUDView(stats: model.stats)
        }
    }
}
