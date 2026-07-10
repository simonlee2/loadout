import Foundation

/// How a journaled change mutated the filesystem — determines how it is
/// reverted (restore a file backup vs. move a directory back).
enum ChangeKind: String, Codable, Sendable {
    case fileEdit
    case directoryMove
    /// A directory, file, or symlink Loadout created (e.g. a registry
    /// install deployment). Revert deletes it.
    case pathAdd
}

/// One reversible, journaled change to an agent-owned file or skill
/// directory. Every write Loadout performs produces exactly one of these.
struct ConfigChange: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let date: Date
    let agent: AgentID
    let kind: ChangeKind
    /// Human-readable, e.g. "Disable swiftui-patterns for Claude Code".
    let summary: String
    /// The edited file (`fileEdit`) or the directory's original location
    /// (`directoryMove`).
    let path: String
    /// Pre-change copy of the file (`fileEdit`; nil when the file did not
    /// exist yet) or where the directory was moved to (`directoryMove`).
    let backupPath: String?
    var isReverted: Bool
}

/// What a toggle actually flips: the one skill, or a whole plugin that
/// gates it (and therefore its sibling skills). UI uses this to confirm
/// before wide-scope toggles.
enum ToggleScope: Hashable, Sendable {
    case skill
    case plugin(name: String)
}

/// Write-side counterpart of `AgentScanner`: drives one agent's real
/// enable/disable mechanism. Implementations must be surgical (preserve
/// every unrelated byte where the format allows), atomic, and must record
/// a journal backup before the first mutation of any file.
@MainActor
protocol AgentConfigWriter {
    var agent: AgentID { get }

    /// False when the agent has no mechanism for this installation
    /// (e.g. Claude Code project-scope skills in M1).
    func canToggle(_ installation: SkillInstallation) -> Bool

    /// Uninstall support (move-to-shelf); user-scope skills only.
    func canUninstall(_ installation: SkillInstallation) -> Bool

    func toggleScope(_ installation: SkillInstallation) -> ToggleScope

    @discardableResult
    func setSkillEnabled(
        _ installation: SkillInstallation,
        enabled: Bool,
        journal: ChangeJournal
    ) throws -> ConfigChange

    /// Moves the skill directory to the journal's shelf so the change is
    /// fully reversible.
    @discardableResult
    func uninstall(
        _ installation: SkillInstallation,
        journal: ChangeJournal
    ) throws -> ConfigChange
}
