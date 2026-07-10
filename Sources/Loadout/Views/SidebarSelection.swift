import Foundation

/// The kind of origin, collapsed for grouping in the sidebar's Library section.
/// (A `SkillOrigin.plugin`/`.project` carries an associated value; this is the
/// bucket it lands in.)
enum OriginKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case user
    case system
    case plugin
    case project

    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: "User"
        case .system: "System"
        case .plugin: "Plugins"
        case .project: "Projects"
        }
    }

    var symbol: String {
        switch self {
        case .user: "person"
        case .system: "gearshape"
        case .plugin: "puzzlepiece.extension"
        case .project: "folder"
        }
    }
}

extension SkillOrigin {
    var kind: OriginKind {
        switch self {
        case .user: .user
        case .system: .system
        case .plugin: .plugin
        case .project: .project
        }
    }
}

extension AgentID {
    /// SF Symbol used for this agent in the sidebar and matrix columns.
    var symbol: String {
        switch self {
        case .claudeCode: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// What the sidebar has selected. Drives the matrix filter.
enum SidebarSelection: Hashable {
    case allSkills
    case origin(OriginKind)
    case agent(AgentID)
}
