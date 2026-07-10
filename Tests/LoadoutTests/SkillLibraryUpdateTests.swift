import Foundation
import Testing
@testable import LoadoutKit

// MARK: - Fixture manifest + mock adapters

/// SKILL.md that is byte-identical across install and update, so it never
/// shows up as a change (only the reference files differ).
private let sharedManifest = """
---
name: deep-research
description: A fetched skill for update tests
---

# deep-research
"""

/// Writes the ORIGINAL library tree: SKILL.md + three reference files.
private struct InstallAdapter: RegistryAdapter {
    let id = "skills.sh"
    let displayName = "skills.sh"

    func featured() async throws -> [RegistrySkill] { [] }
    func search(_ query: String) async throws -> [RegistrySkill] { [] }

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        try write(sharedManifest, "SKILL.md", into: destination)
        try write("line1\nline2\nline3\n", "references/a.md", into: destination)
        try write("to be removed\n", "references/old.md", into: destination)
        return "v1"
    }
}

/// Serves a CHANGED tree vs. `InstallAdapter`: SKILL.md identical,
/// references/a.md modified, references/old.md gone, references/new.md added.
private struct UpdateAdapter: RegistryAdapter {
    let id = "skills.sh"
    let displayName = "skills.sh"
    var writeValidSkill = true

    func featured() async throws -> [RegistrySkill] { [] }
    func search(_ query: String) async throws -> [RegistrySkill] { [] }

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        if writeValidSkill {
            try write(sharedManifest, "SKILL.md", into: destination)
        } else {
            try write("no frontmatter here", "README.md", into: destination)
        }
        try write("line1\nCHANGED\nline3\n", "references/a.md", into: destination)
        try write("brand new\n", "references/new.md", into: destination)
        return "v2"
    }
}

