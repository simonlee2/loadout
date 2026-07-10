import Foundation

/// A config write that cannot be performed safely (unsupported scope,
/// unparseable existing config, …). Never indicates partial writes.
struct ConfigWriteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Write-side driver for Claude Code.
///
/// User skills toggle via `skillOverrides` in `<root>/settings.json`
/// (`"off"` disables; enabling removes the entry). Plugin skills toggle the
/// whole plugin via `enabledPlugins`. Edits are surgical at the structure
/// level: only the relevant key changes, every other key round-trips
/// (formatting is normalized to pretty-printed, sorted-keys JSON).
@MainActor
struct ClaudeCodeConfigWriter: AgentConfigWriter {
    let agent: AgentID = .claudeCode

    let root: URL

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    ) {
        self.root = root
    }

    private var settingsFile: URL {
        root.appendingPathComponent("settings.json", isDirectory: false)
    }

    func canToggle(_ installation: SkillInstallation) -> Bool {
        switch installation.origin {
        case .user, .plugin: true
        case .system, .project: false
        }
    }

    func canUninstall(_ installation: SkillInstallation) -> Bool {
        installation.origin == .user
    }

    func toggleScope(_ installation: SkillInstallation) -> ToggleScope {
        if case .plugin(let name) = installation.origin {
            return .plugin(name: name)
        }
        return .skill
    }

    @discardableResult
    func setSkillEnabled(
        _ installation: SkillInstallation,
        enabled: Bool,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        switch installation.origin {
        case .user:
            return try setUserSkill(installation, enabled: enabled, journal: journal)
        case .plugin(let name):
            return try setPlugin(name, enabled: enabled, journal: journal)
        case .project(let path):
            throw ConfigWriteError(message: """
                “\(installation.slug)” is a project skill of \(path); Claude Code has no \
                per-machine switch for project skills, so Loadout cannot toggle it in M1.
                """)
        case .system:
            throw ConfigWriteError(
                message: "“\(installation.slug)” is system-managed; Loadout cannot toggle it."
            )
        }
    }

    @discardableResult
    func uninstall(
        _ installation: SkillInstallation,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        guard canUninstall(installation) else {
            throw ConfigWriteError(message: """
                Only user-scope Claude Code skills can be uninstalled; \
                “\(installation.slug)” is \(installation.origin.label.lowercased())-scope.
                """)
        }

        let change = try journal.recordDirectoryMove(
            agent: agent,
            summary: "Move \(installation.slug) to the shelf for Claude Code",
            directory: installation.directory
        )

        // Drop a stale skillOverrides entry so a future reinstall starts
        // enabled. Skipped when there is no entry (or no parseable settings).
        if var settings = try? readSettings(),
           var overrides = settings["skillOverrides"] as? [String: Any],
           overrides[installation.slug] != nil {
            overrides.removeValue(forKey: installation.slug)
            if overrides.isEmpty {
                settings.removeValue(forKey: "skillOverrides")
            } else {
                settings["skillOverrides"] = overrides
            }
            try writeSettings(
                settings,
                summary: "Remove stale skillOverrides entry for \(installation.slug)",
                journal: journal
            )
        }

        return change
    }

    // MARK: - Edits

    private func setUserSkill(
        _ installation: SkillInstallation,
        enabled: Bool,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        var settings = try readSettings()
        var overrides = settings["skillOverrides"] as? [String: Any] ?? [:]
        if enabled {
            overrides.removeValue(forKey: installation.slug)
        } else {
            overrides[installation.slug] = "off"
        }
        if overrides.isEmpty {
            settings.removeValue(forKey: "skillOverrides")
        } else {
            settings["skillOverrides"] = overrides
        }

        return try writeSettings(
            settings,
            summary: "\(enabled ? "Enable" : "Disable") \(installation.slug) for Claude Code",
            journal: journal
        )
    }

    private func setPlugin(
        _ name: String,
        enabled: Bool,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        var settings = try readSettings()
        var plugins = settings["enabledPlugins"] as? [String: Any] ?? [:]
        plugins[name] = enabled
        settings["enabledPlugins"] = plugins

        let count = pluginSkillCount(name)
        let suffix = count > 0 ? " (\(count) skill\(count == 1 ? "" : "s"))" : ""
        return try writeSettings(
            settings,
            summary: "\(enabled ? "Enable" : "Disable") plugin \(name)\(suffix)",
            journal: journal
        )
    }

    // MARK: - settings.json I/O

    /// Parses `settings.json` as a top-level object. A missing file is an
    /// empty object; an unparseable one throws (never clobber user config).
    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else {
            return [:]
        }
        let data = try Data(contentsOf: settingsFile)
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            throw ConfigWriteError(
                message: "\(settingsFile.path) is not valid JSON; refusing to overwrite it."
            )
        }
        return dictionary
    }

    /// Journals a backup, then atomically writes the mutated settings.
    @discardableResult
    private func writeSettings(
        _ settings: [String: Any],
        summary: String,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        let change = try journal.recordFileEdit(agent: agent, summary: summary, file: settingsFile)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: settingsFile, options: .atomic)
        } catch {
            try? journal.revert(change)
            throw error
        }
        return change
    }

    /// Number of skills the named plugin ships, for toggle summaries.
    private func pluginSkillCount(_ name: String) -> Int {
        let manifest = root
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("installed_plugins.json", isDirectory: false)
        guard
            let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plugins = object["plugins"] as? [String: Any],
            let entries = plugins[name] as? [[String: Any]]
        else {
            return 0
        }

        var count = 0
        for entry in entries {
            guard let installPath = entry["installPath"] as? String else { continue }
            let skillsDir = URL(fileURLWithPath: installPath, isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
            count += SkillScan.installations(in: skillsDir).count
        }
        return count
    }
}
