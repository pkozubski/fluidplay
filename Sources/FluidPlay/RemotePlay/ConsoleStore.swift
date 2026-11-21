// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

/// A console paired with this Mac. The keys come from pairing and are secret.
struct RegisteredConsole: Codable, Identifiable, Equatable {
    /// The console's MAC address in hex.
    let id: String
    var nickname: String
    var host: String
    let registKey: Data
    let rpKey: Data
    let accountID: Data
}

enum RemotePlayError: LocalizedError {
    case invalidAccountID
    case invalidPin
    case invalidHost
    case pairingRejected
    case pairingTimedOut
    case pairingFailed(Int32)
    case sessionStartFailed(String)
    case connectionFailed(String)
    case consoleNotResponding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAccountID:
            return String(localized: "Invalid PSN account ID. Paste the numeric ID or the Base64 one (it's not the username).")
        case .invalidPin:
            return String(localized: "The pairing PIN must have 8 digits.")
        case .invalidHost:
            return String(localized: "Enter the console's IP address.")
        case .pairingRejected:
            return String(localized: "The console rejected pairing. Check the PIN on the PS5 screen and the account ID.")
        case .pairingTimedOut:
            return String(localized: "The console didn't respond to pairing. Check the IP address and that the PS5 is showing the “Link Device” screen.")
        case .pairingFailed(let code):
            return String(localized: "Pairing failed (code \(String(code))).")
        case .sessionStartFailed(let text):
            return String(localized: "Couldn't start the session: \(text)")
        case .connectionFailed(let text):
            return text
        case .consoleNotResponding:
            return String(localized: "The console isn't responding. Check that it's on, or in rest mode with network access enabled.")
        case .keychain(let status):
            return String(localized: "Keychain error (\(String(status))).")
        }
    }
}

enum AccountID {
    /// The PSN account ID is a 64-bit number; tools show it in decimal or as Base64 of eight bytes.
    static func parse(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber), let value = UInt64(trimmed) {
            return withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        if let data = Data(base64Encoded: trimmed), data.count == 8 {
            return data
        }
        return nil
    }
}

/// The list of paired consoles, stored in the keychain as a single item.
enum ConsoleStore {
    private static let service = "io.github.pkozubski.fluidplay.consoles"
    /// Where the app stored paired consoles before it was renamed from VeyraMac (1.0.0).
    private static let legacyService = "dev.veyramac.app.consoles"
    private static let account = "registered"

    static func load() -> [RegisteredConsole] {
        if let consoles = read(service: service) { return consoles }
        // First launch after the rename: carry the pairing over so the console doesn't need a new PIN.
        guard let legacy = read(service: legacyService), !legacy.isEmpty else { return [] }
        try? save(legacy)
        return legacy
    }

    private static func read(service: String) -> [RegisteredConsole]? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let consoles = try? JSONDecoder().decode([RegisteredConsole].self, from: data)
        else { return nil }
        return consoles
    }

    static func save(_ consoles: [RegisteredConsole]) throws {
        let data = try JSONEncoder().encode(consoles)
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        var status = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData] = data
            item[kSecAttrLabel] = "FluidPlay — paired consoles"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RemotePlayError.keychain(status) }
    }
}

/// Converts a fixed-size C array (imported as a tuple) to text or data.
enum CTuple {
    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func data<T>(_ tuple: T) -> Data {
        withUnsafeBytes(of: tuple) { Data($0) }
    }

    static func copy<T>(_ data: Data, into tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            data.prefix(destination.count).copyBytes(to: destination)
        }
    }
}
