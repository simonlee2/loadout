import Foundation
import Testing
@testable import LoadoutKit

/// Offline tests for ``SkillsShAdapter``. Every network call is served from
/// captured real responses through the injected transport — no live network.
@Suite struct SkillsShAdapterTests {

    // MARK: Fixtures (captured from the real service on 2026-07-10)

    /// Real `GET https://skills.sh/api/search?q=react`, trimmed to three rows.
    static let searchJSON = """
    {
      "query": "react",
      "searchType": "fuzzy",
      "skills": [
        {"id": "vercel-labs/agent-skills/vercel-react-best-practices", "skillId": "vercel-react-best-practices", "name": "vercel-react-best-practices", "installs": 539050, "source": "vercel-labs/agent-skills"},
        {"id": "vercel-labs/agent-skills/vercel-react-native-skills", "skillId": "vercel-react-native-skills", "name": "vercel-react-native-skills", "installs": 162122, "source": "vercel-labs/agent-skills"},
        {"id": "vercel-labs/json-render/react", "skillId": "react", "name": "react", "installs": 3961, "source": "vercel-labs/json-render"}
      ],
      "count": 100,
      "duration_ms": 437
    }
    """

    /// Real `GET https://skills.sh/api/search?q=skill` shape, ranked by installs.
    static let featuredJSON = """
    {
      "query": "skill",
      "searchType": "fuzzy",
      "skills": [
        {"id": "vercel-labs/agent-skills/vercel-react-best-practices", "skillId": "vercel-react-best-practices", "name": "vercel-react-best-practices", "installs": 539050, "source": "vercel-labs/agent-skills"},
        {"id": "vercel-labs/skills/find-skills", "skillId": "find-skills", "name": "find-skills", "installs": 2422975, "source": "vercel-labs/skills"},
        {"id": "obra/superpowers/test-driven-development", "skillId": "test-driven-development", "name": "test-driven-development", "installs": 159477, "source": "obra/superpowers"}
      ],
      "count": 100,
      "duration_ms": 51
    }
    """

    static let commitSHA = "4ce6d48ac44c8b637db87b2102fea3baca719df1"

    static func commitJSON(_ sha: String) -> String {
        #"{"sha":"\#(sha)","commit":{"message":"chore: release"}}"#
    }

    /// Real find-skills SKILL.md (trimmed), used as a valid manifest fixture.
    static let findSkillsManifest = """
    ---
    name: find-skills
    description: Helps users discover and install agent skills when they ask questions like "how do I do X".
    ---

    # Find Skills

    This skill helps you discover and install skills from the open agent skills ecosystem.
    """

    // MARK: Transport helper

    /// A route matched by substring against the request URL.
    struct Route: Sendable {
        let match: String
        let status: Int
        let body: Data
        init(_ match: String, status: Int = 200, body: String) {
            self.match = match
            self.status = status
            self.body = Data(body.utf8)
        }
    }

