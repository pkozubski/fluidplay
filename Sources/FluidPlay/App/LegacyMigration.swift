import Foundation

/// One-time import of data from VeyraMac, the app's name in 1.0.0 (bundle ID `dev.veyramac.app`).
/// Settings, the measured frame-generation cost and the recently played list are copied from the old
/// defaults domain; session snapshots are moved to the new Application Support folder. Paired consoles
/// are migrated lazily by `ConsoleStore.load()` (they live in the Keychain).
enum LegacyMigration {
    private static let legacyDomain = "dev.veyramac.app"
    private static let legacyFolder = "VeyraMac"
    private static let doneKey = "migratedFromVeyraMac"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        if let old = defaults.persistentDomain(forName: legacyDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("NSWindow Frame") {
                defaults.set(value, forKey: key)
            }
        }

        let files = FileManager.default
        guard let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldSnapshots = support.appendingPathComponent("\(legacyFolder)/Snapshots", isDirectory: true)
        let newFolder = support.appendingPathComponent("FluidPlay", isDirectory: true)
        let newSnapshots = newFolder.appendingPathComponent("Snapshots", isDirectory: true)
        if files.fileExists(atPath: oldSnapshots.path), !files.fileExists(atPath: newSnapshots.path) {
            try? files.createDirectory(at: newFolder, withIntermediateDirectories: true)
            try? files.moveItem(at: oldSnapshots, to: newSnapshots)
        }
    }
}
