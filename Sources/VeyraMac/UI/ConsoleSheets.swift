// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Pairing the Mac with a PS5 console.
struct PairingSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var discovered: [DiscoveredConsole] = []
    @State private var searching = false
    @State private var host = ""
    @State private var accountID = ""
    @State private var pin = ""
    @State private var pairing = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add PS5 console")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 4)

            Form {
                Section {
                    if discovered.isEmpty {
                        Text(searching ? String(localized: "Searching for consoles on the network…") : String(localized: "No console found on the local network. Enter the IP address manually."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(discovered) { console in
                        Button {
                            host = console.address
                        } label: {
                            HStack {
                                Image(systemName: host == console.address ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(host == console.address ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(console.name.isEmpty ? String(localized: "Console") : console.name)
                                    Text("\(console.isPS5 ? "PS5" : "PS4") · \(console.address) · \(stateLabel(console.state))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("Console IP address", text: $host, prompt: Text("e.g. 192.168.1.20"))
                    Button {
                        Task { await search() }
                    } label: {
                        Label("Search again", systemImage: "arrow.clockwise")
                    }
                    .disabled(searching)
                } header: {
                    Text("Console")
                }

                Section {
                    TextField("PSN account ID", text: $accountID, prompt: Text("number or Base64"))
                    SecureField("PIN from the PS5 screen", text: $pin, prompt: Text("8 digits"))
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("On your PS5, open Settings → System → Remote Play → Link Device and enter the PIN shown there. The account ID is the number assigned to your PSN account (not your username) — tools such as PSNTools, which Veyra also uses, can look it up.")
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await pair() }
                } label: {
                    if pairing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Pair")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pairing || host.isEmpty || accountID.isEmpty || pin.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 600)
        .task { await search() }
    }

    private func stateLabel(_ state: DiscoveredConsole.State) -> String {
        switch state {
        case .ready: return String(localized: "ready")
        case .standby: return String(localized: "rest mode")
        case .unknown: return String(localized: "status unknown")
        }
    }

    private func search() async {
        searching = true
        let found = await RemotePlayClient.discover()
        discovered = found
        if host.isEmpty, let first = found.first(where: \.isPS5) { host = first.address }
        searching = false
    }

    private func pair() async {
        pairing = true
        errorText = nil
        do {
            try await model.pairConsole(host: host, accountID: accountID, pin: pin)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        pairing = false
    }
}

/// Account login passcode the console asks for when a session starts.
struct LoginPinSheet: View {
    @ObservedObject var model: AppModel
    @State private var pin = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account login passcode")
                .font(.title3.weight(.semibold))
            Text(model.loginPinIncorrect == true
                 ? String(localized: "The previous passcode was incorrect. Enter the passcode you use to log in to your account on the PS5.")
                 : String(localized: "The console is asking for the passcode you use to log in to your account on the PS5."))
                .foregroundStyle(.secondary)
            SecureField("Passcode", text: $pin)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.loginPinIncorrect = nil
                    Task { await model.stop() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Log in") { model.submitLoginPin(pin) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
