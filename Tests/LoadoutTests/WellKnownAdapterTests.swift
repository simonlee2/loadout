import Foundation
import Testing
@testable import LoadoutKit

/// Offline tests for ``WellKnownAdapter``. Every network call is served through
/// the injected transport — no live network.
///
/// No public site currently serves `/.well-known/skills/index.json` (probed
/// 2026-07-10: skills.sh, nousresearch.com, hermes-agent.nousresearch.com,
/// anthropic.com, vercel.com, clawhub.ai all return HTML or 404), so these
/// fixtures are **synthetic, derived from the convention's shipping reference
/// implementation** (`NousResearch/hermes-agent` `tools/skills_hub.py::WellKnownSkillSource`):
/// an index object with a `skills` array of `{name, description?, files?}`.
@Suite struct WellKnownAdapterTests {

    static let site = URL(string: "https://acme.example")!
    static let skillsBase = "https://acme.example/.well-known/skills"

    // MARK: Fixtures (spec-derived synthetic)

    /// A well-known index. `csv-cleaner` omits `files` (⇒ ["SKILL.md"]);
    /// `versioned-skill` carries the optional publisher `version` extension.
    static let indexJSON = """
    {
      "skills": [
        {"name": "pdf-tools", "description": "Extract and merge PDF files.", "files": ["SKILL.md", "reference.md"]},
        {"name": "csv-cleaner", "description": "Clean messy CSV exports."},
        {"name": "versioned-skill", "description": "Ships a version tag.", "version": "1.4.0", "files": ["SKILL.md"]}
      ]
    }
    """

    static let pdfManifest = """
    ---
    name: pdf-tools
    description: Extract and merge PDF files.
    ---
    # PDF Tools
    Procedures for working with PDFs.
    """

    /// A transport route matched by substring against the request URL.
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

    static func transport(_ routes: [Route]) -> WellKnownAdapter.Transport {
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

    static func adapter(_ routes: [Route]) -> WellKnownAdapter {
        WellKnownAdapter(site: site, transport: transport(routes))!
    }

    static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellknown-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: init

    @Test func initDerivesHostIdAndNormalizesIndexURL() throws {
        let a = try #require(WellKnownAdapter(site: Self.site, transport: Self.transport([])))
        #expect(a.id == "well-known:acme.example")
        #expect(a.displayName == "acme.example")
    }

    @Test func initRejectsNonHTTPScheme() {
        #expect(WellKnownAdapter(site: URL(string: "file:///tmp/x")!, transport: Self.transport([])) == nil)
    }

    // MARK: featured / search

    @Test func featuredReturnsWholeIndex() async throws {
        let a = Self.adapter([Route("index.json", body: Self.indexJSON)])
        let results = try await a.featured()
        #expect(results.map(\.name) == ["pdf-tools", "csv-cleaner", "versioned-skill"])
        let first = results[0]
        #expect(first.registry == "well-known:acme.example")
        #expect(first.identifier == "well-known:\(Self.skillsBase)/pdf-tools")
        #expect(first.slug == "pdf-tools")
        #expect(first.summary == "Extract and merge PDF files.")
        #expect(first.sourceURL == URL(string: "\(Self.skillsBase)/pdf-tools"))
        // Convention exposes no installs or audit; version only when published.
        #expect(first.installCount == nil)
        #expect(first.audit == nil)
        #expect(first.version == nil)
        #expect(results.last?.version == "1.4.0")
    }

    @Test func searchFiltersByNameAndDescription() async throws {
        let a = Self.adapter([Route("index.json", body: Self.indexJSON)])
        #expect(try await a.search("pdf").map(\.slug) == ["pdf-tools"])
        // Matches on description text too.
        #expect(try await a.search("CSV").map(\.slug) == ["csv-cleaner"])
        // Empty query returns the full index.
        #expect(try await a.search("  ").count == 3)
        #expect(try await a.search("nonexistent").isEmpty)
    }

    @Test func searchHTTPErrorThrowsWithStatus() async {
        let a = Self.adapter([Route("index.json", status: 503, body: "down")])
        await #expect(throws: WellKnownError.self) {
            _ = try await a.search("pdf")
        }
    }

