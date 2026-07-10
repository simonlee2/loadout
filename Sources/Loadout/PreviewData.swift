import Foundation

/// A stand-in `AgentScanner` that emits realistic sample installations so the UI
/// runs with data before the real scanners land. One instance per agent.
///
/// Note: the sample directories generally won't exist on disk, so the detail
/// pane's SKILL.md read will simply report the file as unreadable for those —
/// which is the correct read-only behavior. Where a real `~/.claude/skills`
/// entry happens to exist, the body renders live.
struct SampleScanner: AgentScanner {
    let agent: AgentID

    func scan() throws -> [SkillInstallation] {
        switch agent {
        case .claudeCode:
            return Self.claudeCodeInstallations
        case .codex:
            return Self.codexInstallations
        }
    }

    // MARK: Path helpers

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private static func dir(_ components: String...) -> URL {
        components.reduce(home) { $0.appendingPathComponent($1) }
    }

    private static func modified(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
    }

    // MARK: Sample data

    private static let claudeCodeInstallations: [SkillInstallation] = [
        SkillInstallation(
            agent: .claudeCode,
            slug: "swiftui-patterns",
            origin: .user,
            directory: dir(".claude", "skills", "swiftui-patterns"),
            metadata: SkillMetadata(
                name: "SwiftUI Patterns",
                description: "Build macOS SwiftUI scenes and components with desktop patterns.",
                extra: ["version": "1.4.0", "author": "cardinalblue", "license": "MIT"]
            ),
            isEnabled: true,
            lastModified: modified(daysAgo: 2)
        ),
        SkillInstallation(
            agent: .claudeCode,
            slug: "code-review",
            origin: .user,
            directory: dir(".claude", "skills", "code-review"),
            metadata: SkillMetadata(
                name: "Code Review",
                description: "Review the current diff for correctness bugs and cleanups.",
                extra: ["version": "2.0.1"]
            ),
            isEnabled: true,
            lastModified: modified(daysAgo: 5)
        ),
        SkillInstallation(
            agent: .claudeCode,
            slug: "imagegen",
            origin: .plugin(name: "warp@claude-code-warp"),
            directory: dir(".claude", "plugins", "warp@claude-code-warp", "skills", "imagegen"),
            metadata: SkillMetadata(
                name: "Image Generation",
                description: "Generate images from natural-language prompts.",
                extra: ["version": "0.9.0", "provider": "nanobanana"]
            ),
            isEnabled: true,
            lastModified: modified(daysAgo: 12)
        ),
        SkillInstallation(
            agent: .claudeCode,
            slug: "deep-research",
            origin: .system,
            directory: URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/skills/deep-research"),
            metadata: SkillMetadata(
                name: "Deep Research",
                description: "Fan-out web searches, verify claims, synthesize a cited report.",
                extra: ["version": "3.1.0"]
            ),
            isEnabled: false,
            lastModified: modified(daysAgo: 30)
        ),
        SkillInstallation(
            agent: .claudeCode,
            slug: "deploy-helper",
            origin: .project(path: "/Users/simon/Projects/Loadout"),
            directory: URL(fileURLWithPath: "/Users/simon/Projects/Loadout/.claude/skills/deploy-helper"),
            metadata: SkillMetadata(
                name: "Deploy Helper",
                description: "Project-scoped deploy and release automation.",
                extra: ["scope": "project"]
            ),
            isEnabled: true,
            lastModified: modified(daysAgo: 1)
        ),
    ]

    private static let codexInstallations: [SkillInstallation] = [
        SkillInstallation(
            agent: .codex,
            slug: "swiftui-patterns",
            origin: .user,
            directory: dir(".codex", "skills", "swiftui-patterns"),
            metadata: SkillMetadata(
                name: "SwiftUI Patterns",
                description: "Build macOS SwiftUI scenes and components with desktop patterns.",
                extra: ["version": "1.3.0"]
            ),
            isEnabled: true,
            lastModified: modified(daysAgo: 8)
        ),
        SkillInstallation(
            agent: .codex,
            slug: "code-review",
            origin: .user,
            directory: dir(".codex", "skills", "code-review"),
            metadata: SkillMetadata(
                name: "Code Review",
                description: "Review the current diff for correctness bugs and cleanups.",
                extra: ["version": "2.0.1"]
            ),
            isEnabled: false,
            lastModified: modified(daysAgo: 20)
        ),
        SkillInstallation(
            agent: .codex,
            slug: "imagegen",
            origin: .plugin(name: "warp@claude-code-warp"),
            directory: dir(".codex", "plugins", "warp@claude-code-warp", "skills", "imagegen"),
            metadata: SkillMetadata(
                name: "Image Generation",
                description: "Generate images from natural-language prompts.",
                extra: ["version": "0.9.0"]
            ),
            isEnabled: true,
            lastModified: modified(daysAgo: 12)
        ),
        SkillInstallation(
            agent: .codex,
            slug: "deep-research",
            origin: .user,
            directory: dir(".codex", "skills", "deep-research"),
            metadata: SkillMetadata(
                name: "Deep Research",
                description: "Fan-out web searches, verify claims, synthesize a cited report.",
                extra: ["version": "3.0.0"]
            ),
            isEnabled: true,
            lastModified: modified(daysAgo: 4)
        ),
        SkillInstallation(
            agent: .codex,
            slug: "markdown-lint",
            origin: .system,
            directory: URL(fileURLWithPath: "/Library/Application Support/Codex/skills/markdown-lint"),
            metadata: SkillMetadata(
                name: "Markdown Lint",
                description: "Lint and normalize Markdown documents.",
                extra: ["version": "1.0.0"]
            ),
            isEnabled: false,
            lastModified: modified(daysAgo: 45)
        ),
    ]
}
