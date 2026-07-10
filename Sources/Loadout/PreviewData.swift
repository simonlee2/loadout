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

    /// Shared with `PreviewProjectOverrides`, which presents these same
    /// installations as seen from inside a sample project.
    static let claudeCodeInstallations: [SkillInstallation] = [
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

// MARK: - Project previews

/// In-memory `ProjectOverriding` for sample mode (`LOADOUT_SAMPLE`): two fake
/// projects whose skill states mix a project-level "off", a project-level "on"
/// that overrides a user-level "off", and plain default-enabled skills.
/// `setSkill` mutates only this object — nothing is written to disk.
@MainActor
final class PreviewProjectOverrides: ProjectOverriding {
    private let sampleProjects = [
        ProjectRef(path: "/Users/simon/Projects/Loadout"),
        ProjectRef(path: "/Users/simon/Projects/PicCollage"),
    ]

    /// project path → slug → override. Absent slugs are default-enabled.
    private var overrides: [String: [String: (enabled: Bool, source: ProjectOverrideSource)]] = [
        "/Users/simon/Projects/Loadout": [
            // Off in this project (project-local override).
            "swiftui-patterns": (enabled: false, source: .projectLocal),
            // On here even though the user-scope copy is disabled.
            "deep-research": (enabled: true, source: .projectLocal),
        ],
        "/Users/simon/Projects/PicCollage": [
            // Off because the user's own settings disable it.
            "imagegen": (enabled: false, source: .user),
        ],
    ]

    func projects() throws -> [ProjectRef] {
        sampleProjects
    }

    func skillStates(in project: ProjectRef) throws -> [ProjectSkillState] {
        SampleScanner.claudeCodeInstallations.map { installation in
            guard let override = overrides[project.path]?[installation.slug] else {
                return ProjectSkillState(
                    installation: installation,
                    isEnabledInProject: true,
                    source: nil
                )
            }
            return ProjectSkillState(
                installation: installation,
                isEnabledInProject: override.enabled,
                source: override.source
            )
        }
    }

    @discardableResult
    func setSkill(
        _ slug: String,
        enabled: Bool,
        in project: ProjectRef,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        overrides[project.path, default: [:]][slug] = (enabled: enabled, source: .projectLocal)
        // Fabricated, un-journaled change so sample mode never touches disk.
        return ConfigChange(
            id: UUID(),
            date: Date(),
            agent: .claudeCode,
            kind: .fileEdit,
            summary: "\(enabled ? "Enable" : "Disable") \(slug) in \(project.name) (preview)",
            path: "\(project.path)/.claude/settings.local.json",
            backupPath: nil,
            isReverted: false
        )
    }
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

    /// Fabricates a realistic staged update (three file changes incl. a
    /// multi-line diff) so sample mode can demo the whole review sheet. The
    /// staging directory is a temp URL that is never actually created on disk.
    func stageUpdate(
        slug: String,
        using adapter: any RegistryAdapter
    ) async throws -> StagedUpdate {
        try await Task.sleep(for: .milliseconds(600))
        let entry = lockEntries.first { $0.slug == slug } ?? LockEntry(
            slug: slug, registry: "skills.sh", identifier: slug, version: "0",
            contentHash: "preview", fetchedAt: Date(), deployments: []
        )
        let latest = (try? await adapter.latestVersion(for: entry)).flatMap { $0 } ?? entry.version
        return Self.sampleStagedUpdate(slug: slug, newVersion: latest)
    }

    /// A realistic three-file staged update used by `stageUpdate` and, for the
    /// offscreen snapshot harness, directly by the review overlay. The staging
    /// directory is a temp URL that is never created on disk.
    static func sampleStagedUpdate(slug: String, newVersion: String) -> StagedUpdate {
        let changes: [FileChange] = [
            FileChange(
                relativePath: "SKILL.md",
                kind: .modified,
                diff: [
                    "  # Code Review",
                    "  ",
                    "- Review the current diff for correctness bugs.",
                    "+ Review the current diff for correctness bugs and",
                    "+ reuse/simplification/efficiency cleanups.",
                    "  ",
                    "  ## Usage",
                    "- Run `/code-review` on your working tree.",
                    "+ Run `/code-review` on your working tree, or pass",
                    "+ `--fix` to apply findings automatically.",
                ]
            ),
            FileChange(
                relativePath: "references/checklist.md",
                kind: .added,
                diff: [
                    "+ # Review checklist",
                    "+ ",
                    "+ - Correctness and edge cases",
                    "+ - Reuse and simplification",
                    "+ - Efficiency",
                ]
            ),
            FileChange(
                relativePath: "assets/diagram.png",
                kind: .removed,
                diff: []
            ),
        ]
        return StagedUpdate(
            slug: slug,
            newVersion: newVersion,
            stagingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("loadout-preview-\(slug)-\(UUID().uuidString)"),
            changes: changes
        )
    }

    /// Applies the update in memory only: bumps the lock entry's version and
    /// content hash, touching nothing on disk.
    func applyUpdate(_ staged: StagedUpdate, journal: ChangeJournal) async throws {
        try await Task.sleep(for: .milliseconds(400))
        guard let index = lockEntries.firstIndex(where: { $0.slug == staged.slug }) else { return }
        let old = lockEntries[index]
        lockEntries[index] = LockEntry(
            slug: old.slug,
            registry: old.registry,
            identifier: old.identifier,
            version: staged.newVersion,
            contentHash: "preview-updated",
            fetchedAt: Date(),
            deployments: old.deployments
        )
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
