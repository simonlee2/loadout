import Foundation
import Testing
@testable import LoadoutKit

// MARK: - Fixtures

/// Writes a minimal skill tree (`SKILL.md` + `references/a.md`) into a fresh
/// directory under `parent` and returns it.
@discardableResult
private func makeSkillTree(
    in parent: URL, name: String = "Deep Research",
    reference: String = "reference body A"
) throws -> URL {
    let fileManager = FileManager.default
    let dir = parent.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
    let references = dir.appendingPathComponent("references", isDirectory: true)
    try fileManager.createDirectory(at: references, withIntermediateDirectories: true)
    let front = """
    ---
    name: \(name)
    description: A skill for tests
    ---

    # \(name)
    """
    try front.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try reference.write(to: references.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    return dir
}

// MARK: - FolderCollection

@MainActor
@Suite struct FolderCollectionTests {
    private func collection(_ fixture: Fixture) -> FolderCollection {
        FolderCollection(directory: fixture.root.appendingPathComponent("collection", isDirectory: true))
    }

    @Test func publishThenListRoundTrips() async throws {
        let fixture = Fixture()
        let store = collection(fixture)
        let source = try makeSkillTree(in: fixture.makeDir("work"))

        try await store.publish(slug: "deep-research", name: "Deep Research", summary: "Finds things", directory: source)

        let listed = try await store.list()
        #expect(listed.count == 1)
        let skill = try #require(listed.first)
        #expect(skill.slug == "deep-research")
        #expect(skill.name == "Deep Research")
        #expect(skill.summary == "Finds things")
        #expect(skill.contentHash == (try TreeHash.hash(directory: source)))
    }

    @Test func downloadRestoresTreeAndVerifiesHash() async throws {
        let fixture = Fixture()
        let store = collection(fixture)
        let source = try makeSkillTree(in: fixture.makeDir("work"))
        let sourceHash = try TreeHash.hash(directory: source)

        try await store.publish(slug: "deep-research", name: "Deep Research", summary: nil, directory: source)

        let destination = fixture.root.appendingPathComponent("out", isDirectory: true)
        let hash = try await store.download(slug: "deep-research", to: destination)

        #expect(hash == sourceHash)
        #expect(try TreeHash.hash(directory: destination) == sourceHash)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("references/a.md").path))
    }

    @Test func overwriteUpdatesHashAndTimestamp() async throws {
        let fixture = Fixture()
        let store = collection(fixture)
        let first = try makeSkillTree(in: fixture.makeDir("v1"), reference: "version one")
        try await store.publish(slug: "deep-research", name: "Deep Research", summary: nil, directory: first)
        let before = try #require(try await store.list().first)

        let second = try makeSkillTree(in: fixture.makeDir("v2"), reference: "version two — changed")
        try await store.publish(slug: "deep-research", name: "Deep Research v2", summary: "now with more", directory: second)
        let after = try #require(try await store.list().first)

        #expect(try await store.list().count == 1)
        #expect(after.contentHash != before.contentHash)
        #expect(after.updatedAt > before.updatedAt)
        #expect(after.name == "Deep Research v2")
        #expect(after.summary == "now with more")

        // The downloaded content reflects the overwrite.
        let destination = fixture.root.appendingPathComponent("out", isDirectory: true)
        try await store.download(slug: "deep-research", to: destination)
        let body = try String(contentsOf: destination.appendingPathComponent("references/a.md"), encoding: .utf8)
        #expect(body == "version two — changed")
    }

    @Test func removeDropsSkill() async throws {
        let fixture = Fixture()
        let store = collection(fixture)
        let source = try makeSkillTree(in: fixture.makeDir("work"))
        try await store.publish(slug: "deep-research", name: "Deep Research", summary: nil, directory: source)

        try await store.remove(slug: "deep-research")

        #expect(try await store.list().isEmpty)
        await #expect(throws: CollectionError.self) {
            let out = fixture.root.appendingPathComponent("out", isDirectory: true)
            try await store.download(slug: "deep-research", to: out)
        }
    }

    @Test func indexPersistsAcrossReinit() async throws {
        let fixture = Fixture()
        let directory = fixture.root.appendingPathComponent("collection", isDirectory: true)
        let source = try makeSkillTree(in: fixture.makeDir("work"))
        do {
            let store = FolderCollection(directory: directory)
            try await store.publish(slug: "deep-research", name: "Deep Research", summary: "s", directory: source)
        }

        // Fresh instance over the same folder sees the published skill.
        let reopened = FolderCollection(directory: directory)
        let listed = try await reopened.list()
        #expect(listed.count == 1)
        #expect(listed.first?.slug == "deep-research")
        #expect(listed.first?.summary == "s")
    }

    @Test func downloadUnknownSlugThrowsNotFound() async throws {
        let fixture = Fixture()
        let store = collection(fixture)
        await #expect(throws: CollectionError.self) {
            let out = fixture.root.appendingPathComponent("out", isDirectory: true)
            try await store.download(slug: "nope", to: out)
        }
    }

    @Test func isAvailableWhenVolumeExists() async throws {
        let fixture = Fixture()
        // Directory need not exist yet; its parent volume does.
        #expect(collection(fixture).isAvailable)
        #expect(collection(fixture).unavailabilityReason == nil)
    }
}

// MARK: - CollectionRegistryAdapter over FolderCollection

