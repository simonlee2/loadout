import Foundation
import Testing
@testable import Loadout

/// Offline tests for ``ClawHubAdapter``. Every network call is served from
/// captured real responses through the injected transport — no live network.
/// Fixtures were captured from https://clawhub.ai/api/v1 on 2026-07-10.
@Suite struct ClawHubAdapterTests {

    // MARK: Fixtures (captured from the real service on 2026-07-10)

    /// Real `GET /api/v1/search?q=react&limit=3`, trimmed to three rows.
    static let searchJSON = """
    {
      "results": [
        {"score": 4.08, "slug": "react", "displayName": "React", "summary": "Full React 19 engineering, architecture, Server Components, hooks.", "version": null, "downloads": 7344, "ownerHandle": "ivangdavila"},
        {"score": 2.95, "slug": "react-performance", "displayName": "React Performance", "summary": "React and Next.js performance optimization patterns.", "version": null, "downloads": 2401, "ownerHandle": "wpank"},
        {"score": 2.95, "slug": "ah-react-specialist", "displayName": "react-specialist", "summary": "Expert React specialist mastering React 18+ with modern patterns.", "version": null, "downloads": 414, "ownerHandle": "mtsatryan"}
      ]
    }
    """

    /// Real `GET /api/v1/skills?limit=&sort=downloads` shape, two rows.
    static let featuredJSON = """
    {
      "items": [
        {"slug": "skill-vetter", "displayName": "Skill Vetter", "summary": "Security-first skill vetting for AI agents.", "tags": {"latest": "1.0.0"}, "stats": {"comments": 0, "downloads": 262754, "installs": 12059, "stars": 1257, "versions": 1}},
        {"slug": "self-improving-agent", "displayName": "self-improving agent", "summary": "Captures learnings, errors, and corrections.", "tags": {"latest": "4.0.1"}, "stats": {"comments": 53, "downloads": 466601, "installs": 18337, "stars": 3906, "versions": 38}}
      ],
      "nextCursor": null
    }
    """

    /// Real `GET /api/v1/skills/skill-vetter` (detail), trimmed.
    static let skillDetailJSON = """
    {
      "skill": {
        "slug": "skill-vetter",
        "displayName": "Skill Vetter",
        "summary": "Security-first skill vetting for AI agents.",
        "tags": {"latest": "1.0.0"},
        "stats": {"downloads": 262754, "installs": 12059, "stars": 1257}
      }
    }
    """

    /// Real `GET /api/v1/skills/skill-vetter/versions/1.0.0` (version detail).
    static let versionJSON = """
    {
      "skill": {"slug": "skill-vetter", "displayName": "Skill Vetter"},
      "version": {
        "version": "1.0.0",
        "createdAt": 1769863429632,
        "changelog": "Initial release",
        "license": null,
        "files": [
          {"path": "SKILL.md", "size": 4561, "sha256": "e8eb75", "contentType": "text/markdown"},
          {"path": "skill-card.md", "size": 2121, "sha256": "607072", "contentType": "text/markdown"}
        ],
        "security": {"status": "clean"}
      }
    }
    """

    /// Real skill-vetter SKILL.md (trimmed), a valid manifest fixture.
    static let skillManifest = """
    ---
    name: skill-vetter
    version: 1.0.0
    description: Security-first skill vetting for AI agents.
    ---

    # Skill Vetter

    Security-first vetting protocol for AI agent skills.
    """

