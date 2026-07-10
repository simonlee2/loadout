import Foundation

/// Registry adapter for [ClawHub](https://clawhub.ai), OpenClaw's public skill
/// registry ("npm for skills": semver versions, dist-tags, changelogs, download
/// counts, and per-version security scans).
///
/// Unlike skills.sh, ClawHub exposes a first-class, unauthenticated public HTTP
/// API under `https://clawhub.ai/api/v1`, so this adapter talks to it directly —
/// no GitHub or git-clone fallback is needed:
///
/// - `featured()` lists the registry's most-downloaded skills
///   (`GET /skills?sort=downloads`), ranked by download count.
/// - `search(_:)` maps `GET /search?q=`. Rows carry no version or security scan,
///   so those fields stay nil until `fetch` resolves a concrete version.
/// - `fetch(_:to:)` resolves the target version (the row's version, else the
///   `latest` dist-tag), reads the version's `files` manifest
///   (`GET /skills/{slug}/versions/{version}`), and downloads each file over the
///   raw file endpoint (`GET /skills/{slug}/file?path=…&version=…`), validating a
///   parseable SKILL.md landed. It returns the canonical semver as provenance.
/// - `latestVersion(_:)` reads the `latest` dist-tag in one request — the honest
///   comparator for a semver-versioned lock entry.
struct ClawHubAdapter: RegistryAdapter {
    let id = "clawhub"
    let displayName = "ClawHub"

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// HTTP transport, injectable for offline tests. Defaults to `URLSession.shared`.
    var transport: Transport

    private let apiBase = "https://clawhub.ai/api/v1"
    private let webBase = "https://clawhub.ai/en/skills"
    private let userAgent = "Loadout/0.1"
    private let timeout: TimeInterval = 15
    /// Cap on `featured()` breadth — one page is plenty for a browse view.
    private let featuredLimit = 50

    init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    // MARK: Browse

    func featured() async throws -> [RegistrySkill] {
        let endpoint = "\(apiBase)/skills?limit=\(featuredLimit)&sort=downloads"
        let data = try await getJSON(endpoint)
        let response: ClawHubSkillsListResponse = try decode(data, endpoint: endpoint)
        return response.items
            .map(registrySkill(from:))
            // The endpoint sorts server-side; re-rank defensively so the browse
            // order is honest even if a future default sort changes.
            .sorted { ($0.installCount ?? 0) > ($1.installCount ?? 0) }
    }