    // MARK: fetch

    @Test func fetchDownloadsListedFilesAndReturnsDigestVersion() async throws {
        let a = Self.adapter([
            Route("index.json", body: Self.indexJSON),
            Route("/pdf-tools/SKILL.md", body: Self.pdfManifest),
            Route("/pdf-tools/reference.md", body: "# Reference\nDetails."),
        ])
        let skill = RegistrySkill(
            registry: a.id,
            identifier: "well-known:\(Self.skillsBase)/pdf-tools",
            slug: "pdf-tools", name: "pdf-tools", summary: nil,
            version: nil, installCount: nil,
            sourceURL: nil, audit: nil
        )
        let dest = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dest) }

        let version = try await a.fetch(skill, to: dest)

        #expect(version.hasPrefix("sha256:"))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("reference.md").path))
        let text = try String(contentsOf: dest.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(Frontmatter.parse(text).name == "pdf-tools")
    }

    @Test func fetchUsesPublisherVersionWhenPresent() async throws {
        let manifest = """
        ---
        name: versioned-skill
        description: Ships a version tag.
        ---
        # Versioned
        """
        let a = Self.adapter([
            Route("index.json", body: Self.indexJSON),
            Route("/versioned-skill/SKILL.md", body: manifest),
        ])
        let skill = RegistrySkill(
            registry: a.id,
            identifier: "well-known:\(Self.skillsBase)/versioned-skill",
            slug: "versioned-skill", name: "versioned-skill", summary: nil,
            version: "1.4.0", installCount: nil, sourceURL: nil, audit: nil
        )
        let dest = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dest) }

        let version = try await a.fetch(skill, to: dest)
        #expect(version == "1.4.0")
    }

    @Test func fetchThrowsWhenSkillNotInIndex() async {
        let a = Self.adapter([Route("index.json", body: Self.indexJSON)])
        let skill = RegistrySkill(
            registry: a.id,
            identifier: "well-known:\(Self.skillsBase)/ghost",
            slug: "ghost", name: "ghost", summary: nil,
            version: nil, installCount: nil, sourceURL: nil, audit: nil
        )
        let dest = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        await #expect(throws: WellKnownError.self) {
            _ = try await a.fetch(skill, to: dest)
        }
    }

    @Test func fetchRejectsUnsafeSkillNameWithoutNetwork() async {
        // Identifier whose resolved name is a traversal token — must not fetch.
        let a = Self.adapter([])
        let skill = RegistrySkill(
            registry: a.id,
            identifier: "well-known:\(Self.skillsBase)/..",
            slug: "..", name: "..", summary: nil,
            version: nil, installCount: nil, sourceURL: nil, audit: nil
        )
        let dest = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        await #expect(throws: WellKnownError.unsafeSkillName("..")) {
            _ = try await a.fetch(skill, to: dest)
        }
    }

    @Test func fetchRejectsUnsafeAdvertisedFilePath() async {
        let evilIndex = """
        {"skills": [{"name": "evil", "files": ["SKILL.md", "../../../etc/passwd"]}]}
        """
        let a = Self.adapter([
            Route("index.json", body: evilIndex),
            Route("/evil/SKILL.md", body: Self.pdfManifest),
        ])
        let skill = RegistrySkill(
            registry: a.id,
            identifier: "well-known:\(Self.skillsBase)/evil",
            slug: "evil", name: "evil", summary: nil,
            version: nil, installCount: nil, sourceURL: nil, audit: nil
        )
        let dest = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        await #expect(throws: WellKnownError.self) {
            _ = try await a.fetch(skill, to: dest)
        }
    }

    @Test func fetchThrowsWhenManifestUnparseable() async {
        let a = Self.adapter([
            Route("index.json", body: """
            {"skills": [{"name": "csv-cleaner", "files": ["SKILL.md"]}]}
            """),
            Route("/csv-cleaner/SKILL.md", body: "no frontmatter here"),
        ])
        let skill = RegistrySkill(
            registry: a.id,
            identifier: "well-known:\(Self.skillsBase)/csv-cleaner",
            slug: "csv-cleaner", name: "csv-cleaner", summary: nil,
            version: nil, installCount: nil, sourceURL: nil, audit: nil
        )
        let dest = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        await #expect(throws: WellKnownError.missingSkillManifest(name: "csv-cleaner")) {
            _ = try await a.fetch(skill, to: dest)
        }
    }

    // MARK: latestVersion

    @Test func latestVersionReturnsPublishedVersion() async throws {
        let a = Self.adapter([Route("index.json", body: Self.indexJSON)])
        let entry = LockEntry(
            slug: "versioned-skill",
            registry: a.id,
            identifier: "well-known:\(Self.skillsBase)/versioned-skill",
            version: "1.3.0", contentHash: "x", fetchedAt: .init(), deployments: []
        )
        #expect(try await a.latestVersion(for: entry) == "1.4.0")
    }

    @Test func latestVersionNilForUnversionedAndForeignEntries() async throws {
        let a = Self.adapter([Route("index.json", body: Self.indexJSON)])
        // Unversioned skill in the index → nil (can't answer cheaply).
        let unversioned = LockEntry(
            slug: "pdf-tools", registry: a.id,
            identifier: "well-known:\(Self.skillsBase)/pdf-tools",
            version: "sha256:abc", contentHash: "x", fetchedAt: .init(), deployments: []
        )
        #expect(try await a.latestVersion(for: unversioned) == nil)
        // Entry from another registry → nil without touching the network.
        let foreign = LockEntry(
            slug: "x", registry: "skills.sh", identifier: "a/b/x",
            version: "1", contentHash: "x", fetchedAt: .init(), deployments: []
        )
        #expect(try await a.latestVersion(for: foreign) == nil)
    }

    // MARK: WellKnownPaths unit coverage

    @Test func indexURLNormalizesSiteForms() {
        let expected = "https://ex.com/.well-known/skills/index.json"
        #expect(WellKnownPaths.indexURL(forSite: "https://ex.com") == expected)
        #expect(WellKnownPaths.indexURL(forSite: "https://ex.com/") == expected)
        #expect(WellKnownPaths.indexURL(forSite: "https://ex.com/.well-known/skills") == expected)
        #expect(WellKnownPaths.indexURL(forSite: expected) == expected)
        #expect(WellKnownPaths.indexURL(forSite: "ftp://ex.com") == nil)
    }

    @Test func identifierRoundTrips() {
        let id = WellKnownPaths.wrapIdentifier(skillsBaseURL: Self.skillsBase, name: "pdf-tools")
        #expect(id == "well-known:\(Self.skillsBase)/pdf-tools")
        let parsed = WellKnownPaths.parseIdentifier(id)
        #expect(parsed?.skillName == "pdf-tools")
        #expect(parsed?.indexURL == "\(Self.skillsBase)/index.json")
        #expect(parsed?.skillURL == "\(Self.skillsBase)/pdf-tools")
    }

    @Test func pathValidationRejectsTraversal() {
        #expect(WellKnownPaths.validateSkillName("pdf-tools") == "pdf-tools")
        #expect(WellKnownPaths.validateSkillName("..") == nil)
        #expect(WellKnownPaths.validateSkillName("a/b") == nil)
        #expect(WellKnownPaths.validateSkillName("") == nil)
        #expect(WellKnownPaths.validateRelativePath("scripts/run.sh") == "scripts/run.sh")
        #expect(WellKnownPaths.validateRelativePath("../escape") == nil)
        #expect(WellKnownPaths.validateRelativePath("/abs") == nil)
    }
}
