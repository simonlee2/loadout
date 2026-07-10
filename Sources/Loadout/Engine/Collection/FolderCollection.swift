import Foundation

/// A `SkillCollection` backed by any folder: each skill is a subfolder and a
/// single `collection.json` index records its metadata (slug/name/summary/
/// contentHash/updatedAt). This is the local mock, the automated-test vehicle,
/// and doubles as a plain iCloud-Drive-folder mode (point `directory` at a
/// folder inside `~/Library/Mobile Documents/...`).
///
/// Write scope is strict: this type only ever writes inside `directory` (skill
/// subfolders, a transient `.staging-*` dir, and `collection.json`).
@MainActor
final class FolderCollection: SkillCollection {
    private let directory: URL
    private let indexURL: URL

    /// ISO8601 with fractional seconds so an immediate re-publish's bumped
    /// `updatedAt` survives the round-trip (plain `.iso8601` truncates to whole
    /// seconds, collapsing back-to-back publishes to the same timestamp).
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid ISO8601 date: \(text)"
                ))
            }
            return date
        }
        return decoder
    }()

    init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("collection.json", isDirectory: false)
    }

    // MARK: Availability

    /// The backing volume is reachable: the nearest existing ancestor of
    /// `directory` exists and is a directory. (`directory` itself need not
    /// exist yet — the first `publish` creates it.)
    var isAvailable: Bool {
        var url = directory
        let fileManager = FileManager.default
        while url.path != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue
            }
            url = url.deletingLastPathComponent()
        }
        var isRootDir: ObjCBool = false
        return fileManager.fileExists(atPath: "/", isDirectory: &isRootDir) && isRootDir.boolValue
    }

    var unavailabilityReason: String? {
        isAvailable ? nil : "The folder \(directory.path) isn't reachable."
    }

    // MARK: List

    func list() async throws -> [CollectionSkill] {
        try loadIndex().map(\.skill).sorted { $0.slug < $1.slug }
    }

    // MARK: Publish

    func publish(slug: String, name: String, summary: String?, directory sourceDir: URL) async throws {
        let fileManager = FileManager.default
        guard isAvailable else {
            throw CollectionError.unavailable(reason: unavailabilityReason ?? "Collection unavailable.")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let contentHash: String
        do {
            contentHash = try TreeHash.hash(directory: sourceDir)
        } catch {
            throw CollectionError.io("could not read \(sourceDir.path): \(error.localizedDescription)")
        }

        // Copy into a staging dir inside `directory`, then swap it into place so
        // an interrupted publish never leaves a half-written skill folder.
        let target = directory.appendingPathComponent(slug, isDirectory: true)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.copyItem(at: sourceDir, to: staging)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw CollectionError.io("could not store \(slug): \(error.localizedDescription)")
        }

        // Upsert the index entry. `updatedAt` strictly increases relative to any
        // previous entry so an immediate re-publish is always distinguishable.
        var entries = (try? loadIndex()) ?? []
        var updatedAt = Date()
        if let previous = entries.first(where: { $0.slug == slug }), updatedAt <= previous.updatedAt {
            updatedAt = previous.updatedAt.addingTimeInterval(0.001)
        }
        entries.removeAll { $0.slug == slug }
        entries.append(IndexEntry(
            slug: slug, name: name, summary: summary,
            contentHash: contentHash, updatedAt: updatedAt
        ))
        entries.sort { $0.slug < $1.slug }
        try writeIndex(entries)
    }

    // MARK: Download

    @discardableResult
    func download(slug: String, to destination: URL) async throws -> String {
        let fileManager = FileManager.default
        let entries = try loadIndex()
        guard let entry = entries.first(where: { $0.slug == slug }) else {
            throw CollectionError.notFound(slug: slug)
        }
        let source = directory.appendingPathComponent(slug, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else {
            throw CollectionError.notFound(slug: slug)
        }

        do {
            // Copy the tree into `destination`, which the caller supplies empty.
            let contents = try fileManager.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil
            )
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in contents {
                try fileManager.copyItem(
                    at: item,
                    to: destination.appendingPathComponent(item.lastPathComponent)
                )
            }
        } catch {
            throw CollectionError.io("could not copy \(slug): \(error.localizedDescription)")
        }

        // Integrity check against the recorded hash.
        let actual = try TreeHash.hash(directory: destination)
        guard actual == entry.contentHash else {
            throw CollectionError.hashMismatch(
                slug: slug, expected: entry.contentHash, actual: actual
            )
        }
        return actual
    }

    // MARK: Remove

    func remove(slug: String) async throws {
        let fileManager = FileManager.default
        var entries = try loadIndex()
        guard entries.contains(where: { $0.slug == slug }) else {
            throw CollectionError.notFound(slug: slug)
        }
        let target = directory.appendingPathComponent(slug, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        entries.removeAll { $0.slug == slug }
        try writeIndex(entries)
    }

    // MARK: Index persistence

    /// One row of `collection.json`.
    private struct IndexEntry: Codable, Hashable {
        let slug: String
        let name: String
        let summary: String?
        let contentHash: String
        let updatedAt: Date

        var skill: CollectionSkill {
            CollectionSkill(
                slug: slug, name: name, summary: summary,
                contentHash: contentHash, updatedAt: updatedAt
            )
        }
    }

    /// Loads the index, returning an empty list when the file is absent.
    private func loadIndex() throws -> [IndexEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: indexURL)
            return try Self.decoder.decode([IndexEntry].self, from: data)
        } catch {
            throw CollectionError.io("collection index is unreadable: \(error.localizedDescription)")
        }
    }

    private func writeIndex(_ entries: [IndexEntry]) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(entries)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw CollectionError.io("could not write collection index: \(error.localizedDescription)")
        }
    }
}
