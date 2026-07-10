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
}
