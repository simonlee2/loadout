import Foundation

// MARK: - Errors

/// Errors surfaced by ``SkillsShAdapter``. Messages include the failing
/// endpoint and HTTP status so failures are diagnosable from the UI.
enum SkillsShError: Error, LocalizedError, Equatable {
    /// A non-2xx HTTP response. Carries the status and the endpoint hit.
    case httpStatus(Int, endpoint: String)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)
    /// A URL string could not be formed.
    case badURL(String)
    /// The repository has no SKILL.md matching the requested skill.
    case skillNotFoundInRepo(source: String, skillId: String)
    /// The fetched tree lacked a parseable SKILL.md with a `name`.
    case missingSkillManifest(source: String, skillId: String)
    /// The git-clone fallback failed after the HTTP path also failed.
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code, endpoint):
            "skills.sh request failed (HTTP \(code)) for \(endpoint)"
        case let .decoding(detail):
            "skills.sh response could not be decoded: \(detail)"
        case let .badURL(string):
            "skills.sh could not form a URL from \"\(string)\""
        case let .skillNotFoundInRepo(source, skillId):
            "No SKILL.md for \"\(skillId)\" was found in \(source)"
        case let .missingSkillManifest(source, skillId):
            "Fetched \(source)/\(skillId) but it has no parseable SKILL.md"
        case let .fetchFailed(detail):
            "skills.sh fetch failed: \(detail)"
        }
    }
}

// MARK: - Decodable DTOs

/// Shape of `GET https://skills.sh/api/search?q=…` (the public, unauthenticated
/// endpoint). The `/api/v1/*` endpoints require a Vercel OIDC token and are not
/// used here.
struct SkillsShSearchResponse: Decodable, Sendable {
    let query: String
    let searchType: String?
    let skills: [Skill]

    struct Skill: Decodable, Sendable {
        /// "owner/repo/skillId" — the registry-native identifier.
        let id: String
        /// The skill's directory / frontmatter name, e.g. "find-skills".
        let skillId: String
        let name: String
        let installs: Int?
        /// "owner/repo" of the GitHub repository hosting the skill.
        let source: String
    }
}

/// `GET https://api.github.com/repos/{owner}/{repo}/commits/HEAD`
struct GitHubCommit: Decodable, Sendable {
    let sha: String
}

/// `GET https://api.github.com/repos/{owner}/{repo}/git/trees/{sha}?recursive=1`
struct GitHubTree: Decodable, Sendable {
    let tree: [Entry]
    let truncated: Bool?

    struct Entry: Decodable, Sendable {
        let path: String
        /// "blob" for files, "tree" for directories.
        let type: String
    }
}

// MARK: - Path helpers

/// Pure helpers for locating a skill's subdirectory within a repository file
/// tree. Shared by the HTTP (GitHub API) and git-clone fetch strategies.
enum SkillsShPaths {
    /// True when `path` names a SKILL.md (case-insensitive), at the repo root or
    /// in any subdirectory.
    static func isManifest(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower == "skill.md" || lower.hasSuffix("/skill.md")
    }

    /// The directory portion of `path` ("" for a repo-root file).
    static func directory(of path: String) -> String {
        guard let slash = path.range(of: "/", options: .backwards) else { return "" }
        return String(path[..<slash.lowerBound])
    }

    /// The last path component ("" for the empty root).
    static func basename(of directory: String) -> String {
        directory.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Locates the directory (relative to the repo root) holding the SKILL.md
    /// for `skillId`. The registry's `skillId` equals the SKILL.md frontmatter
    /// `name`, which is not always the directory name (e.g. skillId
    /// "vercel-react-best-practices" lives in "skills/react-best-practices"),
    /// so matching falls back to reading frontmatter.
    ///
    /// Returns nil when no manifest matches. `loadManifest` returns the text of
    /// a SKILL.md given its repo-relative path (used only for the frontmatter
    /// fallback, so it is called lazily).
    static func locateSkillDirectory(
        paths: [String],
        skillId: String,
        loadManifest: (String) async throws -> String?
    ) async throws -> String? {
        let manifests = paths.filter(isManifest)
        guard !manifests.isEmpty else { return nil }

        // 1. Directory name matches the skillId exactly.
        if let match = manifests.first(where: { basename(of: directory(of: $0)) == skillId }) {
            return directory(of: match)
        }
        // 2. A single-skill repository: the one manifest is unambiguous.
        if manifests.count == 1 {
            return directory(of: manifests[0])
        }
        // 3. Frontmatter `name` matches the skillId.
        for manifest in manifests {
            if let text = try await loadManifest(manifest),
               Frontmatter.parse(text).name == skillId {
                return directory(of: manifest)
            }
        }
        return nil
    }

    /// Repo-relative paths of every file under `skillDirectory` (all repo files
    /// when the skill sits at the root).
    static func files(under skillDirectory: String, in blobs: [String]) -> [String] {
        guard !skillDirectory.isEmpty else { return blobs }
        let prefix = skillDirectory + "/"
        return blobs.filter { $0.hasPrefix(prefix) }
    }

    /// Path of `filePath` relative to `skillDirectory` — the location it should
    /// take inside the destination directory.
    static func destinationRelativePath(for filePath: String, skillDirectory: String) -> String {
        guard !skillDirectory.isEmpty else { return filePath }
        let prefix = skillDirectory + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : filePath
    }
}

// MARK: - Default git-clone fallback

/// Default implementation of the injectable git-clone closure: shallow-clones a
/// public GitHub repo into `directory` and returns the resolved commit SHA.
/// Only invoked when the HTTP (GitHub API) fetch path fails.
func skillsShDefaultGitClone(source: String, into directory: URL) async throws -> String {
    try runGit(["clone", "--depth", "1", "https://github.com/\(source).git", directory.path])
    let sha = try runGit(["-C", directory.path, "rev-parse", "HEAD"])
    return sha.trimmingCharacters(in: .whitespacesAndNewlines)
}

@discardableResult
private func runGit(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw SkillsShError.fetchFailed("git \(arguments.first ?? "") failed: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return String(data: outData, encoding: .utf8) ?? ""
}
