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

// MARK: - Registry previews

/// Stand-in `RegistryAdapter` so the registry browser runs before the real
/// network-backed `SkillsShAdapter` lands. `featured()` returns a small curated
/// list; `search` filters it; `fetch` refuses (the browser never calls it —
/// installs go through `PreviewLibrary`).
struct PreviewRegistryAdapter: RegistryAdapter {
    let id = "skills.sh"
    let displayName = "skills.sh"

    private static let catalog: [RegistrySkill] = [
        RegistrySkill(
            registry: "skills.sh",
            identifier: "anthropics/skills/deep-research",
            slug: "deep-research",
            name: "Deep Research",
            summary: "Fan-out web searches, verify claims, synthesize a cited report.",
            version: "3.1.0",
            installCount: 12_400,
            sourceURL: URL(string: "https://skills.sh/anthropics/skills/deep-research"),
            audit: .passed
        ),
        RegistrySkill(
            registry: "skills.sh",
            identifier: "cardinalblue/skills/code-review",
            slug: "code-review",
            name: "Code Review",
            summary: "Review the current diff for correctness bugs and cleanups.",
            version: "2.0.1",
            installCount: 8_930,
            sourceURL: URL(string: "https://skills.sh/cardinalblue/skills/code-review"),
            audit: .passed
        ),
        RegistrySkill(
            registry: "skills.sh",
            identifier: "community/skills/markdown-lint",
            slug: "markdown-lint",
            name: "Markdown Lint",
            summary: "Lint and normalize Markdown documents.",
            version: "1.0.0",
            installCount: 640,
            sourceURL: URL(string: "https://skills.sh/community/skills/markdown-lint"),
            audit: .flagged
        ),
    ]

    func featured() async throws -> [RegistrySkill] {
        Self.catalog
    }

    func search(_ query: String) async throws -> [RegistrySkill] {
        let needle = query.lowercased()
        return Self.catalog.filter { skill in
            skill.name.lowercased().contains(needle)
                || skill.slug.lowercased().contains(needle)
                || (skill.summary?.lowercased().contains(needle) ?? false)
        }
    }

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        throw PreviewError.notImplemented
    }

    /// Reports a newer version for "code-review" so `checkForUpdates()`
    /// populates one update badge in sample mode; every other managed entry is
    /// already current.
    func latestVersion(for entry: LockEntry) async throws -> String? {
        entry.slug == "code-review" ? "2.1.0" : entry.version
    }

    enum PreviewError: LocalizedError {
        case notImplemented
        var errorDescription: String? { "preview" }
    }
}

/// In-memory `SkillInstalling`: records installs as `LockEntry` values after a
/// 1s delay so the install spinner is visible. Never touches disk.
@MainActor
final class PreviewLibrary: SkillInstalling {
    /// Two pre-adopted skills so sample mode shows a "Managed" chip
    /// (swiftui-patterns, current) and — once `checkForUpdates()` runs — an
    /// "Update" chip (code-review, whose adapter reports a newer version).
    private(set) var lockEntries: [LockEntry] = [
        LockEntry(
            slug: "swiftui-patterns",
            registry: "skills.sh",
            identifier: "cardinalblue/skills/swiftui-patterns",
            version: "1.4.0",
            contentHash: "preview",
            fetchedAt: Date(),
            deployments: AgentID.allCases.map {
                Deployment(agent: $0, path: "/preview/\($0.rawValue)/swiftui-patterns", kind: .symlink)
            }
        ),
        LockEntry(
            slug: "code-review",
            registry: "skills.sh",
            identifier: "cardinalblue/skills/code-review",
            version: "2.0.1",
            contentHash: "preview",
            fetchedAt: Date(),
            deployments: AgentID.allCases.map {
                Deployment(agent: $0, path: "/preview/\($0.rawValue)/code-review", kind: .symlink)
            }
        ),
    ]

    func install(
        _ skill: RegistrySkill,
        using adapter: any RegistryAdapter,
        to agents: [AgentID],
        journal: ChangeJournal
    ) async throws {
        try await Task.sleep(for: .seconds(1))
        let entry = LockEntry(
            slug: skill.slug,
            registry: skill.registry,
            identifier: skill.identifier,
            version: skill.version ?? "preview",
            contentHash: "preview",
            fetchedAt: Date(),
            deployments: agents.map { agent in
                Deployment(agent: agent, path: "/preview/\(agent.rawValue)/\(skill.slug)", kind: .symlink)
            }
        )
        lockEntries.append(entry)
    }

    func remove(slug: String, journal: ChangeJournal) async throws {
        lockEntries.removeAll { $0.slug == slug }
    }

    func adopt(
        _ installation: SkillInstallation,
        syncTo agents: [AgentID],
        journal: ChangeJournal
    ) async throws {
        try await Task.sleep(for: .seconds(1))
        let targets = ([installation.agent] + agents)
        let entry = LockEntry(
            slug: installation.slug,
            registry: "local",
            identifier: installation.slug,
            version: "adopted",
            contentHash: "preview",
            fetchedAt: Date(),
            deployments: targets.map {
                Deployment(agent: $0, path: "/preview/\($0.rawValue)/\(installation.slug)", kind: .symlink)
            }
        )
        lockEntries.append(entry)
    }
}
