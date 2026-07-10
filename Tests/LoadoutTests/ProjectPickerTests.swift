import Foundation
import Testing
@testable import LoadoutKit

/// A minimal in-memory `ProjectOverriding` whose auto-detected project list is
/// fully controllable, so the store's combination logic can be exercised
/// without touching any real config. `skillStates`/`setSkill` are unused here.
@MainActor
private final class FixtureOverrides: ProjectOverriding {
    var auto: [ProjectRef]

    init(auto: [ProjectRef]) { self.auto = auto }

    func projects() throws -> [ProjectRef] { auto }

    func skillStates(in project: ProjectRef) throws -> [ProjectSkillState] { [] }

    @discardableResult
    func setSkill(
        _ slug: String,
        enabled: Bool,
        in project: ProjectRef,
        journal: ChangeJournal
    ) throws -> ConfigChange {
        throw FixtureError.unsupported
    }

    enum FixtureError: Error { case unsupported }
}

@MainActor
@Suite struct ProjectPreferencesTests {
    private func prefsFile(_ fixture: Fixture) -> URL {
        fixture.root.appendingPathComponent("projects.json")
    }

    @Test func hideAddAndShowHiddenPersistAcrossReInit() {
        let fixture = Fixture()
        let file = prefsFile(fixture)

        let prefs = ProjectPreferences(file: file)
        prefs.hide("/some/hidden")
        prefs.add("/some/added")
        prefs.showHidden = true

        // A fresh instance reads the same file back.
        let reloaded = ProjectPreferences(file: file)
        #expect(reloaded.hidden == ["/some/hidden"])
        #expect(reloaded.added == ["/some/added"])
        #expect(reloaded.showHidden == true)
    }

    @Test func unhideAndRemoveAddedPersist() {
        let fixture = Fixture()
        let file = prefsFile(fixture)

        let prefs = ProjectPreferences(file: file)
        prefs.hide("/p")
        prefs.add("/q")
        prefs.unhide("/p")
        prefs.removeAdded("/q")

        let reloaded = ProjectPreferences(file: file)
        #expect(reloaded.hidden.isEmpty)
        #expect(reloaded.added.isEmpty)
    }

    @Test func addIsIdempotent() {
        let fixture = Fixture()
        let prefs = ProjectPreferences(file: prefsFile(fixture))
        prefs.add("/dup")
        prefs.add("/dup")
        #expect(prefs.added == ["/dup"])
    }
}

@MainActor
@Suite struct InventoryStoreProjectsTests {
    /// Builds a store wired to the given auto projects and a fixture-backed
    /// preferences file (never real App Support).
    private func makeStore(
        fixture: Fixture,
        auto: [ProjectRef]
    ) -> (InventoryStore, ProjectPreferences) {
        let store = InventoryStore(scanners: [])
        let prefs = ProjectPreferences(file: fixture.root.appendingPathComponent("projects.json"))
        store.configureProjects(FixtureOverrides(auto: auto), preferences: prefs)
        return (store, prefs)
    }

    @Test func manualFolderAppears() {
        let fixture = Fixture()
        let (store, _) = makeStore(fixture: fixture, auto: [])
        let dir = fixture.makeDir("manual-project")

        store.addManualProject(dir)

        #expect(store.projects.map(\.path) == [dir.path])
        let item = try? #require(store.projectItems.first { $0.ref.path == dir.path })
        #expect(item?.isManual == true)
        #expect(item?.isHidden == false)
        #expect(store.lastActionError == nil)
    }

    @Test func manualDuplicateOfAutoPathIgnored() {
        let fixture = Fixture()
        let shared = fixture.makeDir("shared-project")
        let (store, _) = makeStore(fixture: fixture, auto: [ProjectRef(path: shared.path)])

        store.addManualProject(shared)

        // Only the auto entry survives; the manual duplicate is filtered out.
        let matching = store.projectItems.filter { $0.ref.path == shared.path }
        #expect(matching.count == 1)
        #expect(matching.first?.isManual == false)
    }

    @Test func hiddenExcludedUntilShowHiddenEnabled() {
        let fixture = Fixture()
        let auto = fixture.makeDir("auto-project")
        let (store, _) = makeStore(fixture: fixture, auto: [ProjectRef(path: auto.path)])

        store.hideProject(auto.path)
        #expect(store.projects.isEmpty)
        // Still present in the full list, flagged hidden.
        let item = try? #require(store.projectItems.first { $0.ref.path == auto.path })
        #expect(item?.isHidden == true)

        store.setShowHiddenProjects(true)
        #expect(store.projects.map(\.path) == [auto.path])
    }

    @Test func nonexistentManualPathExcludedOnRefresh() {
        let fixture = Fixture()
        let (store, prefs) = makeStore(fixture: fixture, auto: [])
        let dir = fixture.makeDir("temporary-project")

        store.addManualProject(dir)
        #expect(store.projects.map(\.path) == [dir.path])

        // The folder disappears out from under us; a refresh drops it.
        try? FileManager.default.removeItem(at: dir)
        store.refreshProjects()
        #expect(store.projects.isEmpty)
        #expect(store.projectItems.isEmpty)
        // The stale entry is still recorded in preferences (not auto-pruned).
        #expect(prefs.added == [dir.path])
    }

    @Test func addManualRejectsNonexistentPath() {
        let fixture = Fixture()
        let (store, prefs) = makeStore(fixture: fixture, auto: [])
        let missing = fixture.root.appendingPathComponent("does-not-exist")

        store.addManualProject(missing)

        #expect(store.projectItems.isEmpty)
        #expect(prefs.added.isEmpty)
        #expect(store.lastActionError != nil)
    }

    @Test func hideUnhideRoundTrip() {
        let fixture = Fixture()
        let auto = fixture.makeDir("round-trip")
        let (store, _) = makeStore(fixture: fixture, auto: [ProjectRef(path: auto.path)])

        store.hideProject(auto.path)
        #expect(store.projects.isEmpty)

        store.unhideProject(auto.path)
        #expect(store.projects.map(\.path) == [auto.path])
        #expect(store.projectItems.first?.isHidden == false)
    }

    @Test func removeManualProjectDropsItem() {
        let fixture = Fixture()
        let (store, prefs) = makeStore(fixture: fixture, auto: [])
        let dir = fixture.makeDir("removable")

        store.addManualProject(dir)
        #expect(store.projects.map(\.path) == [dir.path])

        store.removeManualProject(dir.path)
        #expect(store.projects.isEmpty)
        #expect(prefs.added.isEmpty)
    }
}
