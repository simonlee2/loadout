import Foundation
import Observation

/// The user's own project-list choices: hidden auto-detected projects,
/// manually added folders, and whether hidden ones are shown. Stored in
/// Loadout's Application Support (never in any agent config).
@MainActor
@Observable
final class ProjectPreferences {
    private(set) var hidden: Set<String> = []
    private(set) var added: [String] = []
    var showHidden: Bool = false {
        didSet { save() }
    }

    private let file: URL

    init(
        file: URL = URL.applicationSupportDirectory
            .appendingPathComponent("Loadout", isDirectory: true)
            .appendingPathComponent("projects.json", isDirectory: false)
    ) {
        self.file = file
        load()
    }

    func hide(_ path: String) {
        hidden.insert(path)
        save()
    }

    func unhide(_ path: String) {
        hidden.remove(path)
        save()
    }

    func add(_ path: String) {
        guard !added.contains(path) else { return }
        added.append(path)
        save()
    }

    func removeAdded(_ path: String) {
        added.removeAll { $0 == path }
        save()
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var hidden: [String] = []
        var added: [String] = []
        var showHidden: Bool = false
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        hidden = Set(stored.hidden)
        added = stored.added
        // Assign the backing storage without re-triggering save().
        _showHidden = stored.showHidden
    }

    private func save() {
        let stored = Stored(hidden: hidden.sorted(), added: added, showHidden: showHidden)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
