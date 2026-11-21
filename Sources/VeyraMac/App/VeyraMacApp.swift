import Carbon.HIToolbox
import SwiftUI

@main
enum EntryPoint {
    static func main() {
        // Headless diagnostic modes: --selftest, --capture-test, --list-windows.
        if SelfTest.shouldRun(CommandLine.arguments) {
            SelfTest.run(CommandLine.arguments)
        }
        VeyraMacApp.main()
    }
}

struct VeyraMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Veyra Mac", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.attach(model)
                    UITest.runIfRequested(model: model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Game") {
                Button("End game") { Task { await model.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!(model.state.isRunning || model.state == .starting))
                Button(model.settings.showHUD ? String(localized: "Hide stats") : String(localized: "Show stats")) { model.settings.showHUD.toggle() }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                Button("Add console…") { model.showPairing = true }
                Button("Refresh sources") { Task { await model.refreshSources() } }
            }
        }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var registered = false

    /// Registers the global hotkeys once the model exists.
    @MainActor
    func attach(_ model: AppModel) {
        guard !registered else { return }
        registered = true
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_O) { [weak model] in
            Task { @MainActor in model?.toggleOverlay() }
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_F) { [weak model] in
            Task { @MainActor in
                guard let model else { return }
                model.settings.frameGen = model.settings.frameGen == .off ? .auto : .off
                model.showToast(String(localized: "Frame generation: \(model.settings.frameGen.label)"))
            }
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_H) { [weak model] in
            Task { @MainActor in
                guard let model else { return }
                model.settings.showHUD.toggle()
                model.showToast(model.settings.showHUD ? String(localized: "Stats on") : String(localized: "Stats off"))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
