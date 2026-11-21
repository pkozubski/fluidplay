import SwiftUI

/// Home screen or game screen — depending on the session state.
struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            if showsPlayer {
                PlayerView(model: model)
                    .transition(.opacity)
            } else {
                HomeView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showsPlayer)
        .frame(minWidth: 960, minHeight: 600)
        .background(WindowReader { window in
            model.mainWindow = window
            window.backgroundColor = .black
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.collectionBehavior.insert(.fullScreenPrimary)
        })
        .sheet(isPresented: $model.showPairing) {
            PairingSheet(model: model)
        }
        .sheet(isPresented: Binding(
            get: { model.loginPinIncorrect != nil },
            set: { if !$0 { model.loginPinIncorrect = nil } }
        )) {
            LoginPinSheet(model: model)
        }
    }

    private var showsPlayer: Bool {
        model.state == .starting || model.state.isRunning
    }
}
