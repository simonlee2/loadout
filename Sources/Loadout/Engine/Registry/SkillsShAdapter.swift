import Foundation

/// Registry adapter for [skills.sh](https://skills.sh), Vercel's directory of
/// GitHub-hosted agent skills.
///
/// Only the public `GET /api/search?q=` endpoint is unauthenticated; the
/// documented `/api/v1/*` endpoints (leaderboard, curated, skill detail with a
/// `files` array, and security audits) require a Vercel OIDC token we do not
/// have. Consequences:
///
/// - `featured()` has no public leaderboard endpoint, so it approximates one by
///   ranking a broad search query by install count.
/// - `search(_:)` maps the public search rows; the endpoint exposes no
///   description, version, or audit signal, so those are nil.
/// - `fetch(_:to:)` cannot use the authenticated file-list endpoint. It resolves
///   the skill's files straight from GitHub: the commit SHA + recursive tree via
///   the GitHub REST API (over the injectable transport, so tests run offline),
///   with a `git clone --depth 1` fallback behind an injectable closure.
struct SkillsShAdapter: RegistryAdapter {
    let id = "skills.sh"
    let displayName = "skills.sh"

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// Clones `source` ("owner/repo") into the given directory and returns the
    /// resolved commit SHA. Injectable so the git fallback stays offline in tests.
    typealias GitClone = @Sendable (_ source: String, _ into: URL) async throws -> String

    /// HTTP transport, injectable for offline tests. Defaults to `URLSession.shared`.
    var transport: Transport
    /// git-clone fallback, injectable for tests. Defaults to a real shallow clone.
    var gitClone: GitClone

    private let apiBase = "https://skills.sh/api"
    private let userAgent = "Loadout/0.1"
    private let timeout: TimeInterval = 15

