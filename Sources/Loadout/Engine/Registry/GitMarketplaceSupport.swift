import Foundation
import Security

// MARK: - Errors

/// Errors surfaced by ``GitMarketplaceAdapter``. Messages are diagnosable from
/// the UI and never contain injected credentials (tokens are stripped before a
/// git failure is surfaced).
enum GitMarketplaceError: Error, LocalizedError, Equatable {
    /// A git invocation exited non-zero. `stderr` is the (token-stripped)
    /// combined output; `command` is a redacted description of the command.
    case gitFailed(command: String, stderr: String)
    /// git could not authenticate against the remote. Carries the remote's
    /// canonical slug only — never a token.
    case authenticationRequired(remote: String)
    /// The identified skill directory was not present in the checkout.
    case skillNotFound(identifier: String)
    /// The fetched tree lacked a parseable SKILL.md with a `name`.
    case missingSkillManifest(slug: String)
    /// A present `.claude-plugin/marketplace.json` could not be parsed.
    case invalidManifest(String)
    /// A Keychain SecItem operation failed.
    case keychain(status: Int32)

    var errorDescription: String? {
        switch self {
        case let .gitFailed(command, stderr):
            return "git command failed (\(command)): \(stderr)"
        case let .authenticationRequired(remote):
            return "Authentication is required for \(remote). Add a git access token for "
                + "this repository in Loadout, then try again."
        case let .skillNotFound(identifier):
            return "No skill directory \"\(identifier)\" was found in the repository."
        case let .missingSkillManifest(slug):
            return "Fetched \"\(slug)\" but it has no parseable SKILL.md."
        case let .invalidManifest(detail):
            return "The marketplace manifest could not be parsed: \(detail)"
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain operation failed: \(message)"
        }
    }
}

// MARK: - Manifest DTOs

/// Lenient model of `.claude-plugin/marketplace.json` (a Claude Code plugin
/// marketplace manifest). Only the fields this adapter needs are modelled; a
/// missing or malformed `plugins` array decodes to an empty list rather than
/// failing the whole parse.
struct GitMarketplaceManifest: Decodable, Sendable {
    let plugins: [Plugin]

    enum CodingKeys: String, CodingKey { case plugins }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugins = (try? container.decode([Plugin].self, forKey: .plugins)) ?? []
    }

    struct Plugin: Decodable, Sendable {
        let name: String?
        let description: String?
        let version: String?
        let source: PluginSource?
    }
}

/// A plugin's `source`, which may be a bare string path or an object carrying a
/// `path`/`source` key. Only the repo-relative path is retained.
struct PluginSource: Decodable, Sendable {
    let path: String?

    enum CodingKeys: String, CodingKey { case path, source }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            path = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? container.decode(String.self, forKey: .path))
            ?? (try? container.decode(String.self, forKey: .source))
    }
}

// MARK: - Remote slug

/// Pure helpers for turning a git remote into a stable, filesystem-friendly
/// slug ("host/owner/repo"), used for the adapter id, cache directory, and the
/// Keychain account.
enum GitRemoteSlug {
    /// Canonical "host/path" slug for a remote URL. Handles https/ssh/git/file
    /// schemes and the scp-like `git@host:owner/repo.git` form. Strips any
    /// userinfo (including an injected `x-access-token:…`), a trailing `.git`,
    /// and a trailing slash.
    static func slug(for remote: URL) -> String {
        slug(forString: remote.absoluteString)
    }

    static func slug(forString raw: String) -> String {
        var rest = raw

        if let schemeRange = rest.range(of: "://") {
            // scheme://[userinfo@]host/path
            rest = String(rest[schemeRange.upperBound...])
        } else if let colon = rest.firstIndex(of: ":"), rest.contains("@"),
                  !rest.hasPrefix("/") {
            // scp-like: [user@]host:owner/repo — turn the first ':' into '/'.
            rest.replaceSubrange(colon...colon, with: "/")
        }

        // Strip userinfo appearing before the first path separator.
        if let at = rest.firstIndex(of: "@") {
            let firstSlash = rest.firstIndex(of: "/")
            if firstSlash == nil || at < firstSlash! {
                rest = String(rest[rest.index(after: at)...])
            }
        }

        if rest.hasSuffix(".git") { rest.removeLast(4) }
        while rest.hasSuffix("/") { rest.removeLast() }
        while rest.hasPrefix("/") { rest.removeFirst() }
        return rest
    }
}

// MARK: - KeychainCredential

/// Minimal generic-password Keychain helper for storing per-remote git access
/// tokens. The UI for entering tokens comes later; `write` exists so the
/// integrator can store one programmatically.
enum KeychainCredential {
    /// Shared service string for all Loadout git credentials.
    static let defaultService = "com.cardinalblue.loadout.git"

    /// Reads the token for `account`, or nil when absent.
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores (replacing any existing) the token for `account`.
    static func write(_ value: String, service: String, account: String) throws {
        try delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw GitMarketplaceError.keychain(status: status) }
    }

    /// Removes the token for `account`. A missing item is not an error.
    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitMarketplaceError.keychain(status: status)
        }
    }
}

// MARK: - Default git runner

/// Default implementation of ``GitMarketplaceAdapter/GitRunner``: runs
/// `/usr/bin/git` with the given arguments and working directory, with
/// `GIT_TERMINAL_PROMPT=0` so missing auth fails fast instead of hanging.
///
/// stdout and stderr are merged into one pipe and drained by a single reader so
/// git's progress output (which goes to stderr) cannot deadlock the buffer.
@Sendable
func gitMarketplaceDefaultGitRunner(_ arguments: [String], _ cwd: URL?) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }

    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    // Single reader draining continuously — safe with merged streams.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw GitMarketplaceError.gitFailed(
            command: "git \(arguments.first ?? "")",
            stderr: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    return output
}
