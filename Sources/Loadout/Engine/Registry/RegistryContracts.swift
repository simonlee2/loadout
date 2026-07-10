import Foundation

/// Security-audit signal a registry exposes for a skill, when it has one.
enum AuditStatus: String, Codable, Sendable {
    case passed
    case flagged
    case unknown
}

/// One skill as listed by a registry, before installation.
struct RegistrySkill: Identifiable, Hashable, Sendable {
    /// Adapter id this came from, e.g. "skills.sh".
    let registry: String
    /// Registry-native identifier, e.g. "owner/repo/skill-name".
    let identifier: String
    /// Canonical directory name the skill installs as.
    let slug: String
    let name: String
    let summary: String?
    /// Registry-reported version, tag, or commit — nil when unversioned.
    let version: String?
    let installCount: Int?
    let sourceURL: URL?
    let audit: AuditStatus?

    var id: String { "\(registry):\(identifier)" }
}

/// One skill registry. Implementations are network-backed and must never
/// write outside the destination directory handed to `fetch`.
protocol RegistryAdapter: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Default browse content (leaderboard, curated list…). Empty when the
    /// registry has no such concept.
    func featured() async throws -> [RegistrySkill]

    func search(_ query: String) async throws -> [RegistrySkill]

    /// Downloads the skill's file tree into `destination` (an existing empty
    /// directory). Returns the resolved version (tag, semver, or commit SHA)
    /// for the provenance record.
    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String

    /// The registry's current version for an installed entry, or nil when
    /// the registry can't answer cheaply. Compared against
    /// `LockEntry.version` for update badges.
    func latestVersion(for entry: LockEntry) async throws -> String?
}

extension RegistryAdapter {
    func latestVersion(for entry: LockEntry) async throws -> String? { nil }
}

/// Where an installed library skill is deployed for one agent.
struct Deployment: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case symlink
        case copy
    }
    let agent: AgentID
    let path: String
    let kind: Kind
}

/// Provenance record for one library-managed skill — what makes updates
/// and drift detection answerable (decision D4).
struct LockEntry: Codable, Hashable, Sendable, Identifiable {
    let slug: String
    let registry: String
    let identifier: String
    let version: String
    /// SHA-256 over the skill's file tree (sorted relative paths + contents).
    let contentHash: String
    let fetchedAt: Date
    var deployments: [Deployment]

    var id: String { slug }
}

/// The canonical library: one copy per managed skill plus the lockfile.
/// Deployments into agent skill directories are symlinks (D2, spike-verified)
/// and every filesystem mutation is journaled.
@MainActor
protocol SkillInstalling {
    var lockEntries: [LockEntry] { get }

    func install(
        _ skill: RegistrySkill,
        using adapter: any RegistryAdapter,
        to agents: [AgentID],
        journal: ChangeJournal
    ) async throws

    /// Removes deployments and the library copy (journaled, reversible).
    func remove(slug: String, journal: ChangeJournal) async throws

    /// Adopts an existing unmanaged skill: moves it into the library and
    /// symlinks it back to its agent plus `syncTo` agents. Registry is
    /// recorded as "local". This is how pre-existing skills become
    /// cross-agent synced (D1's adopt-later, D2's sync).
    func adopt(
        _ installation: SkillInstallation,
        syncTo agents: [AgentID],
        journal: ChangeJournal
    ) async throws

    /// Downloads the upstream version into a staging dir and computes the
    /// per-file changes vs. the library copy. Applies nothing.
    /// (Must be a protocol requirement, not just an extension method —
    /// callers hold `any SkillInstalling` and need dynamic dispatch.)
    func stageUpdate(
        slug: String,
        using adapter: any RegistryAdapter
    ) async throws -> StagedUpdate

    /// Applies a staged update: shelves the current library copy (journaled,
    /// reversible), moves the staged tree in, refreshes the lock entry.
    func applyUpdate(_ staged: StagedUpdate, journal: ChangeJournal) async throws

    /// Discards a staged update's temp directory.
    func discardUpdate(_ staged: StagedUpdate)
}

extension SkillInstalling {
    func adopt(
        _ installation: SkillInstallation,
        syncTo agents: [AgentID],
        journal: ChangeJournal
    ) async throws {
        throw ConfigWriteError(message: "Adopting isn't supported by this library.")
    }
}

/// One file's change in a staged update, for the review UI.
struct FileChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case added
        case removed
        case modified
    }
    let relativePath: String
    let kind: Kind
    /// Unified-diff-style preview lines ("+ …" / "- …" / "  …"); empty for
    /// binary or oversized files.
    let diff: [String]

    var id: String { relativePath }
}

/// A downloaded-but-not-applied update, held in a temp dir until the user
/// approves it in the review sheet.
struct StagedUpdate: Sendable {
    let slug: String
    let newVersion: String
    let stagingDirectory: URL
    let changes: [FileChange]
}

extension SkillInstalling {
    /// Downloads the upstream version into a staging dir and computes the
    /// per-file changes vs. the library copy. Applies nothing.
    func stageUpdate(
        slug: String,
        using adapter: any RegistryAdapter
    ) async throws -> StagedUpdate {
        throw ConfigWriteError(message: "Updates aren't supported by this library.")
    }

    /// Applies a staged update: shelves the current library copy (journaled,
    /// reversible), moves the staged tree in, refreshes the lock entry.
    func applyUpdate(_ staged: StagedUpdate, journal: ChangeJournal) async throws {
        throw ConfigWriteError(message: "Updates aren't supported by this library.")
    }

    /// Discards a staged update's temp directory.
    func discardUpdate(_ staged: StagedUpdate) {
        try? FileManager.default.removeItem(at: staged.stagingDirectory)
    }
}
