import Foundation
import Testing
@testable import LoadoutKit

/// Tests for `SkillLibrary.adopt(_:syncTo:journal:)` — adopting an existing
/// unmanaged user skill into the library. All filesystem work happens inside
/// per-test `Fixture` temp directories; nothing touches real agent dirs.
@MainActor
@Suite struct SkillLibraryAdoptTests {

    // MARK: Helpers

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

    private func libraryURL(_ fixture: Fixture, slug: String) -> URL {
        fixture.root
            .appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
    }

    /// Creates a real skill directory (SKILL.md + references/a.md) under the
    /// given agent's skills root and returns its `SkillInstallation`.
    private func makeUserSkill(
        _ fixture: Fixture,
        slug: String = "my-skill",
        agent: AgentID = .claudeCode,
        origin: SkillOrigin = .user
    ) -> SkillInstallation {
        let agentDir = agent == .claudeCode ? "claude" : "codex"
        let dir = fixture.writeSkill(
            slug: slug, under: [agentDir, "skills"], description: "an adopted skill"
        )
        fixture.writeFile("reference body", at: agentDir, "skills", slug, "references", "a.md")
        return SkillInstallation(
            agent: agent,
            slug: slug,
            origin: origin,
            directory: dir,
            metadata: SkillMetadata(name: slug, description: "an adopted skill"),
            isEnabled: true,
            lastModified: nil
        )
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// True when the path is a real (non-symlink) directory.
    private func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    // MARK: Happy path

    @Test func adoptMovesToLibraryReplacesWithSymlinkAndSyncs() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, codexRoot) = makeLibrary(fixture)
        let journal = journal(fixture)
        let installation = makeUserSkill(fixture)
        let originalManifest = try bytes(installation.directory.appendingPathComponent("SKILL.md"))

        // syncTo includes the origin agent — it must be skipped, not collide
        // with its own replacement symlink.
        try await library.adopt(installation, syncTo: [.claudeCode, .codex], journal: journal)

