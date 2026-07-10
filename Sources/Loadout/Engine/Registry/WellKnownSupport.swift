import Foundation

// MARK: - Errors

/// Errors surfaced by ``WellKnownAdapter``. Messages include the failing
/// endpoint/name so failures are diagnosable from the UI.
enum WellKnownError: Error, LocalizedError, Equatable {
    /// A URL string could not be formed (bad site URL, unsafe skill URL…).
    case badURL(String)
    /// A non-2xx HTTP response. Carries the status and the endpoint hit.
    case httpStatus(Int, endpoint: String)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)
    /// The site's index has no entry with the requested skill name.
    case skillNotInIndex(name: String, indexURL: String)
    /// The index (or an identifier) named a skill whose name is unsafe
    /// (path traversal, absolute path…). Never fetched.
    case unsafeSkillName(String)
    /// The index advertised a file whose relative path is unsafe. Never fetched.
    case unsafeFilePath(String)
    /// The fetched files lacked a parseable SKILL.md with a `name`.
    case missingSkillManifest(name: String)

    var errorDescription: String? {
        switch self {
        case let .badURL(string):
            "well-known: could not form a URL from \"\(string)\""
        case let .httpStatus(code, endpoint):
            "well-known request failed (HTTP \(code)) for \(endpoint)"
        case let .decoding(detail):
            "well-known response could not be decoded: \(detail)"
        case let .skillNotInIndex(name, indexURL):
            "No skill named \"\(name)\" is listed in \(indexURL)"
        case let .unsafeSkillName(name):
            "well-known index advertised an unsafe skill name: \"\(name)\""
        case let .unsafeFilePath(path):
            "well-known index advertised an unsafe file path: \"\(path)\""
        case let .missingSkillManifest(name):
            "Fetched \"\(name)\" but it has no parseable SKILL.md"
        }
    }
}

// MARK: - Decodable DTOs

/// Shape of `GET <site>/.well-known/skills/index.json` — the "Well-known Agent
/// Skills" convention implemented by Nous Research's Hermes agent
/// (`tools/skills_hub.py::WellKnownSkillSource`). Any website can act as a skill
/// source by publishing this document.
///
/// Only `skills[].name` is required; `description` and `files` are optional
/// (files defaults to `["SKILL.md"]`). `version` is a Loadout-honored optional
/// extension used for cheap update checks — the base convention omits it, in
/// which case update detection is unavailable (see ``WellKnownAdapter``).
struct WellKnownIndex: Decodable, Sendable {
    let skills: [Entry]

    struct Entry: Decodable, Sendable {
        /// The skill's directory / frontmatter name, e.g. "pdf-tools".
        let name: String
        let description: String?
        /// Relative paths under the skill directory to download; nil ⇒ ["SKILL.md"].
        let files: [String]?
        /// Optional publisher-supplied version/tag/commit. Not in the base spec.
        let version: String?
    }
}

// MARK: - Path + identifier helpers

/// Pure helpers for the well-known skills convention: normalizing a site URL to
/// its index URL, wrapping/parsing skill identifiers, and validating
/// index-controlled names and file paths before they touch the network or disk.
///
/// These mirror the reference implementation
/// (`tools/skills_hub.py`: `_query_to_index_url`, `_parse_identifier`,
/// `_wrap_identifier`, `_normalize_bundle_path`) so identifiers round-trip with
/// Hermes and the same traversal/SSRF-adjacent inputs are rejected.
enum WellKnownPaths {
    /// The conventional path segment under a site's root.
    static let basePath = "/.well-known/skills"
    /// Identifier scheme prefix, e.g. "well-known:https://ex.com/.well-known/skills/foo".
    static let identifierPrefix = "well-known:"

    struct ParsedIdentifier: Equatable {
        let indexURL: String
        /// The `.../.well-known/skills` base (index URL minus `/index.json`).
        let skillsBaseURL: String
        let skillName: String
        /// The skill's directory URL: `<skillsBaseURL>/<skillName>`.
        let skillURL: String
    }