    init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        gitClone: @escaping GitClone = skillsShDefaultGitClone
    ) {
        self.transport = transport
        self.gitClone = gitClone
    }

    // MARK: Browse

    func featured() async throws -> [RegistrySkill] {
        // No public leaderboard endpoint exists (see type docs). Approximate the
        // "top skills" browse view by ranking a broad search by install count.
        let results = try await search("skill")
        return results.sorted { ($0.installCount ?? 0) > ($1.installCount ?? 0) }
    }

    func search(_ query: String) async throws -> [RegistrySkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The endpoint rejects queries shorter than 2 characters.
        guard trimmed.count >= 2 else { return [] }
        guard
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            throw SkillsShError.badURL(trimmed)
        }
        let endpoint = "\(apiBase)/search?q=\(encoded)"
        let data = try await getJSON(endpoint)
        let response: SkillsShSearchResponse = try decode(data, endpoint: endpoint)
        return response.skills.map(registrySkill(from:))
    }

    private func registrySkill(from dto: SkillsShSearchResponse.Skill) -> RegistrySkill {
        RegistrySkill(
            registry: id,
            identifier: dto.id,
            // The directory name the skill installs as (D: equals skillId).
            slug: dto.skillId,
            name: dto.name,
            // The public search endpoint exposes no description.
            summary: nil,
            // No version, tag, or audit is exposed until fetch resolves the SHA.
            version: nil,
            installCount: dto.installs,
            // Honest, always-valid source: the hosting GitHub repository.
            sourceURL: URL(string: "https://github.com/\(dto.source)"),
            audit: nil
        )
    }

    // MARK: Fetch

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        let source = repoSource(for: skill)
        let skillId = skill.slug
        do {
            return try await fetchViaGitHubAPI(source: source, skillId: skillId, to: destination)
        } catch {
            // Fall back to a shallow git clone (e.g. GitHub API rate-limited).
            return try await fetchViaGit(
                source: source,
                skillId: skillId,
                to: destination,
                primaryError: error
            )
        }
    }

    // MARK: Updates

    /// Current upstream commit SHA for a skills.sh-managed lock entry.
    ///
    /// `fetch` records the repo HEAD commit SHA as the entry's provenance
    /// version, so the honest comparator is the repo's CURRENT HEAD — one
    /// request: `GET /repos/{owner}/{repo}/commits/HEAD` (the entry's
    /// identifier is "owner/repo/skillId"). Returns nil, without touching the
    /// network, for entries from other registries or with an identifier too
    /// short to name a repository. Hard failures (HTTP errors, transport
    /// errors, undecodable bodies) throw so callers can distinguish "no
    /// update" from "couldn't check".
    func latestVersion(for entry: LockEntry) async throws -> String? {
        guard entry.registry == id else { return nil }
        let parts = entry.identifier.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let source = parts.prefix(2).joined(separator: "/")
        let endpoint = "https://api.github.com/repos/\(source)/commits/HEAD"
        let data = try await getJSON(endpoint, accept: "application/vnd.github+json")
        let commit: GitHubCommit = try decode(data, endpoint: endpoint)
        return commit.sha
    }

    /// "owner/repo" for a skill, derived from its "owner/repo/skillId" identifier
    /// by dropping the trailing slug.
    private func repoSource(for skill: RegistrySkill) -> String {
        let suffix = "/" + skill.slug
        if skill.identifier.hasSuffix(suffix) {
            return String(skill.identifier.dropLast(suffix.count))
        }
        // Fallback: first two path components.
        let parts = skill.identifier.split(separator: "/")
        return parts.prefix(2).joined(separator: "/")
    }

    // MARK: Fetch — GitHub REST API (primary, testable offline)

    private func fetchViaGitHubAPI(source: String, skillId: String, to destination: URL) async throws -> String {
        // 1. Resolve the commit SHA (the returned provenance version).
        let commitEndpoint = "https://api.github.com/repos/\(source)/commits/HEAD"
        let commitData = try await getJSON(commitEndpoint, accept: "application/vnd.github+json")
        let commit: GitHubCommit = try decode(commitData, endpoint: commitEndpoint)
        let sha = commit.sha

        // 2. Fetch the recursive tree pinned to that SHA.
        let treeEndpoint = "https://api.github.com/repos/\(source)/git/trees/\(sha)?recursive=1"
        let treeData = try await getJSON(treeEndpoint, accept: "application/vnd.github+json")
        let tree: GitHubTree = try decode(treeData, endpoint: treeEndpoint)
        let blobs = tree.tree.filter { $0.type == "blob" }.map(\.path)

        // 3. Locate the skill's directory within the tree.
        guard let skillDir = try await SkillsShPaths.locateSkillDirectory(
            paths: blobs,
            skillId: skillId,
            loadManifest: { path in
                try? await getText(rawURL(source: source, sha: sha, path: path))
            }
        ) else {
            throw SkillsShError.skillNotFoundInRepo(source: source, skillId: skillId)
        }

        // 4. Download every file under the skill directory into `destination`.
        let files = SkillsShPaths.files(under: skillDir, in: blobs)
        for path in files {
            let data = try await getData(rawURL(source: source, sha: sha, path: path))
            let relative = SkillsShPaths.destinationRelativePath(for: path, skillDirectory: skillDir)
            try write(data, relative: relative, into: destination)
        }

        // 5. Validate a parseable SKILL.md landed in the destination.
        try validateManifest(in: destination, source: source, skillId: skillId)
        return sha
    }

    private func rawURL(source: String, sha: String, path: String) -> String {
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "https://raw.githubusercontent.com/\(source)/\(sha)/\(encodedPath)"
    }

    // MARK: Fetch — git clone (fallback)

    private func fetchViaGit(
        source: String,
        skillId: String,
        to destination: URL,
        primaryError: Error
    ) async throws -> String {
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadout-skillssh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: clone) }

        let sha: String
        do {
            sha = try await gitClone(source, clone)
        } catch {
            // Surface both failures: the API path is usually the informative one.
            throw SkillsShError.fetchFailed(
                "GitHub API path failed (\(primaryError.localizedDescription)); "
                + "git clone fallback also failed (\(error.localizedDescription))"
            )
        }

        // Enumerate cloned files as repo-relative paths (excluding .git).
        let cloneRoot = clone.standardizedFileURL
        let relativePaths = Self.regularFileRelativePaths(under: cloneRoot)

        guard let skillDir = try await SkillsShPaths.locateSkillDirectory(
            paths: relativePaths,
            skillId: skillId,
            loadManifest: { path in
                try? String(contentsOf: cloneRoot.appendingPathComponent(path), encoding: .utf8)
            }
        ) else {
            throw SkillsShError.skillNotFoundInRepo(source: source, skillId: skillId)
        }

        for path in SkillsShPaths.files(under: skillDir, in: relativePaths) {
            let data = try Data(contentsOf: cloneRoot.appendingPathComponent(path))
            let relative = SkillsShPaths.destinationRelativePath(for: path, skillDirectory: skillDir)
            try write(data, relative: relative, into: destination)
        }

        try validateManifest(in: destination, source: source, skillId: skillId)
        return sha
    }

    /// Repo-relative paths of every regular file under `root`, excluding `.git`.
    /// A synchronous helper because `FileManager` enumerators cannot be iterated
    /// from an async context.
    private static func regularFileRelativePaths(under root: URL) -> [String] {
        let fm = FileManager.default
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var paths: [String] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return paths
        }
        for case let url as URL in walker {
            if url.pathComponents.contains(".git") { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            if full.hasPrefix(rootPrefix) {
                paths.append(String(full.dropFirst(rootPrefix.count)))
            }
        }
        return paths
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

    private func validateManifest(in destination: URL, source: String, skillId: String) throws {
        let manifest = destination.appendingPathComponent("SKILL.md")
        guard
            let text = try? String(contentsOf: manifest, encoding: .utf8),
            Frontmatter.parse(text).name != nil
        else {
            throw SkillsShError.missingSkillManifest(source: source, skillId: skillId)
        }
    }

    // MARK: HTTP

    private func getJSON(_ endpoint: String, accept: String = "application/json") async throws -> Data {
        try await get(endpoint, accept: accept)
    }

    private func getText(_ endpoint: String) async throws -> String {
        let data = try await get(endpoint, accept: "text/plain")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func getData(_ endpoint: String) async throws -> Data {
        try await get(endpoint, accept: "application/octet-stream")
    }

    private func get(_ endpoint: String, accept: String) async throws -> Data {
        guard let url = URL(string: endpoint) else { throw SkillsShError.badURL(endpoint) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SkillsShError.httpStatus(http.statusCode, endpoint: endpoint)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SkillsShError.decoding("\(endpoint): \(error)")
        }
    }
}
