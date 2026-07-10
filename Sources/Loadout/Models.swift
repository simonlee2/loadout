import Foundation

/// A coding agent whose skills Loadout can inventory.
enum AgentID: String, CaseIterable, Identifiable, Codable, Sendable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        }
    }
}

/// Parsed SKILL.md YAML frontmatter. `name` and `description` are the
/// spec-required keys; everything else lands in `extra`.
struct SkillMetadata: Hashable, Sendable {
    var name: String?
    var description: String?
    var extra: [String: String] = [:]
}

/// Where a skill installation lives within an agent's world.
enum SkillOrigin: Hashable, Sendable {
    case user
    case system
    case plugin(name: String)
    case project(path: String)

    var label: String {
        switch self {
        case .user: "User"
        case .system: "System"
        case .plugin(let name): "Plugin · \(name)"
        case .project(let path): "Project · \((path as NSString).lastPathComponent)"
        }
    }
}

/// One skill directory as installed for one agent. Identity is the
/// on-disk path, which is unique per installation.
struct SkillInstallation: Identifiable, Hashable, Sendable {
    let agent: AgentID
    /// Directory name of the skill (the canonical cross-agent join key).
    let slug: String
    let origin: SkillOrigin
    let directory: URL
    let metadata: SkillMetadata
    /// False when the agent's own config disables it (Claude `skillOverrides`,
    /// Codex `[[skills.config]] enabled = false`).
    let isEnabled: Bool
    let lastModified: Date?

    var id: String { directory.path }

    var displayName: String { metadata.name ?? slug }
}

/// One row of the inventory matrix: the same skill slug across agents.
struct SkillRow: Identifiable, Sendable {
    let slug: String
    var installations: [SkillInstallation]

    var id: String { slug }

    var displayName: String {
        installations.first?.displayName ?? slug
    }

    var summary: String? {
        installations.compactMap(\.metadata.description).first
    }

    func installation(for agent: AgentID) -> SkillInstallation? {
        installations.first { $0.agent == agent }
    }
}

/// Read-only scanner for one agent. Implementations must not write
/// anything to disk (M0 is strictly read-only).
protocol AgentScanner: Sendable {
    var agent: AgentID { get }
    func scan() throws -> [SkillInstallation]
}
