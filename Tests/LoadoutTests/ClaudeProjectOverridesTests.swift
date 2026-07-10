import Foundation
import Testing
@testable import Loadout

@MainActor
@Suite struct ClaudeProjectOverridesTests {
    // MARK: - Helpers

    /// Builds a fixture whose layout is:
    ///   <root>/root/          → the ~/.claude root (user skills, settings.json)
    ///   <root>/root/../claude.json (via explicit path) → project registry
    ///   <root>/projects/<name> → tracked project dirs
    ///   <root>/home           → the home directory (excluded from projects())
    private func overrides(_ fixture: Fixture) -> ClaudeProjectOverrides {
        ClaudeProjectOverrides(
            root: fixture.makeDir("root"),
            claudeJSONPath: fixture.root.appendingPathComponent("claude.json"),
            homeDirectory: fixture.makeDir("home")
        )
    }

    private func journal(_ fixture: Fixture) -> ChangeJournal {
        ChangeJournal(directory: fixture.makeDir("journal"))
    }

    /// Registers the given absolute project paths in claude.json.
    private func writeClaudeJSON(_ fixture: Fixture, projects: [String]) {
        let entries = projects.map { "\"\($0)\": {}" }.joined(separator: ", ")
        fixture.writeFile("{\"projects\": {\(entries)}}", at: "claude.json")
    }

    private func projectRef(_ fixture: Fixture, _ name: String) -> ProjectRef {
        ProjectRef(path: fixture.root.appendingPathComponent(name).path)
    }

    private func localSettings(_ fixture: Fixture, project: String) throws -> [String: Any]? {
        let url = fixture.root
            .appendingPathComponent(project)
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.local.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - projects()

    @Test func projectsExcludesHomeAndMissingSortedByName() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        let zebra = fixture.makeDir("projects", "Zebra")
        let apple = fixture.makeDir("projects", "Apple")
        let home = fixture.root.appendingPathComponent("home") // == homeDirectory
        let missing = fixture.root.appendingPathComponent("projects").appendingPathComponent("Gone")

        writeClaudeJSON(fixture, projects: [zebra.path, apple.path, home.path, missing.path])

        let projects = try sut.projects()
        #expect(projects.map(\.name) == ["Apple", "Zebra"])
        #expect(!projects.contains { $0.path == home.path })
        #expect(!projects.contains { $0.path == missing.path })
    }

    @Test func projectsAbsentClaudeJSONReturnsEmpty() throws {
        let fixture = Fixture()
        let sut = overrides(fixture) // no claude.json written
        #expect(try sut.projects().isEmpty)
    }