    /// Builds a transport that serves the first route whose `match` appears in
    /// the request URL; unmatched requests return HTTP 404.
    static func transport(_ routes: [Route]) -> SkillsShAdapter.Transport {
        { request in
            let url = request.url!
            let string = url.absoluteString
            let route = routes.first { string.contains($0.match) }
            let status = route?.status ?? 404
            let body = route?.body ?? Data()
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    /// A git-clone closure that fails — asserts the git fallback is not silently
    /// exercised when the HTTP path is expected to succeed, and stays offline.
    static let failingClone: SkillsShAdapter.GitClone = { _, _ in
        throw SkillsShError.fetchFailed("git clone must not run in this test")
    }

    // MARK: search

    @Test func searchDecodesRowsWithMappedFields() async throws {
        let adapter = SkillsShAdapter(
            transport: Self.transport([Route("/api/search", body: Self.searchJSON)]),
            gitClone: Self.failingClone
        )
        let results = try await adapter.search("react")

        #expect(results.count == 3)
        let first = results[0]
        #expect(first.registry == "skills.sh")
        #expect(first.identifier == "vercel-labs/agent-skills/vercel-react-best-practices")
        #expect(first.slug == "vercel-react-best-practices")
        #expect(first.name == "vercel-react-best-practices")
        #expect(first.installCount == 539050)
        #expect(first.sourceURL == URL(string: "https://github.com/vercel-labs/agent-skills"))
        // The public search endpoint exposes no description, version, or audit.
        #expect(first.summary == nil)
        #expect(first.version == nil)
        #expect(first.audit == nil)
    }

    @Test func searchShortQueryReturnsEmptyWithoutNetwork() async throws {
        // Transport would 404 everything; a <2-char query must not call it.
        let adapter = SkillsShAdapter(transport: Self.transport([]), gitClone: Self.failingClone)
        let results = try await adapter.search("a")
        #expect(results.isEmpty)
    }

    @Test func searchHTTPErrorThrowsWithStatus() async {
        let adapter = SkillsShAdapter(
            transport: Self.transport([Route("/api/search", status: 503, body: "upstream down")]),
            gitClone: Self.failingClone
        )
        await #expect(throws: SkillsShError.httpStatus(503, endpoint: "https://skills.sh/api/search?q=react")) {
            _ = try await adapter.search("react")
        }
    }

    // MARK: featured

    @Test func featuredDecodesAndRanksByInstalls() async throws {
        let adapter = SkillsShAdapter(
            transport: Self.transport([Route("/api/search", body: Self.featuredJSON)]),
            gitClone: Self.failingClone
        )
        let results = try await adapter.featured()

        #expect(results.count == 3)
        // Ranked by installs descending regardless of API order.
        #expect(results.map(\.installCount) == [2422975, 539050, 159477])
        #expect(results.first?.slug == "find-skills")
    }

    // MARK: fetch — happy path

    @Test func fetchDownloadsTreeAndReturnsSHA() async throws {
        let tree = """
        {
          "sha": "\(Self.commitSHA)",
          "tree": [
            {"path": "README.md", "type": "blob"},
            {"path": "skills", "type": "tree"},
            {"path": "skills/find-skills", "type": "tree"},
            {"path": "skills/find-skills/SKILL.md", "type": "blob"},
            {"path": "skills/find-skills/reference.md", "type": "blob"}
          ],
          "truncated": false
        }
        """
        let adapter = SkillsShAdapter(
            transport: Self.transport([
                Route("commits/HEAD", body: Self.commitJSON(Self.commitSHA)),
                Route("git/trees", body: tree),
                Route("skills/find-skills/SKILL.md", body: Self.findSkillsManifest),
                Route("skills/find-skills/reference.md", body: "# Reference\nDetails."),
            ]),
            gitClone: Self.failingClone
        )
        let skill = Self.skill(
            identifier: "vercel-labs/skills/find-skills",
            slug: "find-skills",
            source: "vercel-labs/skills"
        )
        let destination = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: destination) }

        let version = try await adapter.fetch(skill, to: destination)

