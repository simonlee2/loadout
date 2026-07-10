import Foundation
import Observation

/// Persistent record of every write Loadout performs, with the backups
/// needed to revert each one. Lives in Application Support/Loadout:
/// `journal.jsonl` (one ConfigChange per line), `backups/` (pre-change
/// file copies), and `shelf/` (uninstalled skill directories).
@MainActor
@Observable
final class ChangeJournal {
    private(set) var entries: [ConfigChange] = []

    private let directory: URL
    private var journalFile: URL { directory.appendingPathComponent("journal.jsonl") }
    private var backupsDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }
    var shelfDirectory: URL { directory.appendingPathComponent("shelf", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        directory: URL = URL.applicationSupportDirectory
            .appendingPathComponent("Loadout", isDirectory: true)
    ) {
        self.directory = directory
        load()
    }

    /// Backs up `file` and records the change. Call BEFORE writing the file;
    /// if the subsequent write throws, call `revert(_:)` on the result.
    func recordFileEdit(agent: AgentID, summary: String, file: URL) throws -> ConfigChange {
        try ensureDirectories()
        let id = UUID()
        var backupPath: String?
        if FileManager.default.fileExists(atPath: file.path) {
            let backup = backupsDirectory
                .appendingPathComponent("\(id.uuidString)-\(file.lastPathComponent)")
            try FileManager.default.copyItem(at: file, to: backup)
            backupPath = backup.path
        }
        let change = ConfigChange(
            id: id, date: Date(), agent: agent, kind: .fileEdit,
            summary: summary, path: file.path, backupPath: backupPath,
            isReverted: false
        )
        append(change)
        return change
    }

    /// Moves `directory` to the shelf and records the change. The move IS
    /// the mutation — callers do nothing further.
    func recordDirectoryMove(agent: AgentID, summary: String, directory dir: URL) throws -> ConfigChange {
        try ensureDirectories()
        let id = UUID()
        let destination = shelfDirectory
            .appendingPathComponent("\(id.uuidString)-\(dir.lastPathComponent)", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: destination)
        let change = ConfigChange(
            id: id, date: Date(), agent: agent, kind: .directoryMove,
            summary: summary, path: dir.path, backupPath: destination.path,
            isReverted: false
        )
        append(change)
        return change
    }

    /// Records a path (directory, file, or symlink) that the caller is about
    /// to create — e.g. a registry-install deployment. Revert deletes it.
    func recordPathAdd(agent: AgentID, summary: String, path: URL) throws -> ConfigChange {
        try ensureDirectories()
        let change = ConfigChange(
            id: UUID(), date: Date(), agent: agent, kind: .pathAdd,
            summary: summary, path: path.path, backupPath: nil,
            isReverted: false
        )
        append(change)
        return change
    }

    /// Restores the pre-change state: copies the backup over the file (or
    /// deletes it if it did not exist), or moves the shelved directory back.
    func revert(_ change: ConfigChange) throws {
        guard let index = entries.firstIndex(where: { $0.id == change.id }),
              !entries[index].isReverted
        else { return }

        let fileManager = FileManager.default
        switch change.kind {
        case .fileEdit:
            if let backupPath = change.backupPath {
                let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
                try data.write(to: URL(fileURLWithPath: change.path), options: .atomic)
            } else {
                try? fileManager.removeItem(atPath: change.path)
            }
        case .directoryMove:
            guard let shelved = change.backupPath else { return }
            try fileManager.moveItem(
                at: URL(fileURLWithPath: shelved),
                to: URL(fileURLWithPath: change.path)
            )
        case .pathAdd:
            // Symlinks must be removed as such, never followed.
            let url = URL(fileURLWithPath: change.path)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                || fileManager.fileExists(atPath: change.path) {
                try fileManager.removeItem(at: url)
            }
        }

        entries[index].isReverted = true
        persist()
    }

    // MARK: - Persistence

    private func ensureDirectories() throws {
        for dir in [directory, backupsDirectory, shelfDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func append(_ change: ConfigChange) {
        entries.append(change)
        persist()
    }

    private func persist() {
        let lines = entries.compactMap { change -> String? in
            guard let data = try? Self.encoder.encode(change) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? ensureDirectories()
        try? lines.joined(separator: "\n").appending("\n")
            .write(to: journalFile, atomically: true, encoding: .utf8)
    }

    private func load() {
        guard let text = try? String(contentsOf: journalFile, encoding: .utf8) else { return }
        entries = text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? Self.decoder.decode(ConfigChange.self, from: data)
        }
    }
}