private func write(_ contents: String, _ relative: String, into destination: URL) throws {
    let url = destination.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Suite

@MainActor
@Suite struct SkillLibraryUpdateTests {
    private func makeLibrary(_ fixture: Fixture) -> (library: SkillLibrary, claude: URL, codex: URL) {
        let claudeRoot = fixture.root.appendingPathComponent("claude/skills", isDirectory: true)
        let codexRoot = fixture.root.appendingPathComponent("codex/skills", isDirectory: true)
        let library = SkillLibrary(
            directory: fixture.root.appendingPathComponent("library", isDirectory: true),
            deployRoots: [.claudeCode: claudeRoot, .codex: codexRoot]
        )
        return (library, claudeRoot, codexRoot)
    }

    private func journal(_ fixture: Fixture) -> ChangeJournal {
        ChangeJournal(directory: fixture.makeDir("journal"))
    }

    private func skill() -> RegistrySkill {
        RegistrySkill(
            registry: "skills.sh", identifier: "owner/repo/deep-research",
            slug: "deep-research", name: "deep-research", summary: nil,
            version: nil, installCount: nil, sourceURL: nil, audit: nil
        )
    }

    private func libraryDir(_ fixture: Fixture) -> URL {
        fixture.root
            .appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent("deep-research", isDirectory: true)
    }

    /// Installs the original tree and returns the library + its content hash.
    private func installed(
        _ fixture: Fixture, agents: [AgentID] = [.claudeCode]
    ) async throws -> (library: SkillLibrary, claude: URL, codex: URL, journal: ChangeJournal, originalHash: String) {
        let (library, claude, codex) = makeLibrary(fixture)
        let journal = journal(fixture)
        try await library.install(skill(), using: InstallAdapter(), to: agents, journal: journal)
        let hash = try TreeHash.hash(directory: libraryDir(fixture))
        return (library, claude, codex, journal, hash)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - stageUpdate

    @Test func stageUpdateComputesChangesWithoutMutatingLibrary() async throws {
        let fixture = Fixture()
        let ctx = try await installed(fixture)

        let staged = try await ctx.library.stageUpdate(slug: "deep-research", using: UpdateAdapter())

        // Version + change set (sorted by relative path; SKILL.md unchanged).
        #expect(staged.newVersion == "v2")
        #expect(staged.changes.count == 3)

        let byPath = Dictionary(uniqueKeysWithValues: staged.changes.map { ($0.relativePath, $0) })
        let modified = try #require(byPath["references/a.md"])
        #expect(modified.kind == .modified)
        #expect(modified.diff == ["  line1", "- line2", "+ CHANGED", "  line3"])

        let added = try #require(byPath["references/new.md"])
        #expect(added.kind == .added)
        #expect(added.diff == ["+ brand new"])

        let removed = try #require(byPath["references/old.md"])
        #expect(removed.kind == .removed)
        #expect(removed.diff == ["- to be removed"])

        // No SKILL.md entry (byte-identical across versions).
        #expect(byPath["SKILL.md"] == nil)

        // Library + lock entry are untouched.
        #expect(try TreeHash.hash(directory: libraryDir(fixture)) == ctx.originalHash)
        #expect(ctx.library.lockEntries.first?.version == "v1")

        // Staging dir holds the new tree.
        #expect(read(staged.stagingDirectory.appendingPathComponent("references/a.md")) == "line1\nCHANGED\nline3\n")
        #expect(read(staged.stagingDirectory.appendingPathComponent("references/new.md")) == "brand new\n")
        #expect(!FileManager.default.fileExists(
            atPath: staged.stagingDirectory.appendingPathComponent("references/old.md").path
        ))

        ctx.library.discardUpdate(staged)
    }

    @Test func stageUpdateThrowsForUnknownSlug() async throws {
        let fixture = Fixture()
        let (library, _, _) = makeLibrary(fixture)
        await #expect(throws: SkillLibraryError.self) {
            _ = try await library.stageUpdate(slug: "missing", using: UpdateAdapter())
        }
    }

    @Test func stageUpdateRejectsInvalidFetchAndLeavesNoStagingDir() async throws {
        let fixture = Fixture()
        let ctx = try await installed(fixture)
        var adapter = UpdateAdapter()
        adapter.writeValidSkill = false

        await #expect(throws: SkillLibraryError.self) {
            _ = try await ctx.library.stageUpdate(slug: "deep-research", using: adapter)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("loadout-update-") }
        #expect(leftovers.isEmpty)
        #expect(try TreeHash.hash(directory: libraryDir(fixture)) == ctx.originalHash)
    }

    // MARK: - applyUpdate happy path

    @Test func applyUpdateReplacesCopyRefreshesEntryAndKeepsSymlinkResolving() async throws {
        let fixture = Fixture()
        let ctx = try await installed(fixture)
        let oldEntry = try #require(ctx.library.lockEntries.first)

        let staged = try await ctx.library.stageUpdate(slug: "deep-research", using: UpdateAdapter())
        try await ctx.library.applyUpdate(staged, journal: ctx.journal)

        // Library copy is now the new tree.
        let dir = libraryDir(fixture)
        #expect(read(dir.appendingPathComponent("references/a.md")) == "line1\nCHANGED\nline3\n")
        #expect(read(dir.appendingPathComponent("references/new.md")) == "brand new\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("references/old.md").path))

        // Lock entry version/hash/fetchedAt refreshed; identity preserved.
        let entry = try #require(ctx.library.lockEntries.first)
        #expect(entry.version == "v2")
        #expect(entry.contentHash == (try TreeHash.hash(directory: dir)))
        #expect(entry.contentHash != oldEntry.contentHash)
        #expect(entry.identifier == oldEntry.identifier)
        #expect(entry.deployments == oldEntry.deployments)

        // Old copy is shelved (not deleted).
        let move = try #require(ctx.journal.entries.first { $0.kind == .directoryMove })
        let shelved = try #require(move.backupPath)
        #expect(read(URL(fileURLWithPath: shelved).appendingPathComponent("references/old.md")) == "to be removed\n")

        // The deployment symlink resolves to the updated content.
        let link = ctx.claude.appendingPathComponent("deep-research", isDirectory: true)
        #expect((try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true)
        #expect(read(link.appendingPathComponent("references/a.md")) == "line1\nCHANGED\nline3\n")
        #expect(!FileManager.default.fileExists(atPath: link.appendingPathComponent("references/old.md").path))

        // Staging dir consumed by the move.
        #expect(!FileManager.default.fileExists(atPath: staged.stagingDirectory.path))
    }

    // MARK: - Undo sequence

    @Test func revertNewestFirstRestoresOriginalTreeByteForByte() async throws {
        let fixture = Fixture()
        let ctx = try await installed(fixture)

        let staged = try await ctx.library.stageUpdate(slug: "deep-research", using: UpdateAdapter())

        let before = ctx.journal.entries.count
        try await ctx.library.applyUpdate(staged, journal: ctx.journal)

        // The two entries applyUpdate recorded, in append order.
        let updateChanges = Array(ctx.journal.entries[before...])
        #expect(updateChanges.count == 2)
        #expect(updateChanges[0].kind == .directoryMove)
        #expect(updateChanges[1].kind == .pathAdd)

        // Reverting newest-first: pathAdd deletes the new copy, then
        // directoryMove restores the old one (its move-back needs a free path).
        for change in updateChanges.reversed() {
            try ctx.journal.revert(change)
        }

        // Library tree is byte-identical to the original pre-update tree.
        let dir = libraryDir(fixture)
        #expect(try TreeHash.hash(directory: dir) == ctx.originalHash)
        #expect(read(dir.appendingPathComponent("references/a.md")) == "line1\nline2\nline3\n")
        #expect(read(dir.appendingPathComponent("references/old.md")) == "to be removed\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("references/new.md").path))
    }

    // MARK: - Vanished staging dir

    @Test func applyUpdateWithMissingStagingDirThrowsAndLeavesLibraryUntouched() async throws {
        let fixture = Fixture()
        let ctx = try await installed(fixture)

        let staged = try await ctx.library.stageUpdate(slug: "deep-research", using: UpdateAdapter())
        try FileManager.default.removeItem(at: staged.stagingDirectory)

        await #expect(throws: SkillLibraryError.self) {
            try await ctx.library.applyUpdate(staged, journal: ctx.journal)
        }

        // Library copy, lock entry, and journal all unchanged.
        #expect(try TreeHash.hash(directory: libraryDir(fixture)) == ctx.originalHash)
        #expect(ctx.library.lockEntries.first?.version == "v1")
        #expect(!ctx.journal.entries.contains { $0.kind == .directoryMove })
    }
}
