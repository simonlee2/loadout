import Foundation
import Observation

/// User-added git registries (company or personal skill repos). Stored in
/// Loadout's Application Support so no repo URL ever lives in the code.
@MainActor
@Observable
final class RegistryPreferences {
    struct Entry: Codable, Hashable, Sendable {
        var name: String
        var url: String
    }

    private(set) var entries: [Entry] = []

    private let file: URL

    init(
        file: URL = URL.applicationSupportDirectory
            .appendingPathComponent("Loadout", isDirectory: true)
            .appendingPathComponent("registries.json", isDirectory: false)
    ) {
        self.file = file
        load()
    }

    func add(name: String, url: String) {
        guard !entries.contains(where: { $0.url == url }) else { return }
        entries.append(Entry(name: name, url: url))
        save()
    }

    func remove(url: String) {
        entries.removeAll { $0.url == url }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = stored
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
