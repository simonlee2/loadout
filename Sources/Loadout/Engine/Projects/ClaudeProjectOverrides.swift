import Foundation

/// Reads and writes Claude Code's per-project skill overrides.
///
/// Claude Code merges `skillOverrides` from a settings hierarchy; a project
/// can disable (or re-enable) a skill just for itself. Loadout writes only the
/// PERSONAL project file (`<project>/.claude/settings.local.json`) so a
/// team-shared `settings.json` stays untouched.
///
/// Precedence (highest wins where the key EXISTS):
/// `settings.local.json` > project `settings.json` > `~/.claude/settings.json`
/// > default enabled. A value of `"off"` / `false` disables; anything else
/// (including `"on"` / `true`) enables.
@MainActor
struct ClaudeProjectOverrides: ProjectOverriding {
    let agent: AgentID = .claudeCode

    let root: URL
    let claudeJSONPath: URL
    let homeDirectory: URL

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true),
        claudeJSONPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json", isDirectory: false),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.root = root
        self.claudeJSONPath = claudeJSONPath
        self.homeDirectory = homeDirectory
    }

    // MARK: - Projects

    func projects() throws -> [ProjectRef] {
        guard
            let data = try? Data(contentsOf: claudeJSONPath),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = object["projects"] as? [String: Any]
        else {
            return []
        }

        let fileManager = FileManager.default
        let homePath = homeDirectory.standardizedFileURL.path
        var refs: [ProjectRef] = []
        for path in projects.keys {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            // The home directory's .claude/skills is the user scope, not a project.
            guard URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path != homePath
            else { continue }
            refs.append(ProjectRef(path: path))
        }
        return refs.sorted { $0.name < $1.name }
    }

    // MARK: - Skill states

    func skillStates(in project: ProjectRef) throws -> [ProjectSkillState] {
        // Reuse the scanner for discovery (user + plugin + project skills).
        let scanner = ClaudeCodeScanner(root: root, claudeJSONPath: claudeJSONPath)
        let installations = try scanner.scan()
        let projectPath = URL(fileURLWithPath: project.path, isDirectory: true)
            .standardizedFileURL.path

        let localOverrides = skillOverrides(at: settingsLocalFile(project))
        let sharedOverrides = skillOverrides(at: settingsSharedFile(project))
        let userOverrides = skillOverrides(at: userSettingsFile)

        var states: [ProjectSkillState] = []
        for installation in installations {
            // Keep user + plugin skills and the project's OWN skills only;
            // drop other tracked projects' skills (and system, defensively).
            switch installation.origin {
            case .user, .plugin:
                break
            case .project(let path):
                guard URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
                    == projectPath
                else { continue }
            case .system:
                continue
            }

            let (enabled, source) = effectiveState(
                for: installation,
                local: localOverrides,
                shared: sharedOverrides,
                user: userOverrides
            )
            states.append(ProjectSkillState(
                installation: installation,
                isEnabledInProject: enabled,
                source: source
            ))
        }
        return states
    }

    /// Merges the override hierarchy for one installation.
    private func effectiveState(
        for installation: SkillInstallation,
        local: [String: Bool],
        shared: [String: Bool],
        user: [String: Bool]
    ) -> (enabled: Bool, source: ProjectOverrideSource?) {
        // A disabled plugin gates all its skills off; that decision lives at the
        // user level (~/.claude/settings.json enabledPlugins).
        if case .plugin = installation.origin, installation.isEnabled == false {
            return (false, .user)
        }

        let slug = installation.slug
        if let enabled = local[slug] { return (enabled, .projectLocal) }
        if let enabled = shared[slug] { return (enabled, .projectShared) }
        if let enabled = user[slug] { return (enabled, .user) }
        return (true, nil)
    }

    // MARK: - Writing

    @discardableResult
    func setSkill(
        _ slug: String,
        enabled: Bool,
        in project: ProjectRef,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        let file = settingsLocalFile(project)
        var settings = try readSettings(at: file)
        var overrides = settings["skillOverrides"] as? [String: Any] ?? [:]

        if enabled {
            // Removing the local key exposes lower levels. If they still
            // disable the slug, an explicit "on" is needed to re-enable.
            if lowerLevelDisables(slug, in: project) {
                overrides[slug] = "on"
            } else {
                overrides.removeValue(forKey: slug)
            }
        } else {
            overrides[slug] = "off"
        }

        if overrides.isEmpty {
            settings.removeValue(forKey: "skillOverrides")
        } else {
            settings["skillOverrides"] = overrides
        }

        let summary = "\(enabled ? "Enable" : "Disable") \(slug) for \(project.name)"
        return try writeSettings(settings, to: file, summary: summary, journal: journal)
    }

    /// True when project-shared or user settings would leave `slug` disabled if
    /// the project-local entry were removed (precedence: shared over user).
    private func lowerLevelDisables(_ slug: String, in project: ProjectRef) -> Bool {
        let shared = skillOverrides(at: settingsSharedFile(project))
        if let enabled = shared[slug] { return !enabled }
        let user = skillOverrides(at: userSettingsFile)
        if let enabled = user[slug] { return !enabled }
        return false
    }

    // MARK: - Settings I/O

    /// Tolerant read of a file's `skillOverrides` as slug -> enabled. A missing
    /// or unparseable file (or absent key) yields no entries. Presence of a key
    /// in the result means that level explicitly set the slug.
    private func skillOverrides(at url: URL) -> [String: Bool] {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let overrides = object["skillOverrides"] as? [String: Any]
        else {
            return [:]
        }
        var result: [String: Bool] = [:]
        for (slug, value) in overrides {
            result[slug] = Self.isEnabled(value)
        }
        return result
    }

    /// Parses a settings file as a top-level object. A missing file is an empty
    /// object; an unparseable one throws (never clobber user config).
    private func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            throw ConfigWriteError(
                message: "\(url.path) is not valid JSON; refusing to overwrite it."
            )
        }
        return dictionary
    }

    /// Journals a backup (BEFORE writing), then atomically writes the mutated
    /// settings, creating the `.claude` directory if needed. Preserves every
    /// unknown key (structure-level); formatting is normalized.
    @discardableResult
    private func writeSettings(
        _ settings: [String: Any],
        to url: URL,
        summary: String,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        let change = try journal.recordFileEdit(agent: agent, summary: summary, file: url)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            try? journal.revert(change)
            throw error
        }
        return change
    }

    /// Interprets an override value: `"off"` / `false` disable, everything else
    /// (including `"on"` / `true`) enables.
    private static func isEnabled(_ value: Any) -> Bool {
        if let flag = value as? Bool { return flag }
        if let string = value as? String { return string.lowercased() != "off" }
        return true
    }

    // MARK: - Paths

    private var userSettingsFile: URL {
        root.appendingPathComponent("settings.json", isDirectory: false)
    }

    private func projectClaudeDir(_ project: ProjectRef) -> URL {
        URL(fileURLWithPath: project.path, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
    }

    private func settingsLocalFile(_ project: ProjectRef) -> URL {
        projectClaudeDir(project).appendingPathComponent("settings.local.json", isDirectory: false)
    }

    private func settingsSharedFile(_ project: ProjectRef) -> URL {
        projectClaudeDir(project).appendingPathComponent("settings.json", isDirectory: false)
    }
}
