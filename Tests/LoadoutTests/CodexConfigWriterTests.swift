import Foundation
import Testing
@testable import Loadout

@MainActor
@Suite struct CodexConfigWriterTests {
    /// Realistic config.toml: comments, unrelated tables, no skills.config.
    private static let baseConfig = """
    # Codex configuration
    model = "gpt-5"  # default model

    [tools]
    web_search = true

    [profiles.fast]
    model = "gpt-5-mini"
    """

    private func writer(_ fixture: Fixture) -> CodexConfigWriter {
        CodexConfigWriter(root: fixture.root)
    }

    private func journal(_ fixture: Fixture) -> ChangeJournal {
        ChangeJournal(directory: fixture.makeDir("journal"))
    }

    private func systemSkill(_ fixture: Fixture, slug: String) -> SkillInstallation {
        let directory = fixture.writeSkill(slug: slug, under: ["skills", ".system"])
        return SkillInstallation(
            agent: .codex, slug: slug, origin: .system, directory: directory,
            metadata: SkillMetadata(), isEnabled: true, lastModified: nil
        )
    }

    private func configText(_ fixture: Fixture) throws -> String {
        try String(
            contentsOf: fixture.root.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
    }

    @Test func disableAppendsBlockPreservingEveryPriorByte() throws {
        let fixture = Fixture()
        let original = Self.baseConfig + "\n"
        fixture.writeFile(original, at: "config.toml")
        let installation = systemSkill(fixture, slug: "imagegen")

        let change = try writer(fixture).setSkillEnabled(
            installation, enabled: false, journal: journal(fixture)
        )
        #expect(change.summary == "Disable imagegen for Codex CLI")

        let after = try configText(fixture)
        #expect(after.hasPrefix(original))
        let appended = String(after.dropFirst(original.count))
        #expect(appended == """

        [[skills.config]]
        path = "\(installation.directory.path)"
        enabled = false

        """)

        // Scanner round-trip sees the skill disabled.
        let scanned = try #require(
            try CodexScanner(root: fixture.root).scan().first { $0.slug == "imagegen" }
        )
        #expect(scanned.isEnabled == false)
    }

    @Test func enableRemovesAppendedBlockByteIdentically() throws {
        let fixture = Fixture()
        let original = Self.baseConfig + "\n"
        fixture.writeFile(original, at: "config.toml")
        let installation = systemSkill(fixture, slug: "imagegen")
        let sut = writer(fixture)
        let journal = journal(fixture)

        try sut.setSkillEnabled(installation, enabled: false, journal: journal)
        try sut.setSkillEnabled(installation, enabled: true, journal: journal)

        #expect(try configText(fixture) == original)

        let scanned = try #require(
            try CodexScanner(root: fixture.root).scan().first { $0.slug == "imagegen" }
        )
        #expect(scanned.isEnabled == true)
    }

    @Test func enableRemovesMidFileBlockKeepingSurroundingTables() throws {
        let fixture = Fixture()
        let installation = systemSkill(fixture, slug: "imagegen")
        let original = """
        model = "gpt-5"

        [[skills.config]]
        path = "\(installation.directory.path)"
        enabled = false

        [tools]
        web_search = true
        """
        fixture.writeFile(original, at: "config.toml")

        try writer(fixture).setSkillEnabled(
            installation, enabled: true, journal: journal(fixture)
        )

        #expect(try configText(fixture) == """
        model = "gpt-5"

        [tools]
        web_search = true
        """)
    }

    @Test func disableFlipsExistingEnabledLineInPlace() throws {
        let fixture = Fixture()
        let installation = systemSkill(fixture, slug: "imagegen")
        let original = """
        # keep me
        [[skills.config]]
        path = "\(installation.directory.path)"
        enabled = true

        [tools]
        web_search = true
        """
        fixture.writeFile(original, at: "config.toml")

        try writer(fixture).setSkillEnabled(
            installation, enabled: false, journal: journal(fixture)
        )

        let expected = original.replacingOccurrences(
            of: "enabled = true", with: "enabled = false"
        )
        #expect(try configText(fixture) == expected)
    }

    @Test func enableKeepsBlockWithExtraKeysAndFlipsEnabled() throws {
        let fixture = Fixture()
        let installation = systemSkill(fixture, slug: "imagegen")
        let original = """
        [[skills.config]]
        path = "\(installation.directory.path)"
        enabled = false
        note = "keep this block"
        """
        fixture.writeFile(original, at: "config.toml")

        try writer(fixture).setSkillEnabled(
            installation, enabled: true, journal: journal(fixture)
        )

        let expected = original.replacingOccurrences(
            of: "enabled = false", with: "enabled = true"
        )
        #expect(try configText(fixture) == expected)
    }

    @Test func disableMatchesByTrailingComponent() throws {
        let fixture = Fixture()
        let installation = systemSkill(fixture, slug: "imagegen")
        let original = """
        [[skills.config]]
        path = "/elsewhere/on/disk/imagegen"
        enabled = true
        """
        fixture.writeFile(original, at: "config.toml")

        try writer(fixture).setSkillEnabled(
            installation, enabled: false, journal: journal(fixture)
        )

        #expect(try configText(fixture) == """
        [[skills.config]]
        path = "/elsewhere/on/disk/imagegen"
        enabled = false
        """)
    }

    @Test func disableWithMissingConfigCreatesFileWithJustTheBlock() throws {
        let fixture = Fixture()
        let installation = systemSkill(fixture, slug: "imagegen")

        try writer(fixture).setSkillEnabled(
            installation, enabled: false, journal: journal(fixture)
        )

        #expect(try configText(fixture) == """
        [[skills.config]]
        path = "\(installation.directory.path)"
        enabled = false

        """)

        let scanned = try #require(
            try CodexScanner(root: fixture.root).scan().first { $0.slug == "imagegen" }
        )
        #expect(scanned.isEnabled == false)
    }

    @Test func capabilitiesAndUninstallPolicy() throws {
        let fixture = Fixture()
        let installation = systemSkill(fixture, slug: "imagegen")
        let sut = writer(fixture)

        #expect(sut.canToggle(installation))
        #expect(sut.toggleScope(installation) == .skill)
        #expect(sut.canUninstall(installation) == false)
        #expect(throws: (any Error).self) {
            try sut.uninstall(installation, journal: journal(fixture))
        }
        // The skill directory was not touched.
        #expect(FileManager.default.fileExists(atPath: installation.directory.path))
    }
}
