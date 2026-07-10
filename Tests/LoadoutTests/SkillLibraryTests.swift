import Foundation
import Testing
@testable import LoadoutKit

// MARK: - Mock adapter

/// A `RegistryAdapter` whose `fetch` writes a fixture skill tree
/// (`SKILL.md` + `references/a.md`) into the destination.
private struct MockAdapter: RegistryAdapter {
    let id = "skills.sh"
    let displayName = "skills.sh"
    var resolvedVersion = "1.4.0"
    var writeValidSkill = true
    var referenceContents = "reference body A"

    func featured() async throws -> [RegistrySkill] { [] }
    func search(_ query: String) async throws -> [RegistrySkill] { [] }

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        let fileManager = FileManager.default
        if writeValidSkill {
            let front = """
            ---
            name: \(skill.name)
            description: A fetched skill for tests
            ---

            # \(skill.name)
            """
            try front.write(
                to: destination.appendingPathComponent("SKILL.md"),
                atomically: true, encoding: .utf8
            )
        } else {
            // No SKILL.md — should be rejected as invalid.
            try "not a skill".write(
                to: destination.appendingPathComponent("README.md"),
                atomically: true, encoding: .utf8
            )
        }
        let references = destination.appendingPathComponent("references", isDirectory: true)
        try fileManager.createDirectory(at: references, withIntermediateDirectories: true)
        try referenceContents.write(
            to: references.appendingPathComponent("a.md"),
            atomically: true, encoding: .utf8
        )
        return resolvedVersion
    }
}

// MARK: - Suite

@MainActor
@Suite struct SkillLibraryTests {
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

    private func skill(slug: String = "deep-research") -> RegistrySkill {
        RegistrySkill(
            registry: "skills.sh",
            identifier: "owner/repo/\(slug)",
            slug: slug,
            name: slug,
            summary: "A summary",
            version: "1.4.0",
            installCount: 42,
            sourceURL: nil,
            audit: .passed
        )
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private var libraryURL: (Fixture) -> URL {
        { $0.root.appendingPathComponent("library", isDirectory: true) }
    }

    // MARK: Install happy path

    @Test func installDeploysSymlinksAndRecordsProvenance() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, codexRoot) = makeLibrary(fixture)
        let journal = journal(fixture)

        try await library.install(
            skill(), using: MockAdapter(), to: [.claudeCode, .codex], journal: journal
        )

        // Canonical copy exists with real (non-symlink) contents.
        let libraryDir = libraryURL(fixture).appendingPathComponent("deep-research", isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: libraryDir.appendingPathComponent("SKILL.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: libraryDir.appendingPathComponent("references/a.md").path
        ))
        #expect(!isSymlink(libraryDir))

