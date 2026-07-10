import Foundation

// MARK: - Errors

/// Errors surfaced by ``ClawHubAdapter``. Messages include the failing endpoint
/// and HTTP status so failures are diagnosable from the UI.
enum ClawHubError: Error, LocalizedError, Equatable {
    /// A non-2xx HTTP response. Carries the status and the endpoint hit.
    case httpStatus(Int, endpoint: String)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)
    /// A URL string could not be formed.
    case badURL(String)
    /// The registry has no published version to resolve for the slug.
    case noVersionAvailable(slug: String)
    /// The fetched version listed no files, so nothing could be downloaded.
    case emptyVersion(slug: String, version: String)
    /// The downloaded tree lacked a parseable SKILL.md with a `name`.
    case missingSkillManifest(slug: String, version: String)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code, endpoint):
            "ClawHub request failed (HTTP \(code)) for \(endpoint)"
        case let .decoding(detail):
            "ClawHub response could not be decoded: \(detail)"
        case let .badURL(string):
            "ClawHub could not form a URL from \"\(string)\""
        case let .noVersionAvailable(slug):
            "ClawHub has no published version for \"\(slug)\""
        case let .emptyVersion(slug, version):
            "ClawHub version \(version) of \"\(slug)\" lists no files"
        case let .missingSkillManifest(slug, version):
            "Fetched ClawHub \(slug)@\(version) but it has no parseable SKILL.md"
        }
    }
}

// MARK: - Decodable DTOs

/// Shape of `GET https://clawhub.ai/api/v1/search?q=…` (public, unauthenticated).
/// Search rows are lean: no per-version security scan is included, so `audit`
/// stays nil until `fetch` resolves a version.
struct ClawHubSearchResponse: Decodable, Sendable {
    let results: [Result]

    struct Result: Decodable, Sendable {
        /// Globally unique registry slug — the registry-native identifier.
        let slug: String
        let displayName: String?
        let summary: String?
        /// Null on the search endpoint; the resolved version comes from `fetch`.
        let version: String?
        let downloads: Int?
    }
}

/// Shape of `GET https://clawhub.ai/api/v1/skills?limit=&sort=&cursor=`
/// (public browse/list). Used by `featured()`.
struct ClawHubSkillsListResponse: Decodable, Sendable {
    let items: [Item]
    let nextCursor: String?

    struct Item: Decodable, Sendable {
        let slug: String
        let displayName: String?
        let summary: String?
        /// `{ "latest": "4.0.1", … }` — dist-tags. Absent on rare rows.
        let tags: [String: String]?
        let stats: Stats?

        var latestVersion: String? { tags?["latest"] }
    }

    struct Stats: Decodable, Sendable {
        let downloads: Int?
        let installs: Int?
        let stars: Int?
    }
}

/// Shape of `GET https://clawhub.ai/api/v1/skills/{slug}` (public detail).
/// Consulted to resolve the `latest` dist-tag when a version is not known.
struct ClawHubSkillDetailResponse: Decodable, Sendable {
    let skill: Skill

    struct Skill: Decodable, Sendable {
        let slug: String
        let displayName: String?
        let summary: String?
        let tags: [String: String]?
        let stats: ClawHubSkillsListResponse.Stats?

        var latestVersion: String? { tags?["latest"] }
    }
}

/// Shape of `GET https://clawhub.ai/api/v1/skills/{slug}/versions/{version}`
/// (public version detail). The `files` array is the manifest for the download.
struct ClawHubVersionResponse: Decodable, Sendable {
    let version: Version

    struct Version: Decodable, Sendable {
        /// Canonical semver of this release, echoed back from the registry.
        let version: String
        let files: [File]
    }

    struct File: Decodable, Sendable {
        /// Skill-relative path, e.g. "SKILL.md" or "scripts/run.sh".
        let path: String
        let size: Int?
        let sha256: String?
        let contentType: String?
    }
}
