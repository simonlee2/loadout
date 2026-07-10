import Foundation

/// A project directory Claude Code has been used in (tracked in ~/.claude.json).
struct ProjectRef: Identifiable, Hashable, Sendable {
    let path: String

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Where a skill's per-project on/off decision came from.
enum ProjectOverrideSource: String, Sendable {
    case projectLocal    // <project>/.claude/settings.local.json (highest)
    case projectShared   // <project>/.claude/settings.json
    case user            // ~/.claude/settings.json (lowest)
}

/// One skill as seen from inside a project: the underlying installation plus
/// the merged, project-effective enablement.
struct ProjectSkillState: Identifiable, Sendable {
    let installation: SkillInstallation
    let isEnabledInProject: Bool
    /// nil when no level overrides it (default: enabled).
    let source: ProjectOverrideSource?

    var id: String { installation.id }
}

/// Reads and writes Claude Code's per-project skill overrides.
/// Writes go to the project's personal settings file
/// (`.claude/settings.local.json`) so team-shared settings stay untouched.
@MainActor
protocol ProjectOverriding {
    /// Tracked projects that exist on disk, excluding the home directory
    /// (whose ".claude/skills" is the user scope).
    func projects() throws -> [ProjectRef]

    /// Every skill Claude Code can see inside the project (user + plugin +
    /// the project's own), with project-effective enablement.
    func skillStates(in project: ProjectRef) throws -> [ProjectSkillState]

    @discardableResult
    func setSkill(
        _ slug: String,
        enabled: Bool,
        in project: ProjectRef,
        journal: ChangeJournal
    ) throws -> ConfigChange
}