        // Both agents' roots hold a symlink pointing at the canonical copy.
        for root in [claudeRoot, codexRoot] {
            let link = root.appendingPathComponent("deep-research", isDirectory: true)
            #expect(isSymlink(link))
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            #expect(target == libraryDir.path)
            // Reading through the link resolves to the canonical SKILL.md.
            #expect(FileManager.default.fileExists(
                atPath: link.appendingPathComponent("SKILL.md").path
            ))
        }

        // Lock entry fields.
        #expect(library.lockEntries.count == 1)
        let entry = try #require(library.lockEntries.first)
        #expect(entry.slug == "deep-research")
        #expect(entry.registry == "skills.sh")
        #expect(entry.identifier == "owner/repo/deep-research")
        #expect(entry.version == "1.4.0")
        #expect(entry.contentHash.count == 64)
        #expect(entry.deployments.count == 2)
        #expect(Set(entry.deployments.map(\.agent)) == [.claudeCode, .codex])
        #expect(entry.deployments.allSatisfy { $0.kind == .symlink })

        // Journal recorded a pathAdd per created path (library + 2 symlinks).
        let pathAdds = journal.entries.filter { $0.kind == .pathAdd }
        #expect(pathAdds.count == 3)
        #expect(pathAdds.contains { $0.path == libraryDir.path })
        #expect(pathAdds.contains {
            $0.path == claudeRoot.appendingPathComponent("deep-research").path
        })
    }

    // MARK: Refusals

    @Test func duplicateSlugInstallThrows() async throws {
        let fixture = Fixture()
        let (library, _, _) = makeLibrary(fixture)
        let journal = journal(fixture)

        try await library.install(skill(), using: MockAdapter(), to: [.claudeCode], journal: journal)

        await #expect(throws: SkillLibraryError.self) {
            try await library.install(skill(), using: MockAdapter(), to: [.claudeCode], journal: journal)
        }
        #expect(library.lockEntries.count == 1)
    }

    @Test func collisionWithUnmanagedDirThrows() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, _) = makeLibrary(fixture)

        // Pre-existing, unmanaged directory in the agent's root.
        let existing = claudeRoot.appendingPathComponent("deep-research", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "keep me".write(
            to: existing.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        await #expect(throws: SkillLibraryError.self) {
            try await library.install(
                skill(), using: MockAdapter(), to: [.claudeCode], journal: journal(fixture)
            )
        }

        // Nothing was installed; the unmanaged dir is untouched.
        #expect(library.lockEntries.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: libraryURL(fixture).appendingPathComponent("deep-research").path
        ))
        #expect(try String(contentsOf: existing.appendingPathComponent("SKILL.md"), encoding: .utf8) == "keep me")
    }

    // MARK: Invalid fetch leaves no debris

    @Test func invalidFetchThrowsAndLeavesNoDebris() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, codexRoot) = makeLibrary(fixture)
        let journal = journal(fixture)
        var adapter = MockAdapter()
        adapter.writeValidSkill = false

        await #expect(throws: SkillLibraryError.self) {
            try await library.install(
                skill(), using: adapter, to: [.claudeCode, .codex], journal: journal
            )
        }

        #expect(library.lockEntries.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: libraryURL(fixture).appendingPathComponent("deep-research").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: claudeRoot.appendingPathComponent("deep-research").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: codexRoot.appendingPathComponent("deep-research").path
        ))
        // Fetch failed before any journaled mutation.
        #expect(journal.entries.isEmpty)
        // No orphaned fetch temp dirs remain.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("loadout-fetch-") }
        #expect(leftovers.isEmpty)
    }

    // MARK: Content hash

    @Test func contentHashIsDeterministicAndSensitive() throws {
        let fixture = Fixture()
        let a = fixture.makeDir("tree-a")
        let b = fixture.makeDir("tree-b")
        for dir in [a, b] {
            try "---\nname: x\ndescription: y\n---\n".write(
                to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
            let refs = dir.appendingPathComponent("references", isDirectory: true)
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            try "same".write(to: refs.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        }

        let hashA = try TreeHash.hash(directory: a)
        let hashB = try TreeHash.hash(directory: b)
        #expect(hashA == hashB)

        // Change a single byte -> hash changes.
        try "diff".write(
            to: b.appendingPathComponent("references/a.md"), atomically: true, encoding: .utf8
        )
        #expect(try TreeHash.hash(directory: b) != hashA)
    }

    // MARK: Remove

    @Test func removeDeletesSymlinksShelvesCopyAndDropsEntry() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, codexRoot) = makeLibrary(fixture)
        let journal = journal(fixture)

        try await library.install(
            skill(), using: MockAdapter(), to: [.claudeCode, .codex], journal: journal
        )
        try await library.remove(slug: "deep-research", journal: journal)

        // Symlinks gone.
        #expect(!isSymlink(claudeRoot.appendingPathComponent("deep-research")))
        #expect(!isSymlink(codexRoot.appendingPathComponent("deep-research")))
        #expect(!FileManager.default.fileExists(
            atPath: claudeRoot.appendingPathComponent("deep-research").path
        ))

        // Library copy moved off to the shelf, not deleted.
        #expect(!FileManager.default.fileExists(
            atPath: libraryURL(fixture).appendingPathComponent("deep-research").path
        ))
        let move = try #require(journal.entries.first { $0.kind == .directoryMove })
        let shelved = try #require(move.backupPath)
        #expect(FileManager.default.fileExists(
            atPath: (shelved as NSString).appendingPathComponent("SKILL.md")
        ))

        // Lock entry dropped and persisted.
        #expect(library.lockEntries.isEmpty)
    }

    // MARK: Lockfile persistence

    @Test func lockfilePersistsAcrossReinit() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, codexRoot) = makeLibrary(fixture)

        try await library.install(
            skill(), using: MockAdapter(), to: [.claudeCode], journal: journal(fixture)
        )

        // Re-init a fresh library over the same directory/roots.
        let reloaded = SkillLibrary(
            directory: libraryURL(fixture),
            deployRoots: [.claudeCode: claudeRoot, .codex: codexRoot]
        )
        #expect(reloaded.lockEntries.count == 1)
        let entry = try #require(reloaded.lockEntries.first)
        #expect(entry.slug == "deep-research")
        #expect(entry.version == "1.4.0")
        #expect(entry.deployments.count == 1)
    }

    // MARK: Journal revert of a deployment

    @Test func revertOfDeploymentPathAddDeletesSymlink() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, _) = makeLibrary(fixture)
        let journal = journal(fixture)

        try await library.install(skill(), using: MockAdapter(), to: [.claudeCode], journal: journal)

        let linkPath = claudeRoot.appendingPathComponent("deep-research").path
        let deploymentAdd = try #require(journal.entries.first {
            $0.kind == .pathAdd && $0.path == linkPath
        })
        #expect(isSymlink(URL(fileURLWithPath: linkPath)))

        try journal.revert(deploymentAdd)

        // Symlink removed as a symlink; canonical copy untouched.
        #expect(!isSymlink(URL(fileURLWithPath: linkPath)))
        #expect(!FileManager.default.fileExists(atPath: linkPath))
        #expect(FileManager.default.fileExists(
            atPath: libraryURL(fixture).appendingPathComponent("deep-research/SKILL.md").path
        ))
    }
}
