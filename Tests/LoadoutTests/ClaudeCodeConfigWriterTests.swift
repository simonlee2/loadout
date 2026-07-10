import Foundation
import Testing
@testable import Loadout

@MainActor
@Suite struct ClaudeCodeConfigWriterTests {
    /// The keys the real ~/.claude/settings.json contains today; a toggle
    /// round-trip must lose none of them.
    private static let realisticSettings = """
    {
      "enabledPlugins": {"warp@claude-code-warp": true},
      "extraKnownMarketplaces": {
        "claude-code-warp": {"source": {"source": "github", "repo": "warpdotdev/claude-code-warp"}}
      },
      "tui": {"notifChannel": "terminal_bell"},
      "theme": "dark",
      "agentPushNotifEnabled": true,
      "remoteControlAtStartup": false
    }
    """

    private func writer(_ fixture: Fixture) -> ClaudeCodeConfigWriter {
        ClaudeCodeConfigWriter(root: fixture.root)
    }

    private func journal(_ fixture: Fixture) -> ChangeJournal {
        ChangeJournal(directory: fixture.makeDir("journal"))
    }

    private func userSkill(_ fixture: Fixture, slug: String) -> SkillInstallation {
        let directory = fixture.writeSkill(slug: slug, under: ["skills"])
        return SkillInstallation(
            agent: .claudeCode, slug: slug, origin: .user, directory: directory,
            metadata: SkillMetadata(), isEnabled: true, lastModified: nil
        )
    }

    private func settingsJSON(_ fixture: Fixture) throws -> [String: Any] {
        let url = fixture.root.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func scan(_ fixture: Fixture) throws -> [SkillInstallation] {
        try ClaudeCodeScanner(
            root: fixture.root,
            claudeJSONPath: fixture.root.appendingPathComponent("missing.json")
        ).scan()
    }

    // MARK: - User skills

    @Test func disableAddsOverrideAndPreservesEveryOtherKey() throws {
        let fixture = Fixture()
        fixture.writeFile(Self.realisticSettings, at: "settings.json")
        let original = try settingsJSON(fixture)

        let change = try writer(fixture).setSkillEnabled(
            userSkill(fixture, slug: "swiftui-patterns"), enabled: false, journal: journal(fixture)
        )

        var after = try settingsJSON(fixture)
        let overrides = try #require(after["skillOverrides"] as? [String: Any])
        #expect(overrides.count == 1)
        #expect(overrides["swiftui-patterns"] as? String == "off")

        // Deep-equal minus the touched key: nothing else changed.
        after.removeValue(forKey: "skillOverrides")
        #expect(NSDictionary(dictionary: after) == NSDictionary(dictionary: original))

        #expect(change.summary == "Disable swiftui-patterns for Claude Code")

        // Scanner round-trip sees the skill disabled.
        let scanned = try #require(try scan(fixture).first { $0.slug == "swiftui-patterns" })
        #expect(scanned.isEnabled == false)
    }

    @Test func enableRemovesEntryAndEmptyOverridesDict() throws {
        let fixture = Fixture()
        fixture.writeFile(
            #"{"skillOverrides": {"alpha": "off"}, "theme": "dark"}"#,
            at: "settings.json"
        )

        try writer(fixture).setSkillEnabled(
            userSkill(fixture, slug: "alpha"), enabled: true, journal: journal(fixture)
        )

        let after = try settingsJSON(fixture)
        #expect(after["skillOverrides"] == nil)
        #expect(after["theme"] as? String == "dark")

        let scanned = try #require(try scan(fixture).first { $0.slug == "alpha" })
        #expect(scanned.isEnabled == true)
    }

    @Test func enableKeepsOtherSlugsOverride() throws {
        let fixture = Fixture()
        fixture.writeFile(
            #"{"skillOverrides": {"alpha": "off", "beta": "off"}}"#,
            at: "settings.json"
        )

        try writer(fixture).setSkillEnabled(
            userSkill(fixture, slug: "alpha"), enabled: true, journal: journal(fixture)
        )

        let after = try settingsJSON(fixture)
        let overrides = try #require(after["skillOverrides"] as? [String: Any])
        #expect(overrides.count == 1)
        #expect(overrides["beta"] as? String == "off")
    }

    @Test func disableWithMissingSettingsCreatesFile() throws {
        let fixture = Fixture()

        try writer(fixture).setSkillEnabled(
            userSkill(fixture, slug: "alpha"), enabled: false, journal: journal(fixture)
        )

        let after = try settingsJSON(fixture)
        #expect(after.count == 1)
        let overrides = try #require(after["skillOverrides"] as? [String: Any])
        #expect(overrides["alpha"] as? String == "off")
    }

    // MARK: - Plugin skills

    @Test func pluginToggleFlipsEnabledPluginsOnly() throws {
        let fixture = Fixture()
        fixture.writeFile(Self.realisticSettings, at: "settings.json")
        let original = try settingsJSON(fixture)

        // Plugin install tree so the scanner (and skill count) can see it.
        let install = fixture.makeDir("plugins", "cache", "warp")
        let skillDir = fixture.writeSkill(
            slug: "warp-skill", under: ["plugins", "cache", "warp", "skills"]
        )
        fixture.writeFile(
            #"{"plugins": {"warp@claude-code-warp": [{"installPath": "\#(install.path)"}]}}"#,
            at: "plugins", "installed_plugins.json"
        )

        let installation = SkillInstallation(
            agent: .claudeCode, slug: "warp-skill",
            origin: .plugin(name: "warp@claude-code-warp"), directory: skillDir,
            metadata: SkillMetadata(), isEnabled: true, lastModified: nil
        )
        let sut = writer(fixture)
        #expect(sut.canToggle(installation))
        #expect(sut.toggleScope(installation) == .plugin(name: "warp@claude-code-warp"))
        #expect(sut.canUninstall(installation) == false)

        let change = try sut.setSkillEnabled(installation, enabled: false, journal: journal(fixture))
        #expect(change.summary == "Disable plugin warp@claude-code-warp (1 skill)")

        var after = try settingsJSON(fixture)
        let plugins = try #require(after["enabledPlugins"] as? [String: Any])
        #expect(plugins["warp@claude-code-warp"] as? Bool == false)

        after.removeValue(forKey: "enabledPlugins")
        var expected = original
        expected.removeValue(forKey: "enabledPlugins")
        #expect(NSDictionary(dictionary: after) == NSDictionary(dictionary: expected))

        let scanned = try #require(try scan(fixture).first { $0.slug == "warp-skill" })
        #expect(scanned.isEnabled == false)

        // Re-enable round-trips through the scanner too.
        try sut.setSkillEnabled(installation, enabled: true, journal: journal(fixture))
        let rescanned = try #require(try scan(fixture).first { $0.slug == "warp-skill" })
        #expect(rescanned.isEnabled == true)
    }

    // MARK: - Project skills

    @Test func projectSkillsCannotBeToggled() throws {
        let fixture = Fixture()
        let directory = fixture.writeSkill(slug: "proj", under: ["project", ".claude", "skills"])
        let installation = SkillInstallation(
            agent: .claudeCode, slug: "proj",
            origin: .project(path: fixture.root.appendingPathComponent("project").path),
            directory: directory, metadata: SkillMetadata(), isEnabled: true, lastModified: nil
        )

        let sut = writer(fixture)
        #expect(sut.canToggle(installation) == false)
        #expect(sut.canUninstall(installation) == false)
        #expect(throws: (any Error).self) {
            try sut.setSkillEnabled(installation, enabled: false, journal: journal(fixture))
        }
        // Nothing was written.
        let settings = fixture.root.appendingPathComponent("settings.json")
        #expect(!FileManager.default.fileExists(atPath: settings.path))
    }

