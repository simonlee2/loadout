import Foundation
import Testing
@testable import Loadout

@Suite struct ClaudeCodeScannerTests {
    @Test func findsUserSkillsWithSlugsAndOrigin() throws {
        let fixture = Fixture()
        fixture.writeSkill(slug: "alpha", under: ["skills"], description: "Alpha skill.")
        fixture.writeSkill(slug: "beta", under: ["skills"])
        // A directory without SKILL.md must be skipped.
        fixture.makeDir("skills", "empty")

        let scanner = ClaudeCodeScanner(
            root: fixture.root,
            claudeJSONPath: fixture.root.appendingPathComponent("missing.json")
        )
        let skills = try scanner.scan()

        let user = skills.filter { $0.origin == .user }
        #expect(user.count == 2)
        #expect(Set(user.map(\.slug)) == ["alpha", "beta"])
        #expect(user.allSatisfy { $0.agent == .claudeCode })
        #expect(user.allSatisfy { $0.isEnabled })
        let alpha = try #require(user.first { $0.slug == "alpha" })
        #expect(alpha.metadata.description == "Alpha skill.")
        #expect(alpha.lastModified != nil)
    }

    @Test func skillOverridesOffDisables() throws {
        let fixture = Fixture()
        fixture.writeSkill(slug: "alpha", under: ["skills"])
        fixture.writeSkill(slug: "beta", under: ["skills"])
        fixture.writeFile(
            #"{"skillOverrides": {"alpha": "off", "beta": "on"}}"#,
            at: "settings.json"
        )

        let scanner = ClaudeCodeScanner(
            root: fixture.root,
            claudeJSONPath: fixture.root.appendingPathComponent("missing.json")
        )
        let skills = try scanner.scan()

        let alpha = try #require(skills.first { $0.slug == "alpha" })
        let beta = try #require(skills.first { $0.slug == "beta" })
        #expect(alpha.isEnabled == false)
        #expect(beta.isEnabled == true)
    }

    @Test func skillOverridesFalseDisables() throws {
        let fixture = Fixture()
        fixture.writeSkill(slug: "alpha", under: ["skills"])
        fixture.writeFile(#"{"skillOverrides": {"alpha": false}}"#, at: "settings.json")

        let scanner = ClaudeCodeScanner(
            root: fixture.root,
            claudeJSONPath: fixture.root.appendingPathComponent("missing.json")
        )
        let alpha = try #require(try scanner.scan().first { $0.slug == "alpha" })
        #expect(alpha.isEnabled == false)
    }

    @Test func pluginSkillsGatedByEnabledPlugins() throws {
        let fixture = Fixture()
        // Plugin install location, outside the claude root.
        let install = fixture.makeDir("cache", "myplugin", "1.0.0")
        fixture.writeSkill(slug: "plugin-skill", under: ["cache", "myplugin", "1.0.0", "skills"])

        let manifest = """
        {"version": 2, "plugins": {"myplugin@market": [
            {"scope": "user", "installPath": "\(install.path)", "version": "1.0.0"}
        ]}}
        """
        fixture.writeFile(manifest, at: "plugins", "installed_plugins.json")
        fixture.writeFile(#"{"enabledPlugins": {"myplugin@market": true}}"#, at: "settings.json")

        let scanner = ClaudeCodeScanner(
            root: fixture.root,
            claudeJSONPath: fixture.root.appendingPathComponent("missing.json")
        )
        let plugin = try #require(try scanner.scan().first { $0.slug == "plugin-skill" })
        #expect(plugin.origin == .plugin(name: "myplugin@market"))
        #expect(plugin.isEnabled == true)
    }

    @Test func pluginSkillsDisabledWhenNotEnabled() throws {
        let fixture = Fixture()
        let install = fixture.makeDir("cache", "myplugin", "1.0.0")
        fixture.writeSkill(slug: "plugin-skill", under: ["cache", "myplugin", "1.0.0", "skills"])
        let manifest = """
        {"plugins": {"myplugin@market": [{"installPath": "\(install.path)"}]}}
        """
        fixture.writeFile(manifest, at: "plugins", "installed_plugins.json")
        // No settings.json -> plugin not enabled.

        let scanner = ClaudeCodeScanner(
            root: fixture.root,
            claudeJSONPath: fixture.root.appendingPathComponent("missing.json")
        )
        let plugin = try #require(try scanner.scan().first { $0.slug == "plugin-skill" })
        #expect(plugin.isEnabled == false)
    }

    @Test func projectSkillsViaClaudeJSON() throws {
        let fixture = Fixture()
        // A project directory with a .claude/skills tree.
        let project = fixture.makeDir("projects", "MyApp")
        fixture.writeSkill(slug: "proj-skill", under: ["projects", "MyApp", ".claude", "skills"])

        let claudeJSON = fixture.writeFile(
            "{\"projects\": {\"\(project.path)\": {}}}",
            at: "claude.json"
        )

        let scanner = ClaudeCodeScanner(root: fixture.root, claudeJSONPath: claudeJSON)
        let proj = try #require(try scanner.scan().first { $0.slug == "proj-skill" })
        #expect(proj.origin == .project(path: project.path))
        #expect(proj.isEnabled == true)
    }

    @Test func homeTrackedAsProjectDoesNotDoubleCountUserSkills() throws {
        let fixture = Fixture()
        // ~/.claude.json can track the home directory itself as a project,
        // making <project>/.claude/skills the user skills dir.
        let home = fixture.makeDir("home")
        fixture.writeSkill(slug: "alpha", under: ["home", ".claude", "skills"])
        let claudeJSON = fixture.writeFile(
            "{\"projects\": {\"\(home.path)\": {}}}",
            at: "claude.json"
        )

        let scanner = ClaudeCodeScanner(
            root: home.appendingPathComponent(".claude", isDirectory: true),
            claudeJSONPath: claudeJSON
        )
        let skills = try scanner.scan()

        #expect(skills.count == 1)
        let alpha = try #require(skills.first)
        #expect(alpha.origin == .user)
    }

    @Test func missingSettingsAndFilesTolerated() throws {
        let fixture = Fixture()
        // Empty root, non-existent claude.json.
        let scanner = ClaudeCodeScanner(
            root: fixture.root,
            claudeJSONPath: fixture.root.appendingPathComponent("nope.json")
        )
        let skills = try scanner.scan()
        #expect(skills.isEmpty)
    }
}
