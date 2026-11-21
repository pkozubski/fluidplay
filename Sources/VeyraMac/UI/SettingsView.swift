import SwiftUI

/// Settings window (⌘,): everything you don't need to change during play.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            Tab("Image", systemImage: "wand.and.sparkles") {
                ImageSettings(model: model)
            }
            Tab("Game", systemImage: "gamecontroller") {
                PlaySettings(model: model)
            }
            Tab("Consoles", systemImage: "playstation.logo") {
                ConsoleSettings(model: model)
            }
            Tab("Capture", systemImage: "macwindow") {
                CaptureSettings(model: model)
            }
            Tab("Advanced", systemImage: "gearshape.2") {
                AdvancedSettings(model: model)
            }
        }
        .frame(width: 540, height: 460)
    }
}

private struct ImageSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $model.settings.frameGen) {
                    ForEach(FrameGenMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Skip duplicate frames", isOn: $model.settings.dedupe)
                    .disabled(model.settings.frameGen == .off)
            } header: {
                Text("Frame generation")
            } footer: {
                Text("Every display refresh gets a frame: either a real one or one computed between two real ones. A 24, 30 or 40 fps game then plays at a steady 60 fps on a 60 Hz display. Adds about 20–40 ms of latency.")
            }

            Section {
                Toggle("MetalFX upscaling", isOn: $model.settings.metalFX)
                Toggle("ML super resolution", isOn: $model.settings.mlSuperRes)
                LabeledContent("Sharpening") {
                    HStack {
                        Slider(value: $model.settings.sharpness, in: 0...1)
                            .frame(width: 180)
                        Text("\(Int((model.settings.sharpness * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Upscaling")
            } footer: {
                Text("ML super resolution works for video up to 720p. MetalFX fits the result to the display's resolution.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaySettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Stream quality", selection: $model.settings.streamHeight) {
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                    Text("540p").tag(540)
                }
                Toggle("H.265 codec", isOn: $model.settings.streamHEVC)
                BitratePicker(value: $model.settings.streamBitrateMbps)
            } header: {
                Text("PS5 stream")
            } footer: {
                Text("720p lets you turn on ML super resolution. H.265 gives a better picture at the same bandwidth. A higher bitrate means less blockiness in fast scenes, but more lost packets on weak Wi‑Fi — the stats show how many Mbps actually arrive.")
            }

            Section("Game screen") {
                Toggle("Full screen after clicking “Play”", isOn: $model.settings.autoFullScreen)
                Toggle("Show video stats", isOn: $model.settings.showHUD)
            }

            Section {
                LabeledContent("Connected", value: model.controllerName ?? String(localized: "none"))
                Toggle("DualSense mode", isOn: $model.settings.dualSenseMode)
                VibrationSlider(value: $model.settings.vibration)
                Toggle("Adaptive triggers", isOn: $model.settings.adaptiveTriggers)
                    .disabled(!model.settings.dualSenseMode)
            } header: {
                Text("Controller")
            } footer: {
                Text("DualSense mode: the console sends haptics, adaptive trigger effects and the light bar color. Turn it off if you play with an Xbox or DualShock 4 controller — you'll get regular vibration.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConsoleSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.consoles.isEmpty {
                    Text("No paired consoles.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.consoles) { console in
                    HStack {
                        Image(systemName: "playstation.logo")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(console.nickname)
                            Text(console.host)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { model.removeConsole(console) }
                            .disabled(model.state.isRunning || model.state == .starting)
                    }
                }
            } header: {
                Text("Paired consoles")
            } footer: {
                Text("Pairing keys are stored in the macOS keychain. The console's IP address updates automatically when your router changes it.")
            }

            Section {
                Button("Add console…") {
                    model.showPairing = true
                    model.mainWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CaptureSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Processing resolution", selection: $model.settings.resolution) {
                    ForEach(ProcessingResolution.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                Toggle("Crop window title bar", isOn: $model.settings.cropTitleBar)
            } header: {
                Text("Other apps' windows")
            } footer: {
                Text("Applies to capturing windows (e.g. PXPlay, Moonlight) and the whole display. Built-in Remote Play doesn't use these settings.")
            }

            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    if model.needsScreenPermission {
                        Button("Allow…") { model.openScreenRecordingSettings() }
                    } else {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Show diagnostic sources", isOn: $model.settings.showDiagnosticSources)
            } footer: {
                Text("All windows and test patterns on the home screen.")
            }

            Section("Shortcuts (also work in other apps)") {
                LabeledContent("Overlay / full screen", value: "⌃⌥⌘O")
                LabeledContent("Frame generation on/off", value: "⌃⌥⌘F")
                LabeledContent("Stats", value: "⌃⌥⌘H")
            }

            Section("While playing") {
                LabeledContent("Show settings", value: String(localized: "move the mouse"))
                LabeledContent("Full screen", value: String(localized: "double-click the video"))
                LabeledContent("Exit full screen", value: "Esc")
                LabeledContent("End game", value: "⌘.")
            }
        }
        .formStyle(.grouped)
    }
}
