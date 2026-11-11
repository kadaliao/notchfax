import Foundation
import os

/// The archive on disk: `store.json` plus an `images` folder, inside the profile's
/// directory in Application Support. Every change is written before anything is
/// printed or acknowledged, so a quit at any moment loses nothing.
@MainActor
final class FaxStore {
    let directory: URL
    private(set) var archive: FaxArchive
    private let logger = Logger(subsystem: "com.kadaliao.notchfax", category: "fax.store")

    private var fileURL: URL { directory.appendingPathComponent("store.json") }
    private var imagesURL: URL { directory.appendingPathComponent("images", isDirectory: true) }

    init(directory: URL) {
        self.directory = directory
        archive = Self.read(from: directory.appendingPathComponent("store.json")) ?? FaxArchive()
    }

    /// Applies a change and writes it through.
    @discardableResult
    func update<T>(_ change: (inout FaxArchive) -> T) -> T {
        let result = change(&archive)
        save()
        return result
    }

    func save() {
        do {
            try prepareDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(archive)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            logger.error("Could not save the fax archive: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Images

    /// Writes a picture and returns its file name.
    func writeImage(_ data: Data, name: String) throws -> String {
        try prepareDirectories()
        let file = Self.safeFileName(name) + ".png"
        try data.write(to: imagesURL.appendingPathComponent(file), options: [.atomic])
        return file
    }

    func readImage(_ file: String) -> Data? {
        try? Data(contentsOf: imagesURL.appendingPathComponent(Self.safeFileName(file, keepExtension: true)))
    }

    func removeImages(_ files: [String]) {
        for file in files {
            try? FileManager.default.removeItem(at: imagesURL.appendingPathComponent(Self.safeFileName(file, keepExtension: true)))
        }
    }

    // MARK: Private

    private func prepareDirectories() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: imagesURL.path) {
            try manager.createDirectory(at: imagesURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private static func read(from url: URL) -> FaxArchive? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let archive = try? JSONDecoder().decode(FaxArchive.self, from: data) { return archive }
        // Keep an unreadable file aside rather than overwrite it with an empty archive.
        let aside = url.deletingLastPathComponent().appendingPathComponent("store-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }

    /// Server ids are UUIDs; anything else is reduced to a harmless file name.
    static func safeFileName(_ name: String, keepExtension: Bool = false) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: keepExtension ? "-_." : "-_"))
        let cleaned = String(name.unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "image" : String(trimmed.prefix(80))
    }
}