    /// Normalizes an arbitrary site/index URL string to its index URL.
    ///
    /// Accepts a bare site root ("https://ex.com"), the well-known directory,
    /// or the index file itself, and always returns the `…/index.json` URL.
    /// Returns nil for non-HTTP(S) input.
    static func indexURL(forSite raw: String) -> String? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.hasPrefix("http://") || query.hasPrefix("https://") else { return nil }
        if query.hasSuffix("/index.json") { return query }
        let trimmed = trimTrailingSlashes(query)
        // Already the well-known directory itself.
        if trimmed.hasSuffix(basePath) { return "\(trimmed)/index.json" }
        // The well-known directory appears mid-URL (e.g. a deep link).
        if let range = query.range(of: "\(basePath)/") {
            let base = String(query[..<range.lowerBound]) + basePath
            return "\(base)/index.json"
        }
        return "\(trimmed)\(basePath)/index.json"
    }

    /// The `.../.well-known/skills` base for an index URL.
    static func skillsBase(fromIndexURL indexURL: String) -> String {
        let suffix = "/index.json"
        return indexURL.hasSuffix(suffix) ? String(indexURL.dropLast(suffix.count)) : indexURL
    }

    /// The registry-native identifier for a skill: `well-known:<base>/<name>`.
    static func wrapIdentifier(skillsBaseURL: String, name: String) -> String {
        "\(identifierPrefix)\(trimTrailingSlashes(skillsBaseURL))/\(name)"
    }

    /// Reverses ``wrapIdentifier`` (and tolerates raw index/SKILL.md URLs), so a
    /// stored ``LockEntry`` identifier resolves back to its index + files.
    static func parseIdentifier(_ identifier: String) -> ParsedIdentifier? {
        let raw = identifier.hasPrefix(identifierPrefix)
            ? String(identifier.dropFirst(identifierPrefix.count))
            : identifier
        guard raw.hasPrefix("http://") || raw.hasPrefix("https://") else { return nil }

        // Strip a trailing #fragment (the reference impl used it for the name).
        var clean = raw
        var fragment = ""
        if let hash = raw.firstIndex(of: "#") {
            clean = String(raw[..<hash])
            fragment = String(raw[raw.index(after: hash)...])
        }

        if clean.hasSuffix("/index.json") {
            guard !fragment.isEmpty else { return nil }
            let base = String(clean.dropLast("/index.json".count))
            return ParsedIdentifier(
                indexURL: clean,
                skillsBaseURL: base,
                skillName: fragment,
                skillURL: "\(base)/\(fragment)"
            )
        }

        let skillURL: String
        if clean.hasSuffix("/SKILL.md") {
            skillURL = String(clean.dropLast("/SKILL.md".count))
        } else {
            skillURL = trimTrailingSlashes(clean)
        }
        guard skillURL.contains("\(basePath)/"),
              let slash = skillURL.range(of: "/", options: .backwards)
        else { return nil }
        let base = String(skillURL[..<slash.lowerBound])
        let name = String(skillURL[slash.upperBound...])
        guard !name.isEmpty else { return nil }
        return ParsedIdentifier(
            indexURL: "\(base)/index.json",
            skillsBaseURL: base,
            skillName: name,
            skillURL: skillURL
        )
    }

    /// A skill name must be a single safe path component. Returns the normalized
    /// name, or nil if it is empty, absolute, a drive spec, or contains `..`/`/`.
    static func validateSkillName(_ name: String) -> String? {
        normalize(name, allowNested: false)
    }

    /// A bundle file path may be nested but must not escape the skill directory.
    /// Returns the normalized relative path, or nil if unsafe.
    static func validateRelativePath(_ path: String) -> String? {
        normalize(path, allowNested: true)
    }

    /// Mirrors `tools/skills_hub.py::_normalize_bundle_path`.
    private static func normalize(_ value: String, allowNested: Bool) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") { return nil }
        let parts = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !parts.isEmpty else { return nil }
        if parts.contains("..") { return nil }
        if let first = parts.first,
           first.range(of: "^[A-Za-z]:$", options: .regularExpression) != nil {
            return nil
        }
        if !allowNested && parts.count != 1 { return nil }
        return parts.joined(separator: "/")
    }

    private static func trimTrailingSlashes(_ string: String) -> String {
        var result = string
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