@MainActor
@Suite struct CollectionRegistryAdapterTests {
    @Test func featuredMapsCollectionEntries() async throws {
        let fixture = Fixture()
        let store = FolderCollection(directory: fixture.makeDir("collection"))
        let source = try makeSkillTree(in: fixture.makeDir("work"))
        try await store.publish(slug: "deep-research", name: "Deep Research", summary: "Finds things", directory: source)

        let adapter = CollectionRegistryAdapter(collection: store)
        #expect(adapter.id == "my-collection")
        #expect(adapter.displayName == "My Collection")

        let featured = try await adapter.featured()
        #expect(featured.count == 1)
        let skill = try #require(featured.first)
        #expect(skill.registry == "my-collection")
        #expect(skill.identifier == "deep-research")
        #expect(skill.slug == "deep-research")
        #expect(skill.name == "Deep Research")
        #expect(skill.summary == "Finds things")
        #expect(skill.version?.hasPrefix("col-") == true)
    }

    @Test func searchFiltersByQuery() async throws {
        let fixture = Fixture()
        let store = FolderCollection(directory: fixture.makeDir("collection"))
        try await store.publish(
            slug: "deep-research", name: "Deep Research", summary: nil,
            directory: try makeSkillTree(in: fixture.makeDir("a"))
        )
        try await store.publish(
            slug: "pdf-tools", name: "PDF Tools", summary: nil,
            directory: try makeSkillTree(in: fixture.makeDir("b"))
        )
        let adapter = CollectionRegistryAdapter(collection: store)

        #expect(try await adapter.search("pdf").map(\.slug) == ["pdf-tools"])
        #expect(try await adapter.search("").count == 2)
    }

    @Test func fetchLandsFilesAndReturnsVersionPrefix() async throws {
        let fixture = Fixture()
        let store = FolderCollection(directory: fixture.makeDir("collection"))
        let source = try makeSkillTree(in: fixture.makeDir("work"))
        try await store.publish(slug: "deep-research", name: "Deep Research", summary: nil, directory: source)
        let adapter = CollectionRegistryAdapter(collection: store)

        let skill = try #require(try await adapter.featured().first)
        let destination = fixture.root.appendingPathComponent("dest", isDirectory: true)
        let version = try await adapter.fetch(skill, to: destination)

        #expect(version.hasPrefix("col-"))
        // fetch's returned version matches the browse row's version.
        #expect(version == skill.version)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("references/a.md").path))
    }

    @Test func installsThroughSkillLibrary() async throws {
        let fixture = Fixture()
        let store = FolderCollection(directory: fixture.makeDir("collection"))
        try await store.publish(
            slug: "deep-research", name: "Deep Research", summary: nil,
            directory: try makeSkillTree(in: fixture.makeDir("work"))
        )
        let adapter = CollectionRegistryAdapter(collection: store)

        let claudeRoot = fixture.root.appendingPathComponent("claude/skills", isDirectory: true)
        let library = SkillLibrary(
            directory: fixture.root.appendingPathComponent("library", isDirectory: true),
            deployRoots: [.claudeCode: claudeRoot]
        )
        let journal = ChangeJournal(directory: fixture.makeDir("journal"))

        let skill = try #require(try await adapter.featured().first)
        try await library.install(skill, using: adapter, to: [.claudeCode], journal: journal)

        let entry = try #require(library.lockEntries.first)
        #expect(entry.slug == "deep-research")
        #expect(entry.registry == "my-collection")
        #expect(entry.version.hasPrefix("col-"))
        let link = claudeRoot.appendingPathComponent("deep-research", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: link.appendingPathComponent("SKILL.md").path))
    }
}

// MARK: - CloudKitArchive (zip/unzip round-trip)

@Suite struct CloudKitArchiveTests {
    @Test func zipUnzipRoundTripPreservesTree() throws {
        let fixture = Fixture()
        let source = try makeSkillTree(in: fixture.makeDir("work"), reference: "some bytes\nline two")
        let sourceHash = try TreeHash.hash(directory: source)

        let archive = try CloudKitArchive.zip(directory: source)
        defer { try? FileManager.default.removeItem(at: archive) }
        #expect(FileManager.default.fileExists(atPath: archive.path))

        let destination = fixture.root.appendingPathComponent("unpacked", isDirectory: true)
        try CloudKitArchive.unzip(archive, to: destination)

        #expect(try TreeHash.hash(directory: destination) == sourceHash)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("references/a.md").path))
    }
}

// MARK: - CloudKitCollection (entitlement guard, unsigned runner)

@MainActor
@Suite struct CloudKitCollectionTests {
    /// The unsigned test process has no iCloud entitlement, so the guard must
    /// report unavailable WITH a reason and must never touch (crash on)
    /// CKContainer.
    @Test func entitlementGuardReportsUnavailable() {
        #expect(CloudKitCollection.hasICloudEntitlement() == false)
    }

    @Test func activateStaysUnavailableWithoutEntitlement() async {
        let store = CloudKitCollection()
        await store.activate()
        #expect(store.isAvailable == false)
        let reason = store.unavailabilityReason
        #expect(reason?.contains("signed") == true)
    }

    @Test func operationsThrowWhenUnavailable() async {
        let store = CloudKitCollection()
        await store.activate()
        await #expect(throws: CollectionError.self) {
            _ = try await store.list()
        }
    }
}
