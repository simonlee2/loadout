import Foundation
import Testing
@testable import Loadout

/// Offline tests for ``GitMarketplaceAdapter``. Fixture repositories are built
/// with real `git init` in temp directories (git is available; no network).
/// Remotes are `file://` URLs so `--depth` shallow clones behave like the real
/// network path.
@Suite struct GitMarketplaceAdapterTests {

    // MARK: Git fixture helpers

    /// Runs git in `dir`, failing the surrounding test on a non-zero exit.
    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(output)",
            ])
        }
        return output
    }

    static func makeTempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitmkt-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Initializes an empty git repo (no working-tree files yet) and returns it.
    static func initRepo(_ label: String) throws -> URL {
        let repo = makeTempDir(label)
        try git(["init", "--quiet"], in: repo)
        try git(["config", "user.email", "test@example.com"], in: repo)
        try git(["config", "user.name", "Test"], in: repo)
        try git(["config", "commit.gpgsign", "false"], in: repo)
        return repo
    }

    static func write(_ contents: String, to relative: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func commitAll(_ message: String, in repo: URL) throws -> String {
        try git(["add", "-A"], in: repo)
        try git(["commit", "--quiet", "-m", message], in: repo)
        return try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func skillManifest(name: String, description: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        Body for \(name).
        """
    }

    /// Builds an adapter pointed at a local fixture repo, caching under a throwaway
    /// directory so App Support is never touched.
    static func adapter(
        for repo: URL,
        cacheRoot: URL,
        credential: GitMarketplaceAdapter.CredentialProvider? = nil
    ) -> GitMarketplaceAdapter {
        GitMarketplaceAdapter(
            remoteURL: URL(fileURLWithPath: repo.path),
            displayName: "Fixture",
            cacheRoot: cacheRoot,
            credential: credential
        )
    }

    // MARK: Layout 1 — plugin marketplace

    @Test func pluginMarketplaceLayoutMapsSkills() async throws {
        let repo = try Self.initRepo("plugins")
        defer { try? FileManager.default.removeItem(at: repo) }

        let manifest = """
        {
          "plugins": [
            {"name": "alpha", "description": "Alpha", "version": "1.2.0", "source": "./plugins/alpha"},
            {"name": "beta", "source": {"path": "./plugins/beta"}}
          ]
        }
        """
        try Self.write(manifest, to: ".claude-plugin/marketplace.json", in: repo)
        try Self.write(
            Self.skillManifest(name: "Foo Skill", description: "Does foo"),
            to: "plugins/alpha/skills/foo/SKILL.md", in: repo
        )
        try Self.write(
            Self.skillManifest(name: "Bar Skill", description: "Does bar"),
            to: "plugins/beta/skills/bar/SKILL.md", in: repo
        )
        let sha = try Self.commitAll("init", in: repo)
        let shortSHA = String(sha.prefix(7))

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let skills = try await adapter.featured().sorted { $0.slug < $1.slug }
        #expect(skills.count == 2)

        let bar = try #require(skills.first { $0.slug == "bar" })
        #expect(bar.name == "Bar Skill")
        #expect(bar.summary == "Does bar")
        #expect(bar.identifier == "plugins/beta/skills/bar")
        // No plugin version → repo HEAD short SHA.
        #expect(bar.version == shortSHA)
        #expect(bar.registry == adapter.id)

        let foo = try #require(skills.first { $0.slug == "foo" })
        #expect(foo.name == "Foo Skill")
        #expect(foo.summary == "Does foo")
        #expect(foo.identifier == "plugins/alpha/skills/foo")
        // Plugin version wins over the repo SHA.
        #expect(foo.version == "1.2.0")
    }

    // MARK: Layout 2 — plain skills tree

    @Test func plainSkillsDirectoryLayoutDiscovered() async throws {
        let repo = try Self.initRepo("plain")
        defer { try? FileManager.default.removeItem(at: repo) }

        try Self.write(Self.skillManifest(name: "One", description: "First"), to: "skills/one/SKILL.md", in: repo)
        try Self.write(Self.skillManifest(name: "Two", description: "Second"), to: "skills/two/SKILL.md", in: repo)
        let sha = try Self.commitAll("init", in: repo)
        let shortSHA = String(sha.prefix(7))

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let skills = try await adapter.featured().sorted { $0.slug < $1.slug }
        #expect(skills.map(\.slug) == ["one", "two"])
        #expect(skills.map(\.identifier) == ["skills/one", "skills/two"])
        #expect(skills.allSatisfy { $0.version == shortSHA })
    }

    @Test func rootLevelTreeLayoutDiscovered() async throws {
        let repo = try Self.initRepo("root")
        defer { try? FileManager.default.removeItem(at: repo) }

        // No `skills/` dir: skills sit directly at the repo root.
        try Self.write(Self.skillManifest(name: "Alpha", description: "A"), to: "alpha/SKILL.md", in: repo)
        try Self.write(Self.skillManifest(name: "Bravo", description: "B"), to: "bravo/SKILL.md", in: repo)
        try Self.commitAll("init", in: repo)

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let skills = try await adapter.featured().sorted { $0.slug < $1.slug }
        #expect(skills.map(\.slug) == ["alpha", "bravo"])
        #expect(skills.map(\.identifier) == ["alpha", "bravo"])
    }

    // MARK: search

    @Test func searchFiltersOverSlugNameSummary() async throws {
        let repo = try Self.initRepo("search")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.write(Self.skillManifest(name: "Foo", description: "handles foo"), to: "skills/foo/SKILL.md", in: repo)
        try Self.write(Self.skillManifest(name: "Bar", description: "handles bar"), to: "skills/bar/SKILL.md", in: repo)
        try Self.commitAll("init", in: repo)

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let hits = try await adapter.search("foo")
        #expect(hits.map(\.slug) == ["foo"])
        // Empty query returns everything.
        let all = try await adapter.search("   ")
        #expect(all.count == 2)
    }

    // MARK: fetch

    @Test func fetchCopiesTreeReturnsHeadSHAAndValidates() async throws {
        let repo = try Self.initRepo("fetch")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.write(Self.skillManifest(name: "Foo", description: "foo"), to: "skills/foo/SKILL.md", in: repo)
        try Self.write("helper contents", to: "skills/foo/scripts/run.sh", in: repo)
        let fullSHA = try Self.commitAll("init", in: repo)

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let skill = try #require(try await adapter.featured().first)
        let destination = Self.makeTempDir("dest")
        defer { try? FileManager.default.removeItem(at: destination) }

        let version = try await adapter.fetch(skill, to: destination)
        #expect(version == fullSHA)

        let manifest = destination.appendingPathComponent("SKILL.md")
        let script = destination.appendingPathComponent("scripts/run.sh")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(Frontmatter.parse(try String(contentsOf: manifest, encoding: .utf8)).name == "Foo")
    }

    @Test func fetchThrowsOnCorruptManifest() async throws {
        let repo = try Self.initRepo("corrupt")
        defer { try? FileManager.default.removeItem(at: repo) }
        // SKILL.md with no frontmatter → no name → invalid.
        try Self.write("# just a heading, no frontmatter", to: "skills/broken/SKILL.md", in: repo)
        try Self.commitAll("init", in: repo)

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let skill = try #require(try await adapter.featured().first)
        let destination = Self.makeTempDir("dest")
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: GitMarketplaceError.missingSkillManifest(slug: "broken")) {
            _ = try await adapter.fetch(skill, to: destination)
        }
    }

    // MARK: latestVersion

    @Test func latestVersionReturnsRepoHead() async throws {
        let repo = try Self.initRepo("latest")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.write(Self.skillManifest(name: "Foo", description: "foo"), to: "skills/foo/SKILL.md", in: repo)
        let fullSHA = try Self.commitAll("init", in: repo)

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let entry = LockEntry(
            slug: "foo", registry: adapter.id, identifier: "skills/foo",
            version: "old", contentHash: "hash",
            fetchedAt: Date(timeIntervalSince1970: 0), deployments: []
        )
        let latest = try await adapter.latestVersion(for: entry)
        #expect(latest == fullSHA)
    }

    @Test func latestVersionIgnoresOtherRegistries() async throws {
        let repo = try Self.initRepo("latest-foreign")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.write(Self.skillManifest(name: "Foo", description: "foo"), to: "skills/foo/SKILL.md", in: repo)
        try Self.commitAll("init", in: repo)

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let entry = LockEntry(
            slug: "x", registry: "clawhub", identifier: "x",
            version: "1.0.0", contentHash: "hash",
            fetchedAt: Date(timeIntervalSince1970: 0), deployments: []
        )
        #expect(try await adapter.latestVersion(for: entry) == nil)
    }

    // MARK: refresh picks up new commits

    @Test func refreshPicksUpNewCommit() async throws {
        let repo = try Self.initRepo("refresh")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.write(Self.skillManifest(name: "One", description: "1"), to: "skills/one/SKILL.md", in: repo)
        try Self.commitAll("first", in: repo)

        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let adapter = Self.adapter(for: repo, cacheRoot: cacheRoot)

        let first = try await adapter.featured()
        #expect(first.map(\.slug) == ["one"])

        // Commit a new skill to the fixture, then re-fetch.
        try Self.write(Self.skillManifest(name: "Two", description: "2"), to: "skills/two/SKILL.md", in: repo)
        try Self.commitAll("second", in: repo)

        let second = try await adapter.featured().sorted { $0.slug < $1.slug }
        #expect(second.map(\.slug) == ["one", "two"])
    }

    // MARK: auth failure surfacing

    @Test func authFailureSurfacesWithoutLeakingToken() async throws {
        let token = "ghp_SUPERSECRETTOKEN123"
        let cacheRoot = Self.makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // gitRunner stub that always fails as if auth is missing.
        let runner: GitMarketplaceAdapter.GitRunner = { _, _ in
            throw GitMarketplaceError.gitFailed(
                command: "git clone",
                stderr: "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
            )
        }
        let adapter = GitMarketplaceAdapter(
            remoteURL: URL(string: "https://github.com/cardinalblue/skills")!,
            displayName: "CardinalBlue",
            cacheRoot: cacheRoot,
            gitRunner: runner,
            credential: { token }
        )

        #expect(adapter.id == "git:github.com/cardinalblue/skills")

        var caught: GitMarketplaceError?
        do {
            _ = try await adapter.featured()
        } catch let error as GitMarketplaceError {
            caught = error
        }
        let error = try #require(caught)
        guard case .authenticationRequired = error else {
            Issue.record("expected authenticationRequired, got \(error)")
            return
        }
        let description = try #require(error.errorDescription)
        #expect(!description.contains(token))
    }

    // MARK: KeychainCredential round-trip

    @Test func keychainWriteReadDeleteRoundTrip() throws {
        let service = "com.cardinalblue.loadout.git.tests.\(UUID().uuidString)"
        let account = "github.com/test/roundtrip"
        defer { try? KeychainCredential.delete(service: service, account: account) }

        #expect(KeychainCredential.read(service: service, account: account) == nil)
        try KeychainCredential.write("token-value", service: service, account: account)
        #expect(KeychainCredential.read(service: service, account: account) == "token-value")
        // Overwrite replaces.
        try KeychainCredential.write("token-value-2", service: service, account: account)
        #expect(KeychainCredential.read(service: service, account: account) == "token-value-2")
        try KeychainCredential.delete(service: service, account: account)
        #expect(KeychainCredential.read(service: service, account: account) == nil)
    }

    // MARK: slug parsing

    @Test func slugHandlesRemoteForms() {
        #expect(GitRemoteSlug.slug(forString: "https://github.com/cardinalblue/skills") == "github.com/cardinalblue/skills")
        #expect(GitRemoteSlug.slug(forString: "https://github.com/cardinalblue/skills.git") == "github.com/cardinalblue/skills")
        #expect(GitRemoteSlug.slug(forString: "git@github.com:cardinalblue/skills.git") == "github.com/cardinalblue/skills")
        #expect(GitRemoteSlug.slug(forString: "ssh://git@github.com/cardinalblue/skills.git") == "github.com/cardinalblue/skills")
        #expect(GitRemoteSlug.slug(forString: "https://x-access-token:tok@github.com/cardinalblue/skills") == "github.com/cardinalblue/skills")
    }
}
