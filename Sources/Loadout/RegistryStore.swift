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

    // MARK: - Personal collection

    private(set) var collection: (any SkillCollection)?

    var collectionAvailable: Bool { collection?.isAvailable ?? false }
    var collectionUnavailabilityReason: String? { collection?.unavailabilityReason }

    func configureCollection(_ collection: any SkillCollection) {
        self.collection = collection
    }

    func activateCollection() async {
        await collection?.activate()
    }

    /// Publishes one installed skill's files into the personal collection.
    func publishToCollection(_ installation: SkillInstallation) async {
        guard let collection else { return }
        do {
            try await collection.publish(
                slug: installation.slug,
                name: installation.displayName,
                summary: installation.metadata.description,
                directory: installation.directory
            )
        } catch {
            lastActionError = "Publish failed: \(error.localizedDescription)"
        }
    }

    /// slug → newer upstream version, from the last `checkForUpdates`.
    private(set) var updatesAvailable: [String: String] = [:]
    private(set) var isCheckingUpdates = false

    /// Compares every lock entry against its registry's current version.
    func checkForUpdates() async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        var updates: [String: String] = [:]
        for entry in library.lockEntries {
            guard let adapter = adapter(id: entry.registry) else { continue }
            if let latest = try? await adapter.latestVersion(for: entry),
               latest != entry.version {
                updates[entry.slug] = latest
            }
        }
        updatesAvailable = updates
    }

    /// Downloads an available update for review; nil (with error surfaced)
    /// on failure.
    func stageUpdate(slug: String) async -> StagedUpdate? {
        guard let entry = library.lockEntries.first(where: { $0.slug == slug }),
              let adapter = adapter(id: entry.registry) else { return nil }
        do {
            return try await library.stageUpdate(slug: slug, using: adapter)
        } catch {
            lastActionError = "Couldn't stage update: \(error.localizedDescription)"
            return nil
        }
    }

    func applyUpdate(_ staged: StagedUpdate) async {
        do {
            try await library.applyUpdate(staged, journal: journal)
            updatesAvailable.removeValue(forKey: staged.slug)
        } catch {
            lastActionError = "Couldn't apply update: \(error.localizedDescription)"
        }
    }

    func discardUpdate(_ staged: StagedUpdate) {
        library.discardUpdate(staged)
    }

    func adopt(_ installation: SkillInstallation, syncTo agents: [AgentID]) async {
        do {
            try await library.adopt(installation, syncTo: agents, journal: journal)
        } catch {
            lastActionError = "Adopt failed: \(error.localizedDescription)"
        }
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