    func search(_ query: String) async throws -> [RegistrySkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty query would be rejected by the endpoint; short-circuit it.
        guard !trimmed.isEmpty else { return [] }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ClawHubError.badURL(trimmed)
        }
        let endpoint = "\(apiBase)/search?q=\(encoded)"
        let data = try await getJSON(endpoint)
        let response: ClawHubSearchResponse = try decode(data, endpoint: endpoint)
        return response.results.map(registrySkill(from:))
    }

    private func registrySkill(from dto: ClawHubSearchResponse.Result) -> RegistrySkill {
        RegistrySkill(
            registry: id,
            identifier: dto.slug,
            slug: dto.slug,
            name: dto.displayName ?? dto.slug,
            summary: dto.summary,
            // The search endpoint reports version null; resolved at fetch time.
            version: dto.version,
            installCount: dto.downloads,
            sourceURL: URL(string: "\(webBase)/\(dto.slug)"),
            // No per-version security scan is exposed on search rows.
            audit: nil
        )
    }

    private func registrySkill(from dto: ClawHubSkillsListResponse.Item) -> RegistrySkill {
        RegistrySkill(
            registry: id,
            identifier: dto.slug,
            slug: dto.slug,
            name: dto.displayName ?? dto.slug,
            summary: dto.summary,
            version: dto.latestVersion,
            installCount: dto.stats?.downloads,
            sourceURL: URL(string: "\(webBase)/\(dto.slug)"),
            audit: nil
        )
    }

    // MARK: Fetch

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        let slug = skill.slug
        let version = try await resolvedVersion(slug: slug, preferred: skill.version)

        // 1. Read the version's file manifest.
        let versionEndpoint = "\(apiBase)/skills/\(encodePath(slug))/versions/\(encodePath(version))"
        let versionData = try await getJSON(versionEndpoint)
        let versionResponse: ClawHubVersionResponse = try decode(versionData, endpoint: versionEndpoint)
        let files = versionResponse.version.files
        guard !files.isEmpty else {
            throw ClawHubError.emptyVersion(slug: slug, version: version)
        }

        // 2. Download every file into `destination`, preserving relative paths.
        for file in files {
            let data = try await getFileData(slug: slug, path: file.path, version: version)
            try write(data, relative: file.path, into: destination)
        }

        // 3. Validate a parseable SKILL.md landed.
        try validateManifest(in: destination, slug: slug, version: version)

        // The registry echoes the canonical semver — the provenance version.
        return versionResponse.version.version
    }

    /// The version to fetch: the caller's known version, else the `latest`
    /// dist-tag from the skill detail endpoint. Throws when neither exists.
    private func resolvedVersion(slug: String, preferred: String?) async throws -> String {
        if let preferred, !preferred.isEmpty { return preferred }
        let endpoint = "\(apiBase)/skills/\(encodePath(slug))"
        let data = try await getJSON(endpoint)
        let detail: ClawHubSkillDetailResponse = try decode(data, endpoint: endpoint)
        guard let latest = detail.skill.latestVersion, !latest.isEmpty else {
            throw ClawHubError.noVersionAvailable(slug: slug)
        }
        return latest
    }

    // MARK: Updates

    /// Current `latest` dist-tag for a ClawHub lock entry — one request against
    /// the skill detail endpoint. `fetch` records the canonical semver as the
    /// entry's version, so the honest comparator is the current `latest` tag.
    /// Returns nil, without touching the network, for entries from other
    /// registries. Hard failures throw so callers can tell "no update" apart
    /// from "couldn't check".
    func latestVersion(for entry: LockEntry) async throws -> String? {
        guard entry.registry == id else { return nil }
        let endpoint = "\(apiBase)/skills/\(encodePath(entry.identifier))"
        let data = try await getJSON(endpoint)
        let detail: ClawHubSkillDetailResponse = try decode(data, endpoint: endpoint)
        return detail.skill.latestVersion
    }

    // MARK: File + validation helpers

    private func write(_ data: Data, relative: String, into destination: URL) throws {
        let target = destination.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: target)
    }

    private func validateManifest(in destination: URL, slug: String, version: String) throws {
        let manifest = destination.appendingPathComponent("SKILL.md")
        guard
            let text = try? String(contentsOf: manifest, encoding: .utf8),
            Frontmatter.parse(text).name != nil
        else {
            throw ClawHubError.missingSkillManifest(slug: slug, version: version)
        }
    }

    // MARK: HTTP

    private func getJSON(_ endpoint: String) async throws -> Data {
        try await get(endpoint, accept: "application/json")
    }

    private func getFileData(slug: String, path: String, version: String) async throws -> Data {
        guard
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let encodedVersion = version.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            throw ClawHubError.badURL(path)
        }
        let endpoint = "\(apiBase)/skills/\(encodePath(slug))/file?path=\(encodedPath)&version=\(encodedVersion)"
        return try await get(endpoint, accept: "application/octet-stream")
    }

    private func get(_ endpoint: String, accept: String) async throws -> Data {
        guard let url = URL(string: endpoint) else { throw ClawHubError.badURL(endpoint) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClawHubError.httpStatus(http.statusCode, endpoint: endpoint)
        }
        return data
    }

    /// Percent-encodes a single URL path segment (a slug or version).
    private func encodePath(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
    }

    private func decode<T: Decodable>(_ data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClawHubError.decoding("\(endpoint): \(error)")
        }
    }
}