    static let skillCard = """
    ## Description
    Security-first skill vetting for AI agents.
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
    static func transport(_ routes: [Route]) -> ClawHubAdapter.Transport {
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

    // MARK: search

    @Test func searchDecodesRowsWithMappedFields() async throws {
        let adapter = ClawHubAdapter(transport: Self.transport([Route("/search", body: Self.searchJSON)]))
        let results = try await adapter.search("react")

        #expect(results.count == 3)
        let first = results[0]
        #expect(first.registry == "clawhub")
        #expect(first.identifier == "react")
        #expect(first.slug == "react")
        #expect(first.name == "React")
        #expect(first.summary == "Full React 19 engineering, architecture, Server Components, hooks.")
        #expect(first.installCount == 7344)
        #expect(first.sourceURL == URL(string: "https://clawhub.ai/en/skills/react"))
        // The public search endpoint exposes no version or security scan.
        #expect(first.version == nil)
        #expect(first.audit == nil)
    }

    @Test func searchEmptyQueryReturnsEmptyWithoutNetwork() async throws {
        // Transport would 404 everything; an empty query must not call it.
        let adapter = ClawHubAdapter(transport: Self.transport([]))
        let results = try await adapter.search("   ")
        #expect(results.isEmpty)
    }

    @Test func searchHTTPErrorThrowsWithStatus() async {
        let adapter = ClawHubAdapter(transport: Self.transport([Route("/search", status: 503, body: "upstream down")]))
        await #expect(throws: ClawHubError.httpStatus(503, endpoint: "https://clawhub.ai/api/v1/search?q=react")) {
            _ = try await adapter.search("react")
        }
    }

    // MARK: featured

    @Test func featuredDecodesAndRanksByDownloads() async throws {
        let adapter = ClawHubAdapter(transport: Self.transport([Route("/skills?", body: Self.featuredJSON)]))
        let results = try await adapter.featured()

        #expect(results.count == 2)
        // Ranked by downloads descending regardless of API order.
        #expect(results.map(\.installCount) == [466601, 262754])
        #expect(results.first?.slug == "self-improving-agent")
        // Featured rows carry the `latest` dist-tag as their version.
        #expect(results.first?.version == "4.0.1")
    }

    // MARK: fetch — happy path (version resolved via latest dist-tag)

    @Test func fetchResolvesLatestDownloadsTreeAndReturnsSemver() async throws {
        // Search-sourced skill has version nil, so fetch resolves `latest` via
        // the detail endpoint, then reads the version manifest and files.
        let adapter = ClawHubAdapter(transport: Self.transport([
            // Most specific routes first: version detail before bare detail.
            Route("/versions/1.0.0", body: Self.versionJSON),
            Route("file?path=SKILL.md", body: Self.skillManifest),
            Route("file?path=skill-card.md", body: Self.skillCard),
            Route("/skills/skill-vetter", body: Self.skillDetailJSON),
        ]))
        let skill = Self.skill(slug: "skill-vetter", version: nil)
        let destination = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: destination) }

        let version = try await adapter.fetch(skill, to: destination)

        #expect(version == "1.0.0")
        let manifest = destination.appendingPathComponent("SKILL.md")
        let card = destination.appendingPathComponent("skill-card.md")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(FileManager.default.fileExists(atPath: card.path))
        let text = try String(contentsOf: manifest, encoding: .utf8)
        #expect(Frontmatter.parse(text).name == "skill-vetter")
    }

    // MARK: fetch — known version skips the detail lookup

    @Test func fetchWithKnownVersionSkipsDetailLookup() async throws {
        // No detail route registered: if fetch tried to resolve `latest`, it
        // would 404. A known version must go straight to the version endpoint.
        let adapter = ClawHubAdapter(transport: Self.transport([
            Route("/versions/1.0.0", body: Self.versionJSON),
            Route("file?path=SKILL.md", body: Self.skillManifest),
            Route("file?path=skill-card.md", body: Self.skillCard),
        ]))
        let skill = Self.skill(slug: "skill-vetter", version: "1.0.0")
        let destination = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: destination) }

        let version = try await adapter.fetch(skill, to: destination)
        #expect(version == "1.0.0")
    }

    // MARK: fetch — missing SKILL.md

    @Test func fetchThrowsWhenNoManifestInVersion() async {
        // Version lists only a non-manifest file, so validation fails.
        let versionNoManifest = """
        {
          "version": {
            "version": "1.0.0",
            "files": [{"path": "README.md", "size": 10}]
          }
        }
        """
        let adapter = ClawHubAdapter(transport: Self.transport([
            Route("/versions/1.0.0", body: versionNoManifest),
            Route("file?path=README.md", body: "# Readme"),
        ]))
        let skill = Self.skill(slug: "skill-vetter", version: "1.0.0")
        let destination = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: ClawHubError.missingSkillManifest(slug: "skill-vetter", version: "1.0.0")) {
            _ = try await adapter.fetch(skill, to: destination)
        }
    }

    // MARK: fetch — no published version

    @Test func fetchThrowsWhenNoVersionAvailable() async {
        // Detail with no `latest` dist-tag and a search-sourced (versionless)
        // skill means there is nothing to fetch.
        let detailNoLatest = """
        {"skill": {"slug": "ghost", "displayName": "Ghost", "tags": {}}}
        """
        let adapter = ClawHubAdapter(transport: Self.transport([
            Route("/skills/ghost", body: detailNoLatest),
        ]))
        let skill = Self.skill(slug: "ghost", version: nil)
        let destination = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: ClawHubError.noVersionAvailable(slug: "ghost")) {
            _ = try await adapter.fetch(skill, to: destination)
        }
    }

    // MARK: latestVersion

    @Test func latestVersionReadsDistTag() async throws {
        let adapter = ClawHubAdapter(transport: Self.transport([
            Route("/skills/skill-vetter", body: Self.skillDetailJSON),
        ]))
        let entry = Self.lockEntry(slug: "skill-vetter", identifier: "skill-vetter", version: "0.9.0")
        let latest = try await adapter.latestVersion(for: entry)
        #expect(latest == "1.0.0")
    }

    @Test func latestVersionIgnoresOtherRegistriesWithoutNetwork() async throws {
        // Transport would 404; a foreign-registry entry must not call it.
        let adapter = ClawHubAdapter(transport: Self.transport([]))
        let entry = Self.lockEntry(slug: "x", identifier: "owner/repo/x", version: "abc", registry: "skills.sh")
        let latest = try await adapter.latestVersion(for: entry)
        #expect(latest == nil)
    }

    // MARK: Helpers

    static func skill(slug: String, version: String?) -> RegistrySkill {
        RegistrySkill(
            registry: "clawhub",
            identifier: slug,
            slug: slug,
            name: slug,
            summary: nil,
            version: version,
            installCount: nil,
            sourceURL: URL(string: "https://clawhub.ai/en/skills/\(slug)"),
            audit: nil
        )
    }

    static func lockEntry(
        slug: String,
        identifier: String,
        version: String,
        registry: String = "clawhub"
    ) -> LockEntry {
        LockEntry(
            slug: slug,
            registry: registry,
            identifier: identifier,
            version: version,
            contentHash: "hash",
            fetchedAt: Date(timeIntervalSince1970: 0),
            deployments: []
        )
    }

    static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawhub-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
