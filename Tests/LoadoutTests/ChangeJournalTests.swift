import Foundation
import Testing
@testable import LoadoutKit

@MainActor
@Suite struct ChangeJournalTests {
    @Test func revertOfFileEditRestoresByteIdenticalOriginal() throws {
        let fixture = Fixture()
        let file = fixture.writeFile("original contents\nwith two lines\n", at: "config.toml")
        let originalBytes = try Data(contentsOf: file)
        let journal = ChangeJournal(directory: fixture.makeDir("journal"))

        let change = try journal.recordFileEdit(agent: .codex, summary: "Edit", file: file)
        try Data("mutated".utf8).write(to: file, options: .atomic)

        try journal.revert(change)

        #expect(try Data(contentsOf: file) == originalBytes)
        #expect(journal.entries.first?.isReverted == true)
    }

    @Test func revertOfEditToMissingFileDeletesIt() throws {
        let fixture = Fixture()
        let file = fixture.root.appendingPathComponent("settings.json")
        let journal = ChangeJournal(directory: fixture.makeDir("journal"))

        let change = try journal.recordFileEdit(agent: .claudeCode, summary: "Create", file: file)
        #expect(change.backupPath == nil)
        try Data("{}".utf8).write(to: file, options: .atomic)

        try journal.revert(change)

        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func revertOfDirectoryMoveRestoresContents() throws {
        let fixture = Fixture()
        let skillDir = fixture.writeSkill(slug: "alpha", under: ["skills"])
        fixture.writeFile("extra", at: "skills", "alpha", "notes.txt")
        let journal = ChangeJournal(directory: fixture.makeDir("journal"))

        let change = try journal.recordDirectoryMove(
            agent: .claudeCode, summary: "Uninstall alpha", directory: skillDir
        )

        #expect(!FileManager.default.fileExists(atPath: skillDir.path))
        let shelved = try #require(change.backupPath)
        #expect(FileManager.default.fileExists(
            atPath: (shelved as NSString).appendingPathComponent("notes.txt")
        ))

        try journal.revert(change)

        #expect(FileManager.default.fileExists(
            atPath: skillDir.appendingPathComponent("SKILL.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: skillDir.appendingPathComponent("notes.txt").path
        ))
        #expect(!FileManager.default.fileExists(atPath: shelved))
    }

    @Test func journalPersistsAcrossReinit() throws {
        let fixture = Fixture()
        let journalDir = fixture.makeDir("journal")
        let file = fixture.writeFile("v1", at: "config.toml")

        let first = ChangeJournal(directory: journalDir)
        let change = try first.recordFileEdit(agent: .codex, summary: "Edit config", file: file)
        try Data("v2".utf8).write(to: file, options: .atomic)

        let reloaded = ChangeJournal(directory: journalDir)
        #expect(reloaded.entries.count == 1)
        let entry = try #require(reloaded.entries.first)
        #expect(entry.id == change.id)
        #expect(entry.summary == "Edit config")
        #expect(entry.kind == .fileEdit)
        #expect(entry.isReverted == false)

        // The reloaded journal can still revert the change.
        try reloaded.revert(entry)
        #expect(try String(contentsOf: file, encoding: .utf8) == "v1")

        let third = ChangeJournal(directory: journalDir)
        #expect(third.entries.first?.isReverted == true)
    }
}