    // MARK: - Invalid JSON

    @Test func invalidSettingsJSONThrowsWithoutClobbering() throws {
        let fixture = Fixture()
        let corrupt = "{ this is not json"
        let url = fixture.writeFile(corrupt, at: "settings.json")
        let originalBytes = try Data(contentsOf: url)

        #expect(throws: (any Error).self) {
            try writer(fixture).setSkillEnabled(
                userSkill(fixture, slug: "alpha"), enabled: false, journal: journal(fixture)
            )
        }

        #expect(try Data(contentsOf: url) == originalBytes)
    }

    // MARK: - Uninstall

    @Test func uninstallShelvesDirectoryAndClearsStaleOverride() throws {
        let fixture = Fixture()
        let installation = userSkill(fixture, slug: "alpha")
        fixture.writeFile(
            #"{"skillOverrides": {"alpha": "off"}, "theme": "dark"}"#,
            at: "settings.json"
        )
        let sut = writer(fixture)
        #expect(sut.canUninstall(installation))
        let journal = journal(fixture)

        let change = try sut.uninstall(installation, journal: journal)

        // Directory gone from skills/, present on the shelf.
        #expect(!FileManager.default.fileExists(atPath: installation.directory.path))
        let shelved = try #require(change.backupPath)
        #expect(shelved.hasPrefix(journal.shelfDirectory.path))
        #expect(FileManager.default.fileExists(
            atPath: (shelved as NSString).appendingPathComponent("SKILL.md")
        ))

        // Stale override removed as a second journaled edit.
        let after = try settingsJSON(fixture)
        #expect(after["skillOverrides"] == nil)
        #expect(after["theme"] as? String == "dark")
        #expect(journal.entries.count == 2)
        #expect(journal.entries[0].kind == .directoryMove)
        #expect(journal.entries[1].kind == .fileEdit)

        // Revert restores the directory with its contents.
        try journal.revert(change)
        #expect(FileManager.default.fileExists(
            atPath: installation.directory.appendingPathComponent("SKILL.md").path
        ))
    }

    @Test func uninstallWithoutStaleOverrideSkipsSettingsEdit() throws {
        let fixture = Fixture()
        let installation = userSkill(fixture, slug: "alpha")
        fixture.writeFile(#"{"theme": "dark"}"#, at: "settings.json")
        let journal = journal(fixture)

        try writer(fixture).uninstall(installation, journal: journal)

        #expect(journal.entries.count == 1)
        #expect(journal.entries[0].kind == .directoryMove)
    }
}
