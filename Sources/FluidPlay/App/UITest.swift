import AppKit
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// UI diagnostics: `FluidPlay --ui-test <directory> [fps30|fps60|fps30in60] [--demo-console]`.
/// Saves screenshots of the start screen and the game screen (with the island and after it hides), prints
/// display stats and quits the app. Launch via `open` so the screenshots use the app's
/// Screen Recording permission (without it you get a fallback screenshot without glass and video).
@MainActor
enum UITest {
    private static var started = false
    /// The in-game bar shows console buttons even with a test pattern (so they're visible in the screenshot).
    static var showsConsoleControls = false
    /// Keeps the in-game bar on screen for the screenshot even when the pointer is outside the window.
    static var keepsChromeVisible = false

    static func runIfRequested(model: AppModel) {
        let arguments = CommandLine.arguments
        guard !started, let index = arguments.firstIndex(of: "--ui-test"), arguments.indices.contains(index + 1) else { return }
        started = true
        setlinebuf(stdout)
        let directory = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cadence = TestPatternSource.Cadence.allCases.first { arguments.contains($0.rawValue) } ?? .fps30in60

        Task { @MainActor in
            showsConsoleControls = true
            // --demo-console: a sample console instead of the user's (for public screenshots).
            if arguments.contains("--demo-console") {
                model.showDemoConsole()
                await model.refreshSources()
            }
            try? await Task.sleep(for: .seconds(2.5))
            await capture(model.mainWindow, to: directory.appendingPathComponent("1-start.png"))

            // Connecting screen (view only, no real connection).
            model.statusText = String(localized: "Waking the console…")
            model.state = .starting
            try? await Task.sleep(for: .seconds(1.5))
            await capture(model.mainWindow, to: directory.appendingPathComponent("1b-connecting.png"))
            model.state = .idle
            model.statusText = ""
            try? await Task.sleep(for: .seconds(0.5))

            await model.refreshSources()
            guard let item = model.sources.first(where: { $0.id == "pattern-\(cadence.rawValue)" }) else {
                print("No test source")
                NSApp.terminate(nil)
                return
            }
            keepsChromeVisible = true
            model.play(item)
            try? await Task.sleep(for: .seconds(1.2))
            await capture(model.mainWindow, to: directory.appendingPathComponent("2-game-island.png"))
            report(model)
            keepsChromeVisible = false

            try? await Task.sleep(for: .seconds(3))
            await capture(model.mainWindow, to: directory.appendingPathComponent("3-game-no-island.png"))
            report(model)

            await model.stop()
            NSApp.terminate(nil)
        }
    }

    private static func report(_ model: AppModel) {
        let s = model.stats
        print("state=\(model.state) image=\(s.inputSize) source=\(Int(s.captureFps)) unique=\(Int(s.uniqueFps)) display=\(Int(s.presentedFps)) fps at \(Int(s.displayHz)) Hz FG=\(s.frameGen)")
    }

    private static func capture(_ window: NSWindow?, to url: URL) async {
        guard let window else {
            print("Screenshot: no window")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw ProcessorError.unsupported("window not visible to ScreenCaptureKit")
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            write(image, to: url)
            print("Screenshot (ScreenCaptureKit): \(url.path)")
        } catch {
            // Without permission: render just the views (no glass and no video).
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                print("Screenshot (fallback, \(error.localizedDescription)): \(url.path)")
            }
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
