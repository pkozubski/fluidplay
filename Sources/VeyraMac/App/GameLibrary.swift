import AppKit
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A recently played game: title from console discovery and a session snapshot.
struct RecentGame: Codable, Identifiable, Equatable {
    /// Game title — also the identifier (the console reports only the name).
    var id: String { title }
    let title: String
    var consoleID: String
    var lastPlayed: Date
}

/// Session snapshots (background of console cards and game tiles) and the list of recently played games.
/// Everything is stored locally in `~/Library/Application Support/VeyraMac/Snapshots`.
@MainActor
final class GameLibrary: ObservableObject {
    @Published private(set) var recentGames: [RecentGame] = []
    /// Changes after a new snapshot is saved — views refresh their images.
    @Published private(set) var revision = 0

    private let directory: URL?
    private var cache: [String: NSImage] = [:]
    private static let recentKey = "recentGames.v1"
    private static let maxRecent = 12
    /// CIContext is thread-safe.
    nonisolated private static let encoder = CIContext(options: [.cacheIntermediates: false])

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VeyraMac/Snapshots", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if let data = UserDefaults.standard.data(forKey: Self.recentKey),
           let games = try? JSONDecoder().decode([RecentGame].self, from: data) {
            recentGames = games
        }
    }

    func consoleImage(_ consoleID: String) -> NSImage? {
        image(named: "console-\(Self.safe(consoleID))")
    }

    func gameImage(_ game: RecentGame) -> NSImage? {
        image(named: "game-\(Self.safe(game.title))")
    }

    /// Saves a session snapshot. JPEG encoding runs in the background; `title` (when the console reported it)
    /// adds the game to recently played.
    func saveSnapshot(_ buffer: CVPixelBuffer, consoleID: String, title: String?) {
        guard let directory else { return }
        var names = ["console-\(Self.safe(consoleID))"]
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanTitle.isEmpty {
            names.append("game-\(Self.safe(cleanTitle))")
            var games = recentGames.filter { $0.title != cleanTitle }
            games.insert(RecentGame(title: cleanTitle, consoleID: consoleID, lastPlayed: Date()), at: 0)
            recentGames = Array(games.prefix(Self.maxRecent))
            if let data = try? JSONEncoder().encode(recentGames) {
                UserDefaults.standard.set(data, forKey: Self.recentKey)
            }
        }
        let urls = names.map { directory.appendingPathComponent("\($0).jpg") }
        Task.detached(priority: .utility) {
            guard let data = Self.encodeJPEG(buffer) else { return }
            for url in urls { try? data.write(to: url, options: .atomic) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for name in names { self.cache[name] = nil }
                self.revision += 1
            }
        }
    }

    func forget(consoleID: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("console-\(Self.safe(consoleID)).jpg"))
        cache["console-\(Self.safe(consoleID))"] = nil
        revision += 1
    }

    private func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = directory?.appendingPathComponent("\(name).jpg"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    /// Downscaled snapshot (960 px wide) as JPEG.
    nonisolated private static func encodeJPEG(_ buffer: CVPixelBuffer) -> Data? {
        let source = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 960 / max(source.extent.width, 1))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = encoder.createCGImage(scaled, from: scaled.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated private static func safe(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(String(mapped).prefix(80))
    }
}
