import Foundation
import Testing
@testable import LoadoutKit

@Suite struct CodexScannerTests {
    @Test func systemSkillsGetSystemOrigin() throws {
        let fixture = Fixture()
        fixture.writeSkill(slug: "imagegen", under: ["skills", ".system"])
        fixture.writeSkill(slug: "skill-creator", under: ["skills", ".system"])
        // Marker file alongside system skills must be ignored.
        fixture.writeFile("v1", at: "skills", ".system", ".codex-system-skills.marker")

        let scanner = CodexScanner(root: fixture.root)
        let skills = try scanner.scan()

        #expect(skills.count == 2)
        #expect(skills.allSatisfy { $0.origin == .system })
        #expect(skills.allSatisfy { $0.agent == .codex })
        #expect(Set(skills.map(\.slug)) == ["imagegen", "skill-creator"])
        #expect(skills.allSatisfy { $0.isEnabled })
    }

    @Test func nonHiddenSkillsGetUserOrigin() throws {
        let fixture = Fixture()
        fixture.writeSkill(slug: "sys", under: ["skills", ".system"])
        fixture.writeSkill(slug: "mine", under: ["skills"])

        let scanner = CodexScanner(root: fixture.root)
        let skills = try scanner.scan()

        let mine = try #require(skills.first { $0.slug == "mine" })
        #expect(mine.origin == .user)
        // The hidden .system dir must not appear as a user skill.
        #expect(skills.filter { $0.origin == .user }.count == 1)
    }

    @Test func configTomlDisablesByPath() throws {
        let fixture = Fixture()
        let skillDir = fixture.writeSkill(slug: "imagegen", under: ["skills", ".system"])
        fixture.writeSkill(slug: "openai-docs", under: ["skills", ".system"])

        let config = """
        model = "gpt-5"

        [[skills.config]]
        path = "\(skillDir.path)"
        enabled = false

        [[skills.config]]
        path = "/some/other/path/openai-docs-elsewhere"
        enabled = true
        """
        fixture.writeFile(config, at: "config.toml")

        let scanner = CodexScanner(root: fixture.root)
        let skills = try scanner.scan()
        let imagegen = try #require(skills.first { $0.slug == "imagegen" })
        let docs = try #require(skills.first { $0.slug == "openai-docs" })
        #expect(imagegen.isEnabled == false)
        #expect(docs.isEnabled == true)
    }

    @Test func configTomlDisablesByTrailingComponent() throws {
        let fixture = Fixture()
        fixture.writeSkill(slug: "imagegen", under: ["skills", ".system"])

        let config = """
        [[skills.config]]
        path = "/elsewhere/on/disk/imagegen"
        enabled = false
        """
        fixture.writeFile(config, at: "config.toml")

        let scanner = CodexScanner(root: fixture.root)
        let imagegen = try #require(try scanner.scan().first { $0.slug == "imagegen" })
        #expect(imagegen.isEnabled == false)
    }

    @Test func missingConfigTomlTolerated() throws {
        let fixture = Fixture()
        fixture.writeSkill(slug: "imagegen", under: ["skills", ".system"])

        let scanner = CodexScanner(root: fixture.root)
        let skills = try scanner.scan()
        #expect(skills.count == 1)
        #expect(skills[0].isEnabled == true)
    }

    @Test func missingRootTolerated() throws {
        let scanner = CodexScanner(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("loadout-nonexistent-\(UUID().uuidString)")
        )
        #expect(try scanner.scan().isEmpty)
    }
}
