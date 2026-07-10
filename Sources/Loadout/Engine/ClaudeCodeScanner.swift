import Foundation

/// Read-only scanner for Claude Code skill installations.
///
/// Discovers user, plugin, and project skills from a `~/.claude` root plus a
/// `~/.claude.json` project registry. Every source is optional: a missing file
/// or directory means that source contributes nothing, never an error.
struct ClaudeCodeScanner: AgentScanner {
    let agent: AgentID = .claudeCode

    let root: URL
    let claudeJSONPath: URL

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true),
        claudeJSONPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json", isDirectory: false)
    ) {
        self.root = root
        self.claudeJSONPath = claudeJSONPath
    }

    func scan() throws -> [SkillInstallation] {
        let settings = Settings(root: root)
        var result: [SkillInstallation] = []

        result.append(contentsOf: scanUserSkills(settings: settings))
        result.append(contentsOf: scanPluginSkills(settings: settings))
        result.append(contentsOf: scanProjectSkills())

        // A tracked "project" can be the home directory itself, making its
        // .claude/skills the user skills dir — keep the first (user) sighting
        // of any directory.
        var seen: Set<String> = []
        return result.filter { seen.insert($0.directory.standardizedFileURL.path).inserted }
    }

    // MARK: - User skills

    private func scanUserSkills(settings: Settings) -> [SkillInstallation] {
        let skillsDir = root.appendingPathComponent("skills", isDirectory: true)
        return SkillScan.installations(in: skillsDir).map { found in
            let disabled = settings.skillOverrides[found.slug].map { $0 == false } ?? false
            return SkillInstallation(
                agent: agent,
                slug: found.slug,
                origin: .user,
                directory: found.directory,
                metadata: found.metadata,
                isEnabled: !disabled,
                lastModified: found.lastModified
            )
        }
    }

    // MARK: - Plugin skills

    private func scanPluginSkills(settings: Settings) -> [SkillInstallation] {
        let manifest = root
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("installed_plugins.json", isDirectory: false)
        guard
            let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plugins = object["plugins"] as? [String: Any]
        else {
            return []
        }

        var result: [SkillInstallation] = []
        for (pluginName, value) in plugins {
            guard let entries = value as? [[String: Any]] else { continue }
            let enabled = settings.enabledPlugins[pluginName] == true
            for entry in entries {
                guard let installPath = entry["installPath"] as? String else { continue }
                let skillsDir = URL(fileURLWithPath: installPath, isDirectory: true)
                    .appendingPathComponent("skills", isDirectory: true)
                for found in SkillScan.installations(in: skillsDir) {
                    result.append(SkillInstallation(
                        agent: agent,
                        slug: found.slug,
                        origin: .plugin(name: pluginName),
                        directory: found.directory,
                        metadata: found.metadata,
                        isEnabled: enabled,
                        lastModified: found.lastModified
                    ))
                }
            }
        }
        return result
    }

    // MARK: - Project skills

    private func scanProjectSkills() -> [SkillInstallation] {
        guard
            let data = try? Data(contentsOf: claudeJSONPath),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = object["projects"] as? [String: Any]
        else {
            return []
        }

        let fileManager = FileManager.default
        var result: [SkillInstallation] = []
        for projectPath in projects.keys {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue
            else { continue }

            let skillsDir = URL(fileURLWithPath: projectPath, isDirectory: true)
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
            for found in SkillScan.installations(in: skillsDir) {
                result.append(SkillInstallation(
                    agent: agent,
                    slug: found.slug,
                    origin: .project(path: projectPath),
                    directory: found.directory,
                    metadata: found.metadata,
                    isEnabled: true,
                    lastModified: found.lastModified
                ))
            }
        }
        return result
    }

    // MARK: - settings.json

    /// Minimal, tolerant view of the fields of `settings.json` this scanner
    /// cares about. Unknown keys are ignored.
    private struct Settings {
        /// slug -> enabled flag. A value of `false` (from `"off"` or `false`)
        /// marks the matching user skill disabled.
        var skillOverrides: [String: Bool] = [:]
        var enabledPlugins: [String: Bool] = [:]

        init(root: URL) {
            let url = root.appendingPathComponent("settings.json", isDirectory: false)
            guard
                let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return
            }

            if let overrides = object["skillOverrides"] as? [String: Any] {
                for (slug, value) in overrides {
                    skillOverrides[slug] = Self.isEnabled(value)
                }
            }
            if let enabled = object["enabledPlugins"] as? [String: Any] {
                for (name, value) in enabled {
                    enabledPlugins[name] = (value as? Bool) ?? false
                }
            }
        }

        /// Interprets an override value: `"off"` / `false` disable, everything
        /// else (including `"on"` / `true`) enables.
        private static func isEnabled(_ value: Any) -> Bool {
            if let flag = value as? Bool { return flag }
            if let string = value as? String {
                return string.lowercased() != "off"
            }
            return true
        }
    }
}
