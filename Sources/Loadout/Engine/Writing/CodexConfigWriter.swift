import Foundation

/// Write-side driver for Codex CLI.
///
/// Every skill (system and user) toggles via a `[[skills.config]]` block in
/// `<root>/config.toml`. Editing is text-surgical and line-based: only the
/// block for the target skill is touched, every other byte — comments,
/// whitespace, unrelated tables — is preserved exactly. Disabling appends a
/// block (or flips `enabled` in place); enabling removes the block again when
/// it holds nothing but `path`/`enabled`, so a disable→enable round trip is
/// byte-identical.
@MainActor
struct CodexConfigWriter: AgentConfigWriter {
    let agent: AgentID = .codex

    let root: URL

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) {
        self.root = root
    }

    private var configFile: URL {
        root.appendingPathComponent("config.toml", isDirectory: false)
    }

    func canToggle(_ installation: SkillInstallation) -> Bool { true }

    /// Codex skills are system-managed installs in M1; removing their
    /// directories invites codex re-install weirdness, so no uninstall.
    func canUninstall(_ installation: SkillInstallation) -> Bool { false }

    func toggleScope(_ installation: SkillInstallation) -> ToggleScope { .skill }

    @discardableResult
    func setSkillEnabled(
        _ installation: SkillInstallation,
        enabled: Bool,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        let fileExists = FileManager.default.fileExists(atPath: configFile.path)
        let original = fileExists ? try String(contentsOf: configFile, encoding: .utf8) : ""
        let edited = enabled
            ? textEnabling(installation.directory, in: original)
            : textDisabling(installation.directory, in: original)

        let change = try journal.recordFileEdit(
            agent: agent,
            summary: "\(enabled ? "Enable" : "Disable") \(installation.slug) for Codex CLI",
            file: configFile
        )
        // Nothing to write when enabling a skill that has no block and no
        // file — don't create an empty config.toml.
        guard fileExists || !edited.isEmpty else { return change }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(edited.utf8).write(to: configFile, options: .atomic)
        } catch {
            try? journal.revert(change)
            throw error
        }
        return change
    }

    @discardableResult
    func uninstall(
        _ installation: SkillInstallation,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        throw ConfigWriteError(message: """
            Codex CLI skills are managed by codex itself; Loadout cannot \
            uninstall “\(installation.slug)” in M1.
            """)
    }

    // MARK: - Surgical TOML editing

    /// One `[[skills.config]]` block located within the file's lines.
    private struct Block {
        let headerLine: Int
        /// Exclusive end: the next table header line, or `lines.count`.
        var endLine: Int
        var pathLine: Int?
        var pathValue: String?
        var enabledLine: Int?
        /// True when the block contains anything beyond `path`/`enabled`
        /// (other keys, comments) that whole-block removal would destroy.
        var hasOtherContent = false
    }

    private func textDisabling(_ directory: URL, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let block = block(for: directory, in: lines) {
            if let enabledLine = block.enabledLine {
                lines[enabledLine] = replacingValue(of: lines[enabledLine], with: false)
            } else if let pathLine = block.pathLine {
                lines.insert("enabled = false", at: pathLine + 1)
            }
            return lines.joined(separator: "\n")
        }

        let appended = "[[skills.config]]\npath = \"\(directory.path)\"\nenabled = false\n"
        return text.isEmpty ? appended : text + "\n" + appended
    }

    private func textEnabling(_ directory: URL, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let block = block(for: directory, in: lines) else { return text }

        if block.hasOtherContent {
            if let enabledLine = block.enabledLine {
                lines[enabledLine] = replacingValue(of: lines[enabledLine], with: true)
            }
            return lines.joined(separator: "\n")
        }

        // Only path/enabled: remove the whole block. When the block runs to
        // EOF its removal also eats the final empty component (the trailing
        // newline marker); the blank line that preceded the header takes over
        // that role, or we restore the newline explicitly.
        let removedToEOF = block.endLine == lines.count
        let hadTrailingNewline = lines.last == ""
        lines.removeSubrange(block.headerLine..<block.endLine)
        if removedToEOF, hadTrailingNewline, lines.last != "" {
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func block(for directory: URL, in lines: [String]) -> Block? {
        skillConfigBlocks(in: lines).first { matches($0.pathValue, directory: directory) }
    }

    private func skillConfigBlocks(in lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespaces) == "[[skills.config]]" else {
                index += 1
                continue
            }
            var block = Block(headerLine: index, endLine: lines.count)
            var cursor = index + 1
            while cursor < lines.count {
                let line = lines[cursor].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }
                if !line.isEmpty {
                    if let value = tomlValue(for: "path", in: line) {
                        block.pathLine = cursor
                        block.pathValue = unquote(value)
                    } else if tomlValue(for: "enabled", in: line) != nil {
                        block.enabledLine = cursor
                    } else {
                        block.hasOtherContent = true
                    }
                }
                cursor += 1
            }
            block.endLine = cursor
            blocks.append(block)
            index = cursor
        }
        return blocks
    }

    /// Same tolerant matching as `CodexScanner`: exact, resolved, or
    /// trailing path component.
    private func matches(_ entry: String?, directory: URL) -> Bool {
        guard let entry else { return false }
        if entry == directory.path { return true }
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath().path
        if entry == resolvedDirectory { return true }
        let resolvedEntry = URL(fileURLWithPath: entry)
            .standardizedFileURL.resolvingSymlinksInPath().path
        if resolvedEntry == resolvedDirectory || resolvedEntry == directory.path { return true }
        return (entry as NSString).lastPathComponent == directory.lastPathComponent
    }

    /// Rewrites an `enabled = …` line in place, keeping its indentation.
    private func replacingValue(of line: String, with enabled: Bool) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return indent + "enabled = \(enabled)"
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