        #expect(version == Self.commitSHA)
        let manifest = destination.appendingPathComponent("SKILL.md")
        let reference = destination.appendingPathComponent("reference.md")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(FileManager.default.fileExists(atPath: reference.path))
        // Files are written relative to the skill dir, not the repo root.
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("skills").path))
        let text = try String(contentsOf: manifest, encoding: .utf8)
        #expect(Frontmatter.parse(text).name == "find-skills")
    }

    // MARK: fetch — frontmatter-name fallback (skillId != directory name)

    @Test func fetchMatchesBySkillMetadataNameWhenDirectoryDiffers() async throws {
        // Real-world case: skillId "vercel-react-best-practices" lives in the
        // directory "skills/react-best-practices".
        let tree = """
        {
          "tree": [
            {"path": "skills/react-best-practices/SKILL.md", "type": "blob"},
            {"path": "skills/writing-guidelines/SKILL.md", "type": "blob"}
          ]
        }
        """
        let matching = """
        ---
        name: vercel-react-best-practices
        description: React performance guidelines.
        ---
        # Best Practices
        """
        let other = """
        ---
        name: vercel-writing-guidelines
        description: Writing guidelines.
        ---
        # Writing
        """
        let adapter = SkillsShAdapter(
            transport: Self.transport([
                Route("commits/HEAD", body: Self.commitJSON(Self.commitSHA)),
                Route("git/trees", body: tree),
                Route("skills/react-best-practices/SKILL.md", body: matching),
                Route("skills/writing-guidelines/SKILL.md", body: other),
            ]),
            gitClone: Self.failingClone
        )
        let skill = Self.skill(
            identifier: "vercel-labs/agent-skills/vercel-react-best-practices",
            slug: "vercel-react-best-practices",
            source: "vercel-labs/agent-skills"
        )
        let destination = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: destination) }

        let version = try await adapter.fetch(skill, to: destination)

        #expect(version == Self.commitSHA)
        let text = try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(Frontmatter.parse(text).name == "vercel-react-best-practices")
    }

    // MARK: fetch — missing SKILL.md

    @Test func fetchThrowsWhenNoManifestInRepo() async {
        // Tree with no SKILL.md anywhere. The API path fails to locate the skill;
        // the git fallback (failingClone) also fails, so the surfaced error
        // reports the primary "no SKILL.md" cause.
        let tree = """
        {
          "tree": [
            {"path": "README.md", "type": "blob"},
            {"path": "src/index.ts", "type": "blob"}
          ]
        }
        """
        let adapter = SkillsShAdapter(
            transport: Self.transport([
                Route("commits/HEAD", body: Self.commitJSON(Self.commitSHA)),
                Route("git/trees", body: tree),
            ]),
            gitClone: Self.failingClone
        )
        let skill = Self.skill(
            identifier: "acme/pack/ghost-skill",
            slug: "ghost-skill",
            source: "acme/pack"
        )
        let destination = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: SkillsShError.self) {
            _ = try await adapter.fetch(skill, to: destination)
        }
    }

    // MARK: SkillsShPaths unit coverage

    @Test func locateSkillDirectoryPrefersDirectoryNameMatch() async throws {
        let paths = ["skills/find-skills/SKILL.md", "skills/other/SKILL.md", "README.md"]
        let dir = try await SkillsShPaths.locateSkillDirectory(
            paths: paths,
            skillId: "find-skills",
            loadManifest: { _ in Issue.record("must not load manifests on a name match"); return nil }
        )
        #expect(dir == "skills/find-skills")
    }

    @Test func locateSkillDirectoryUsesSingleManifestWhenUnambiguous() async throws {
        let paths = ["skills/deeply/nested/SKILL.md", "README.md"]
        let dir = try await SkillsShPaths.locateSkillDirectory(
            paths: paths,
            skillId: "does-not-match-directory",
            loadManifest: { _ in nil }
        )
        #expect(dir == "skills/deeply/nested")
    }

    @Test func filesUnderScopesToSkillDirectory() {
        let blobs = [
            "skills/find-skills/SKILL.md",
            "skills/find-skills/scripts/run.sh",
            "skills/other/SKILL.md",
            "README.md",
        ]
        let files = SkillsShPaths.files(under: "skills/find-skills", in: blobs)
        #expect(files.sorted() == ["skills/find-skills/SKILL.md", "skills/find-skills/scripts/run.sh"])
        #expect(
            SkillsShPaths.destinationRelativePath(
                for: "skills/find-skills/scripts/run.sh",
                skillDirectory: "skills/find-skills"
            ) == "scripts/run.sh"
        )
    }

    // MARK: Helpers

    static func skill(identifier: String, slug: String, source: String) -> RegistrySkill {
        RegistrySkill(
            registry: "skills.sh",
            identifier: identifier,
            slug: slug,
            name: slug,
            summary: nil,
            version: nil,
            installCount: nil,
            sourceURL: URL(string: "https://github.com/\(source)"),
            audit: nil
        )
    }

    static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillssh-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
