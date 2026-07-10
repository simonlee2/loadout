import Foundation

/// Read-only scanner for Codex CLI skill installations.
///
/// System skills live under the hidden `<root>/skills/.system/` directory;
/// any non-hidden `<root>/skills/*` directories are treated as user skills.
struct CodexScanner: AgentScanner {
    let agent: AgentID = .codex

    let root: URL

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) {
        self.root = root
    }

    func scan() throws -> [SkillInstallation] {
        let disabledPaths = disabledSkillPaths()
        let skillsDir = root.appendingPathComponent("skills", isDirectory: true)

        var result: [SkillInstallation] = []

        // System skills under the hidden `.system` directory.
        let systemDir = skillsDir.appendingPathComponent(".system", isDirectory: true)
        for found in SkillScan.installations(in: systemDir) {
            result.append(makeInstallation(found, origin: .system, disabledPaths: disabledPaths))
        }

        // User skills: non-hidden directories directly under `skills`.
        for found in SkillScan.installations(in: skillsDir, includeHidden: false) {
            result.append(makeInstallation(found, origin: .user, disabledPaths: disabledPaths))
        }

        return result
    }

    private func makeInstallation(
        _ found: SkillScan.Found,
        origin: SkillOrigin,
        disabledPaths: DisabledPaths
    ) -> SkillInstallation {
        SkillInstallation(
            agent: agent,
            slug: found.slug,
            origin: origin,
            directory: found.directory,
            metadata: found.metadata,
            isEnabled: !disabledPaths.disables(found.directory),
            lastModified: found.lastModified
        )
    }

    // MARK: - config.toml

    /// Set of skill paths that `config.toml` marks `enabled = false`.
    ///
    /// Matching is tolerant: a directory is disabled if its resolved absolute
    /// path matches, or if its trailing path component matches, any disabled
    /// entry.
    private struct DisabledPaths {
        let fullPaths: Set<String>
        let lastComponents: Set<String>

        func disables(_ directory: URL) -> Bool {
            let resolved = directory.standardizedFileURL.resolvingSymlinksInPath().path
            if fullPaths.contains(resolved) { return true }
            if fullPaths.contains(directory.path) { return true }
            return lastComponents.contains(directory.lastPathComponent)
        }
    }

    /// Minimal line-by-line TOML reader: collects `path`/`enabled` pairs from
    /// repeated `[[skills.config]]` blocks. Avoids a TOML dependency on purpose.
    private func disabledSkillPaths() -> DisabledPaths {
        let url = root.appendingPathComponent("config.toml", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return DisabledPaths(fullPaths: [], lastComponents: [])
        }

        var fullPaths: Set<String> = []
        var lastComponents: Set<String> = []

        var inBlock = false
        var currentPath: String?
        var currentEnabled: Bool?

        func flush() {
            if let path = currentPath, currentEnabled == false {
                let resolved = URL(fileURLWithPath: path)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                fullPaths.insert(resolved)
                fullPaths.insert(path)
                lastComponents.insert((path as NSString).lastPathComponent)
            }
            currentPath = nil
            currentEnabled = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") {
                // A new table header closes the current block.
                flush()
                inBlock = line == "[[skills.config]]"
                continue
            }

            guard inBlock else { continue }

            if let value = tomlValue(for: "path", in: line) {
                currentPath = unquote(value)
            } else if let value = tomlValue(for: "enabled", in: line) {
                currentEnabled = value.lowercased() == "true"
            }
        }
        flush()

        return DisabledPaths(fullPaths: fullPaths, lastComponents: lastComponents)
    }

    /// Returns the raw right-hand side of `key = value` on a line, or nil.
    private func tomlValue(for key: String, in line: String) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard parts[0].trimmingCharacters(in: .whitespaces) == key else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// Strips surrounding single or double quotes from a TOML string value.
    private func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
