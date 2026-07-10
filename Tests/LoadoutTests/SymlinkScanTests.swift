import Foundation
import Testing
@testable import Loadout

/// Symlinked skill directories are the D2 deployment mechanism — the
/// scanner must treat them exactly like real directories.
@Suite struct SymlinkScanTests {
    @Test func discoversSymlinkedSkillDirectories() throws {
        let fixture = Fixture()
        // Canonical skill outside the skills dir, symlinked into it.
        fixture.writeSkill(slug: "canonical-probe", under: ["library"])
        let canonical = fixture.root
            .appendingPathComponent("library")
            .appendingPathComponent("canonical-probe")
        let skillsDir = fixture.makeDir("skills")
        try FileManager.default.createSymbolicLink(
            at: skillsDir.appendingPathComponent("linked-probe"),
            withDestinationURL: canonical
        )
        fixture.writeSkill(slug: "real-skill", under: ["skills"])

        let found = SkillScan.installations(in: skillsDir)

        #expect(found.map(\.slug) == ["linked-probe", "real-skill"])
    }

    @Test func danglingSymlinkIsSkippedGracefully() throws {
        let fixture = Fixture()
        let skillsDir = fixture.makeDir("skills")
        try FileManager.default.createSymbolicLink(
            at: skillsDir.appendingPathComponent("dangling"),
            withDestinationURL: fixture.root.appendingPathComponent("gone")
        )
        fixture.writeSkill(slug: "real-skill", under: ["skills"])

        let found = SkillScan.installations(in: skillsDir)

        #expect(found.map(\.slug) == ["real-skill"])
    }
}
