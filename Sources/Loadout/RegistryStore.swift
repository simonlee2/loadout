import Foundation
import Observation

/// Observable source of truth for registry browsing and installs. Owns the
/// adapters and the library; the inventory store remains the truth for what
/// is installed on the agents themselves.
@MainActor
@Observable
final class RegistryStore {
    struct BrowseState {
        var skills: [RegistrySkill] = []
        var isLoading = false
        var error: String?
        /// The query the current `skills` answer; nil = featured content.
        var query: String?
    }

    private(set) var browse: [String: BrowseState] = [:]
    var lastActionError: String?
    private(set) var installing: Set<String> = []

    let adapters: [any RegistryAdapter]
    private let library: any SkillInstalling
    private let journal: ChangeJournal

    init(adapters: [any RegistryAdapter], library: any SkillInstalling, journal: ChangeJournal) {
        self.adapters = adapters
        self.library = library
        self.journal = journal
    }

    var lockEntries: [LockEntry] { library.lockEntries }

    func adapter(id: String) -> (any RegistryAdapter)? {
        adapters.first { $0.id == id }
    }

    func isInstalled(_ skill: RegistrySkill) -> Bool {
        library.lockEntries.contains { $0.slug == skill.slug }
    }

    func isInstalling(_ skill: RegistrySkill) -> Bool {
        installing.contains(skill.id)
    }

    /// Loads featured content for a registry unless it is already showing.
    func loadFeatured(registry id: String) async {
        guard let adapter = adapter(id: id) else { return }
        if let state = browse[id], state.query == nil, !state.skills.isEmpty { return }
        await run(adapter, query: nil) { try await adapter.featured() }
    }

    func search(_ query: String, registry id: String) async {
        guard let adapter = adapter(id: id) else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            browse[id] = BrowseState()
            await loadFeatured(registry: id)
            return
        }
        await run(adapter, query: trimmed) { try await adapter.search(trimmed) }
    }

    func install(_ skill: RegistrySkill, to agents: [AgentID]) async {
        guard let adapter = adapter(id: skill.registry) else { return }
        installing.insert(skill.id)
        defer { installing.remove(skill.id) }
        do {
            try await library.install(skill, using: adapter, to: agents, journal: journal)
        } catch {
            lastActionError = "Install failed: \(error.localizedDescription)"
        }
    }

    private func run(
        _ adapter: any RegistryAdapter,
        query: String?,
        _ operation: () async throws -> [RegistrySkill]
    ) async {
        var state = browse[adapter.id] ?? BrowseState()
        state.isLoading = true
        state.error = nil
        state.query = query
        browse[adapter.id] = state
        do {
            state.skills = try await operation()
        } catch {
            state.error = error.localizedDescription
        }
        state.isLoading = false
        browse[adapter.id] = state
    }
}