    @Test func projectsInvalidClaudeJSONReturnsEmpty() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.writeFile("{ not json", at: "claude.json")
        #expect(try sut.projects().isEmpty)
    }

    // MARK: - skillStates precedence matrix

    @Test func userLevelOffDisablesWithUserSource() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.writeSkill(slug: "alpha", under: ["root", "skills"])
        fixture.writeFile(#"{"skillOverrides": {"alpha": "off"}}"#, at: "root", "settings.json")
        let project = fixture.makeDir("projects", "App")
        writeClaudeJSON(fixture, projects: [project.path])

        let state = try #require(
            try sut.skillStates(in: ProjectRef(path: project.path)).first { $0.installation.slug == "alpha" }
        )
        #expect(state.isEnabledInProject == false)
        #expect(state.source == .user)
    }

    @Test func projectSharedOffOverridesNothingAtUser() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.writeSkill(slug: "alpha", under: ["root", "skills"])
        let project = fixture.makeDir("projects", "App")
        fixture.writeFile(
            #"{"skillOverrides": {"alpha": "off"}}"#,
            at: "projects", "App", ".claude", "settings.json"
        )
        writeClaudeJSON(fixture, projects: [project.path])

        let state = try #require(
            try sut.skillStates(in: ProjectRef(path: project.path)).first { $0.installation.slug == "alpha" }
        )
        #expect(state.isEnabledInProject == false)
        #expect(state.source == .projectShared)
    }

    @Test func projectLocalOnOverridesSharedOff() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.writeSkill(slug: "alpha", under: ["root", "skills"])
        let project = fixture.makeDir("projects", "App")
        fixture.writeFile(
            #"{"skillOverrides": {"alpha": "off"}}"#,
            at: "projects", "App", ".claude", "settings.json"
        )
        fixture.writeFile(
            #"{"skillOverrides": {"alpha": "on"}}"#,
            at: "projects", "App", ".claude", "settings.local.json"
        )
        writeClaudeJSON(fixture, projects: [project.path])

        let state = try #require(
            try sut.skillStates(in: ProjectRef(path: project.path)).first { $0.installation.slug == "alpha" }
        )
        #expect(state.isEnabledInProject == true)
        #expect(state.source == .projectLocal)
    }

    @Test func noKeysDefaultsEnabledWithNilSource() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.writeSkill(slug: "alpha", under: ["root", "skills"])
        let project = fixture.makeDir("projects", "App")
        writeClaudeJSON(fixture, projects: [project.path])

        let state = try #require(
            try sut.skillStates(in: ProjectRef(path: project.path)).first { $0.installation.slug == "alpha" }
        )
        #expect(state.isEnabledInProject == true)
        #expect(state.source == nil)
    }

    // MARK: - Plugin gating

    @Test func disabledPluginDisablesItsSkillsRegardlessOfOverrides() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        let install = fixture.makeDir("cache", "myplugin")
        fixture.writeSkill(slug: "plugin-skill", under: ["cache", "myplugin", "skills"])
        fixture.writeFile(
            #"{"plugins": {"myplugin@market": [{"installPath": "\#(install.path)"}]}}"#,
            at: "root", "plugins", "installed_plugins.json"
        )
        // Plugin absent from enabledPlugins -> disabled. A project "on" cannot rescue it.
        let project = fixture.makeDir("projects", "App")
        fixture.writeFile(
            #"{"skillOverrides": {"plugin-skill": "on"}}"#,
            at: "projects", "App", ".claude", "settings.local.json"
        )
        writeClaudeJSON(fixture, projects: [project.path])

        let state = try #require(
            try sut.skillStates(in: ProjectRef(path: project.path))
                .first { $0.installation.slug == "plugin-skill" }
        )
        #expect(state.isEnabledInProject == false)
        #expect(state.source == .user)
    }

    // MARK: - Project-own skills

    @Test func projectOwnSkillsIncludedWithState() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        let project = fixture.makeDir("projects", "App")
        fixture.writeSkill(slug: "own-skill", under: ["projects", "App", ".claude", "skills"])
        // Another tracked project whose skills must NOT leak in.
        let other = fixture.makeDir("projects", "Other")
        fixture.writeSkill(slug: "other-skill", under: ["projects", "Other", ".claude", "skills"])
        fixture.writeFile(
            #"{"skillOverrides": {"own-skill": "off"}}"#,
            at: "projects", "App", ".claude", "settings.local.json"
        )
        writeClaudeJSON(fixture, projects: [project.path, other.path])

        let states = try sut.skillStates(in: ProjectRef(path: project.path))
        let own = try #require(states.first { $0.installation.slug == "own-skill" })
        #expect(own.installation.origin == .project(path: project.path))
        #expect(own.isEnabledInProject == false)
        #expect(own.source == .projectLocal)
        // The other project's skill is excluded.
        #expect(!states.contains { $0.installation.slug == "other-skill" })
    }

    // MARK: - setSkill

    @Test func disableWritesExactKeyPreservingOthers() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        let project = fixture.makeDir("projects", "App")
        fixture.writeFile(
            #"{"permissions": {"allow": ["Bash"]}, "skillOverrides": {"beta": "off"}}"#,
            at: "projects", "App", ".claude", "settings.local.json"
        )

        try sut.setSkill("alpha", enabled: false, in: projectRef(fixture, "projects/App"), journal: journal(fixture))

        let after = try #require(try localSettings(fixture, project: "projects/App"))
        let overrides = try #require(after["skillOverrides"] as? [String: Any])
        #expect(overrides["alpha"] as? String == "off")
        #expect(overrides["beta"] as? String == "off")
        // Unknown key preserved.
        #expect((after["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash"])
    }

    @Test func enableWithUserLevelOffWritesOn() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.writeFile(#"{"skillOverrides": {"alpha": "off"}}"#, at: "root", "settings.json")
        fixture.makeDir("projects", "App")

        try sut.setSkill("alpha", enabled: true, in: projectRef(fixture, "projects/App"), journal: journal(fixture))

        let after = try #require(try localSettings(fixture, project: "projects/App"))
        let overrides = try #require(after["skillOverrides"] as? [String: Any])
        #expect(overrides["alpha"] as? String == "on")
    }

    @Test func enableWithNothingBelowRemovesKeyAndDropsEmptyDict() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.writeFile(
            #"{"skillOverrides": {"alpha": "off"}}"#,
            at: "projects", "App", ".claude", "settings.local.json"
        )
        // No lower-level override for alpha.

        try sut.setSkill("alpha", enabled: true, in: projectRef(fixture, "projects/App"), journal: journal(fixture))

        let after = try #require(try localSettings(fixture, project: "projects/App"))
        #expect(after["skillOverrides"] == nil)
    }

    @Test func fileCreatedWhenMissing() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.makeDir("projects", "App")

        #expect(try localSettings(fixture, project: "projects/App") == nil)
        try sut.setSkill("alpha", enabled: false, in: projectRef(fixture, "projects/App"), journal: journal(fixture))

        let after = try #require(try localSettings(fixture, project: "projects/App"))
        #expect((after["skillOverrides"] as? [String: Any])?["alpha"] as? String == "off")
    }

    @Test func journalRevertRestoresExistingFileByteIdentically() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        let url = fixture.writeFile(
            #"{"skillOverrides": {"beta": "off"}, "theme": "dark"}"#,
            at: "projects", "App", ".claude", "settings.local.json"
        )
        let originalBytes = try Data(contentsOf: url)
        let journal = journal(fixture)

        let change = try sut.setSkill(
            "alpha", enabled: false, in: projectRef(fixture, "projects/App"), journal: journal
        )
        #expect(try Data(contentsOf: url) != originalBytes)

        try journal.revert(change)
        #expect(try Data(contentsOf: url) == originalBytes)
    }

    @Test func journalRevertDeletesFileThatDidNotExist() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.makeDir("projects", "App")
        let journal = journal(fixture)

        let change = try sut.setSkill(
            "alpha", enabled: false, in: projectRef(fixture, "projects/App"), journal: journal
        )
        #expect(try localSettings(fixture, project: "projects/App") != nil)

        try journal.revert(change)
        #expect(try localSettings(fixture, project: "projects/App") == nil)
    }

    @Test func invalidJSONThrowsWithoutClobbering() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        let url = fixture.writeFile(
            "{ this is not json",
            at: "projects", "App", ".claude", "settings.local.json"
        )
        let originalBytes = try Data(contentsOf: url)

        #expect(throws: (any Error).self) {
            try sut.setSkill(
                "alpha", enabled: false, in: projectRef(fixture, "projects/App"), journal: journal(fixture)
            )
        }
        #expect(try Data(contentsOf: url) == originalBytes)
    }

    // MARK: - Round-trip

    @Test func setSkillThenSkillStatesReflectsIt() throws {
        let fixture = Fixture()
        let sut = overrides(fixture)
        fixture.writeSkill(slug: "alpha", under: ["root", "skills"])
        let project = fixture.makeDir("projects", "App")
        writeClaudeJSON(fixture, projects: [project.path])
        let ref = ProjectRef(path: project.path)

        // Initially enabled, no source.
        let before = try #require(try sut.skillStates(in: ref).first { $0.installation.slug == "alpha" })
        #expect(before.isEnabledInProject == true)
        #expect(before.source == nil)

        try sut.setSkill("alpha", enabled: false, in: ref, journal: journal(fixture))

        let after = try #require(try sut.skillStates(in: ref).first { $0.installation.slug == "alpha" })
        #expect(after.isEnabledInProject == false)
        #expect(after.source == .projectLocal)
    }
}
