import Foundation
import CryptoKit

/// Registry adapter for the **Well-known Agent Skills** convention: any website
/// that publishes `/.well-known/skills/index.json` acts as a skill source.
///
/// This is the open convention implemented by Nous Research's Hermes agent
/// (`tools/skills_hub.py::WellKnownSkillSource`) — verified against that
/// shipping source on 2026-07-10. Hermes' own skills hub is a JS-rendered
/// aggregator with no documented public browse/search API, but the well-known
/// convention it federates over is a concrete, code-defined contract, so this
/// adapter targets the convention directly. One instance is bound to one site,
/// which future-proofs any company site (or an internal host) as a Loadout
/// registry.
///
/// Field mapping is deliberately honest about what the convention carries:
///
/// - `search(_:)` filters the site's own index by name/description; the index is
///   the entire corpus, so there is no separate server-side query endpoint.
/// - `featured()` returns the full published index (its natural browse view).
/// - The index exposes no install counts and no security-audit verdict (Hermes
///   runs its *own* scanner *after* fetching), so `installCount` and `audit`
///   are nil.
/// - `version`/`latestVersion(for:)` are answerable only when a publisher adds
///   the optional `version` field (not in the base spec); `fetch` otherwise
///   records a content digest of SKILL.md as the provenance version.
///
/// Every index-controlled skill name and file path is validated against
/// traversal/absolute-path attacks (mirroring the reference `_normalize_bundle_path`)
/// before any request or disk write, since the index is untrusted remote input.
struct WellKnownAdapter: RegistryAdapter {
    let id: String
    let displayName: String

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// HTTP transport, injectable for offline tests. Defaults to `URLSession.shared`.
    var transport: Transport

    /// `<site>/.well-known/skills/index.json`.
    private let indexURLString: String
    /// `<site>/.well-known/skills`.
    private let skillsBaseURLString: String
    private let userAgent = "Loadout/0.1"
    private let timeout: TimeInterval = 15

    /// Binds the adapter to a site. `site` may be the bare root
    /// ("https://ex.com"), the well-known directory, or the index file itself;
    /// all normalize to the same index URL. Fails for non-HTTP(S) URLs or URLs
    /// with no host.
    init?(
        site: URL,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        guard
            let scheme = site.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = site.host,
            let indexURL = WellKnownPaths.indexURL(forSite: site.absoluteString)
        else { return nil }
        self.indexURLString = indexURL
        self.skillsBaseURLString = WellKnownPaths.skillsBase(fromIndexURL: indexURL)
        self.id = "well-known:\(host)"
        self.displayName = host
        self.transport = transport
    }

    // MARK: Browse

    func featured() async throws -> [RegistrySkill] {
        try await index().skills.map(registrySkill(from:))
    }

    func search(_ query: String) async throws -> [RegistrySkill] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let skills = try await index().skills
        guard !needle.isEmpty else { return skills.map(registrySkill(from:)) }
        return skills
            .filter { entry in
                entry.name.lowercased().contains(needle)
                    || (entry.description?.lowercased().contains(needle) ?? false)
            }
            .map(registrySkill(from:))
    }

    private func registrySkill(from entry: WellKnownIndex.Entry) -> RegistrySkill {
        let version = entry.version.flatMap { $0.isEmpty ? nil : $0 }
        return RegistrySkill(
            registry: id,
            identifier: WellKnownPaths.wrapIdentifier(skillsBaseURL: skillsBaseURLString, name: entry.name),
            slug: entry.name,
            name: entry.name,
            summary: entry.description,
            version: version,
            // The convention exposes no install counts.
            installCount: nil,
            sourceURL: URL(string: "\(skillsBaseURLString)/\(entry.name)"),
            // No security-audit verdict is published; Hermes scans post-fetch.
            audit: nil
        )
    }

    // MARK: Fetch

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        // Resolve the index + skill URLs from the identifier when possible so the
        // fetch is self-contained; fall back to this adapter's base + slug.
        let parsed = WellKnownPaths.parseIdentifier(skill.identifier)
        let indexURLString = parsed?.indexURL ?? self.indexURLString
        let skillURLString = parsed?.skillURL ?? "\(skillsBaseURLString)/\(skill.slug)"
        let rawName = parsed?.skillName ?? skill.slug

        guard let skillName = WellKnownPaths.validateSkillName(rawName) else {
            throw WellKnownError.unsafeSkillName(rawName)
        }

        let entries = try await index(at: indexURLString).skills
        guard let entry = entries.first(where: { $0.name == skillName }) else {
            throw WellKnownError.skillNotInIndex(name: skillName, indexURL: indexURLString)
        }

        let files = (entry.files?.isEmpty == false ? entry.files! : ["SKILL.md"])
        var manifestData: Data?
        for rawPath in files {
            guard let relative = WellKnownPaths.validateRelativePath(rawPath) else {
                throw WellKnownError.unsafeFilePath(rawPath)
            }
            let data = try await getData("\(skillURLString)/\(encodePath(relative))")
            try write(data, relative: relative, into: destination)
            if relative == "SKILL.md" { manifestData = data }
        }

        try validateManifest(in: destination, name: skillName)

        // Prefer a publisher-supplied version; else a content digest of SKILL.md.
        if let version = entry.version, !version.isEmpty {
            return version
        }
        let manifest = manifestData ?? (try? Data(contentsOf: destination.appendingPathComponent("SKILL.md"))) ?? Data()
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest.prefix(12))"
    }

    // MARK: Updates

    /// The site's current version for an installed entry, when the publisher
    /// supplies the optional `version` field. Returns nil (without failing) when
    /// the entry is from another registry or the index carries no version — the
    /// base convention is unversioned, so updates can't be detected cheaply. A
    /// single index request; hard failures throw so callers distinguish
    /// "no update" from "couldn't check".
    func latestVersion(for entry: LockEntry) async throws -> String? {
        guard entry.registry == id else { return nil }
        guard let parsed = WellKnownPaths.parseIdentifier(entry.identifier) else { return nil }
        let skills = try await index(at: parsed.indexURL).skills
        guard let match = skills.first(where: { $0.name == parsed.skillName }) else { return nil }
        return match.version.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Index

    private func index() async throws -> WellKnownIndex {
        try await index(at: indexURLString)
    }

    private func index(at endpoint: String) async throws -> WellKnownIndex {
        let data = try await getJSON(endpoint)
        return try decode(data, endpoint: endpoint)
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

    private func validateManifest(in destination: URL, name: String) throws {
        let manifest = destination.appendingPathComponent("SKILL.md")
        guard
            let text = try? String(contentsOf: manifest, encoding: .utf8),
            Frontmatter.parse(text).name != nil
        else {
            throw WellKnownError.missingSkillManifest(name: name)
        }
    }

    /// Percent-encodes each path segment while preserving the slashes.
    private func encodePath(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    // MARK: HTTP

    private func getJSON(_ endpoint: String) async throws -> Data {
        try await get(endpoint, accept: "application/json")
    }

    private func getData(_ endpoint: String) async throws -> Data {
        try await get(endpoint, accept: "application/octet-stream")
    }

    private func get(_ endpoint: String, accept: String) async throws -> Data {
        guard let url = URL(string: endpoint) else { throw WellKnownError.badURL(endpoint) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WellKnownError.httpStatus(http.statusCode, endpoint: endpoint)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WellKnownError.decoding("\(endpoint): \(error)")
        }
    }
}