        // Canonical copy is a real directory in the library.
        let libraryDir = libraryURL(fixture, slug: "my-skill")
        #expect(isRealDirectory(libraryDir))
        #expect(FileManager.default.fileExists(
            atPath: libraryDir.appendingPathComponent("references/a.md").path
        ))

        // The original path is now a symlink to the library copy, and the
        // content is byte-identical when read through the old path.
        let originalDir = claudeRoot.appendingPathComponent("my-skill", isDirectory: true)
        #expect(isSymlink(originalDir))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: originalDir.path) == libraryDir.path)
        #expect(try bytes(originalDir.appendingPathComponent("SKILL.md")) == originalManifest)

        // The sync agent got its own symlink, readable through to the copy.
        let codexLink = codexRoot.appendingPathComponent("my-skill", isDirectory: true)
        #expect(isSymlink(codexLink))
        #expect(FileManager.default.fileExists(
            atPath: codexLink.appendingPathComponent("SKILL.md").path
        ))

        // Lock entry: local provenance pointing back at the original path.
        #expect(library.lockEntries.count == 1)
        let entry = try #require(library.lockEntries.first)
        #expect(entry.slug == "my-skill")
        #expect(entry.registry == "local")
        #expect(entry.identifier == originalDir.path)
        #expect(entry.contentHash.count == 64)
        #expect(entry.version == "local-\(entry.contentHash.prefix(12))")
        #expect(entry.deployments.count == 2)
        #expect(Set(entry.deployments.map(\.agent)) == [.claudeCode, .codex])
        #expect(entry.deployments.allSatisfy { $0.kind == .symlink })
        #expect(entry.deployments.contains { $0.path == originalDir.path })
        #expect(entry.deployments.contains { $0.path == codexLink.path })

        // Journal: pathAdd for the sync symlink ONLY — never for the library
        // move or the origin replacement (the no-content-loss design).
        let adds = journal.entries.filter { $0.kind == .pathAdd }
        #expect(adds.count == 1)
        #expect(adds.first?.path == codexLink.path)
        #expect(journal.entries.count == 1)

        // Lockfile persisted: a fresh library over the same dirs sees it.
        let reloaded = SkillLibrary(
            directory: fixture.root.appendingPathComponent("library", isDirectory: true),
            deployRoots: [.claudeCode: claudeRoot, .codex: codexRoot]
        )
        #expect(reloaded.lockEntries.first?.registry == "local")
    }

    // MARK: Refusals — each leaves the original directory untouched

    @Test func adoptRefusesNonUserOrigin() async throws {
        let fixture = Fixture()
        let (library, _, _) = makeLibrary(fixture)
        let installation = makeUserSkill(fixture, origin: .plugin(name: "some-pack"))
        let manifest = installation.directory.appendingPathComponent("SKILL.md")
        let before = try bytes(manifest)

        await #expect(throws: SkillLibraryError.self) {
            try await library.adopt(installation, syncTo: [.codex], journal: journal(fixture))
        }

        #expect(isRealDirectory(installation.directory))
        #expect(try bytes(manifest) == before)
        #expect(library.lockEntries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: libraryURL(fixture, slug: "my-skill").path))
    }

    @Test func adoptRefusesAlreadyManagedSlug() async throws {
        let fixture = Fixture()
        let (library, _, _) = makeLibrary(fixture)
        let journal = journal(fixture)

        // First adopt puts "my-skill" in the lockfile.
        let first = makeUserSkill(fixture, agent: .claudeCode)
        try await library.adopt(first, syncTo: [], journal: journal)

        // A second unmanaged dir with the same slug (other agent) is refused.
        let second = makeUserSkill(fixture, agent: .codex)
        let manifest = second.directory.appendingPathComponent("SKILL.md")
        let before = try bytes(manifest)

        await #expect(throws: SkillLibraryError.self) {
            try await library.adopt(second, syncTo: [], journal: journal)
        }

        #expect(isRealDirectory(second.directory))
        #expect(try bytes(manifest) == before)
        #expect(library.lockEntries.count == 1)
    }

    @Test func adoptRefusesSymlinkSource() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, _) = makeLibrary(fixture)

        // A real skill elsewhere, with the "installation" path being a
        // symlink to it — as if it were already managed.
        let realDir = fixture.writeSkill(slug: "my-skill", under: ["elsewhere"])
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let linkDir = claudeRoot.appendingPathComponent("my-skill", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        let manifest = realDir.appendingPathComponent("SKILL.md")
        let before = try bytes(manifest)

        let installation = SkillInstallation(
            agent: .claudeCode, slug: "my-skill", origin: .user,
            directory: linkDir,
            metadata: SkillMetadata(name: "my-skill", description: "d"),
            isEnabled: true, lastModified: nil
        )

        await #expect(throws: SkillLibraryError.self) {
            try await library.adopt(installation, syncTo: [.codex], journal: journal(fixture))
        }

        // The symlink is still a symlink and the target content is untouched.
        #expect(isSymlink(linkDir))
        #expect(try bytes(manifest) == before)
        #expect(library.lockEntries.isEmpty)
    }

    @Test func adoptRefusesCollisionInTargetAgent() async throws {
        let fixture = Fixture()
        let (library, _, codexRoot) = makeLibrary(fixture)
        let installation = makeUserSkill(fixture, agent: .claudeCode)
        let manifest = installation.directory.appendingPathComponent("SKILL.md")
        let before = try bytes(manifest)

        // Pre-existing unmanaged same-slug directory in the sync target.
        let colliding = fixture.writeSkill(slug: "my-skill", under: ["codex", "skills"])
        let collidingManifest = colliding.appendingPathComponent("SKILL.md")
        let collidingBefore = try bytes(collidingManifest)

        await #expect(throws: SkillLibraryError.self) {
            try await library.adopt(installation, syncTo: [.codex], journal: journal(fixture))
        }

        // Original directory untouched (real dir, byte-identical).
        #expect(isRealDirectory(installation.directory))
        #expect(try bytes(manifest) == before)
        // The colliding unmanaged dir is untouched too.
        #expect(isRealDirectory(codexRoot.appendingPathComponent("my-skill", isDirectory: true)))
        #expect(try bytes(collidingManifest) == collidingBefore)
        #expect(library.lockEntries.isEmpty)
    }

    // MARK: Mid-failure restore

    @Test func adoptMidFailureRestoresOriginalState() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, _) = makeLibrary(fixture)
        let journal = journal(fixture)
        let installation = makeUserSkill(fixture, agent: .claudeCode)
        let before = try bytes(installation.directory.appendingPathComponent("SKILL.md"))

        // Collision on the sync agent surfaces only AFTER the move into the
        // library and the origin replacement symlink have happened.
        fixture.writeSkill(slug: "my-skill", under: ["codex", "skills"])

        await #expect(throws: SkillLibraryError.self) {
            try await library.adopt(installation, syncTo: [.codex], journal: journal)
        }

        // Original directory restored: a real directory again (not the
        // replacement symlink), full content back in place.
        let originalDir = claudeRoot.appendingPathComponent("my-skill", isDirectory: true)
        #expect(isRealDirectory(originalDir))
        #expect(!isSymlink(originalDir))
        #expect(try bytes(originalDir.appendingPathComponent("SKILL.md")) == before)
        #expect(FileManager.default.fileExists(
            atPath: originalDir.appendingPathComponent("references/a.md").path
        ))

        // No library copy, no lock entry, no unreverted journal debris.
        #expect(!FileManager.default.fileExists(atPath: libraryURL(fixture, slug: "my-skill").path))
        #expect(library.lockEntries.isEmpty)
        #expect(journal.entries.allSatisfy { $0.isReverted })
    }

    // MARK: Safety — no sequence of journal reverts may delete the content

    @Test func revertingEveryAdoptJournalEntryNeverDeletesContent() async throws {
        let fixture = Fixture()
        let (library, claudeRoot, _) = makeLibrary(fixture)
        let journal = journal(fixture)
        let installation = makeUserSkill(fixture)
        let before = try bytes(installation.directory.appendingPathComponent("SKILL.md"))

        let entriesBefore = journal.entries.count
        try await library.adopt(installation, syncTo: [.codex], journal: journal)
        let adoptEntries = Array(journal.entries.dropFirst(entriesBefore))
        #expect(!adoptEntries.isEmpty)

        // Revert EVERY journal entry the adopt produced, newest first.
        for change in adoptEntries.reversed() {
            try journal.revert(change)
        }

        // The invariant: the skill content still exists somewhere on disk —
        // in the library or at the original path — byte-identical.
        let libraryManifest = libraryURL(fixture, slug: "my-skill")
            .appendingPathComponent("SKILL.md")
        let originalManifest = claudeRoot
            .appendingPathComponent("my-skill", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        let survivor = [libraryManifest, originalManifest].first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let survivingManifest = try #require(survivor)
        #expect(try bytes(survivingManifest) == before)
    }
}
