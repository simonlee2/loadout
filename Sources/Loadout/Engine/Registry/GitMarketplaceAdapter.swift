import Foundation

/// Registry adapter that turns **any git repository** into a skill registry.
///
/// The remote is shallow-cloned into a per-remote cache directory on first use
/// and refreshed (`git fetch --depth 1` + `git reset --hard`) on subsequent
/// calls; the checkout is the entire corpus for `featured`/`search`, so those
/// need no network beyond the one refresh. Two repository layouts are
/// auto-detected at the checkout root:
///
///  1. **Claude Code plugin marketplace** — a `.claude-plugin/marketplace.json`
///     listing `plugins`, each with a `source` path into the repo. Skills live
///     under `<pluginRoot>/skills/*/SKILL.md`. A skill's version is the
///     manifest plugin version if present, else the repo HEAD short SHA.
///  2. **Plain skills tree** — no manifest: `skills/*/SKILL.md` when a `skills/`
///     directory exists, else `*/SKILL.md` at the repo root. Version is the repo
///     HEAD short SHA.
///
/// Authentication: SSH remotes rely on the user's ssh setup. For HTTPS remotes,
/// a per-remote Keychain token (when present) is injected as a process argument
/// only — `https://x-access-token:<token>@host/…` plus an empty
/// `-c credential.helper=` — never logged, written to disk, or included in an
/// error message. A private repo with no token makes git fail fast, surfaced as
/// ``GitMarketplaceError/authenticationRequired(remote:)``.
struct GitMarketplaceAdapter: RegistryAdapter {
    let id: String
    let displayName: String

    /// Runs git with the given arguments and working directory, returning its
    /// combined output. Injectable so tests run against local fixture repos.
    typealias GitRunner = @Sendable (_ args: [String], _ cwd: URL?) async throws -> String
    /// Returns the git access token for this remote, or nil. Injectable; the
    /// default reads the per-remote Keychain entry.
    typealias CredentialProvider = @Sendable () -> String?

    let remoteURL: URL
    /// Canonical "host/path" slug — also the cache subdirectory and Keychain account.
    let slug: String
    let cacheRoot: URL
    let gitRunner: GitRunner
    let credential: CredentialProvider

    init(
        remoteURL: URL,
        displayName: String,
        cacheRoot: URL = GitMarketplaceAdapter.defaultCacheRoot(),
        gitRunner: @escaping GitRunner = gitMarketplaceDefaultGitRunner,
        credential: CredentialProvider? = nil
    ) {
        let slug = GitRemoteSlug.slug(for: remoteURL)
        self.remoteURL = remoteURL
        self.slug = slug
        self.id = "git:" + slug
        self.displayName = displayName
        self.cacheRoot = cacheRoot
        self.gitRunner = gitRunner
        self.credential = credential ?? {
            KeychainCredential.read(service: KeychainCredential.defaultService, account: slug)
        }
    }

    /// `<App Support>/Loadout/git`.
    static func defaultCacheRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Loadout/git", isDirectory: true)
    }

    /// The local checkout directory for this remote.
    private var checkoutDirectory: URL {
        cacheRoot.appendingPathComponent(slug, isDirectory: true)
    }

    // MARK: Browse

    func featured() async throws -> [RegistrySkill] {
        try await refresh()
        return try await discoverSkills()
    }

    func search(_ query: String) async throws -> [RegistrySkill] {
        try await refresh()
        let all = try await discoverSkills()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { skill in
            skill.slug.lowercased().contains(needle)
                || skill.name.lowercased().contains(needle)
                || (skill.summary?.lowercased().contains(needle) ?? false)
        }
    }

    // MARK: Fetch

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        try await refresh()
        let checkout = checkoutDirectory
        let skillDir = checkout.appendingPathComponent(skill.identifier, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skillDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitMarketplaceError.skillNotFound(identifier: skill.identifier)
        }

        // Copy the skill's directory tree into the (empty) destination.
        let contents = try FileManager.default.contentsOfDirectory(
            at: skillDir,
            includingPropertiesForKeys: nil
        )
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try FileManager.default.copyItem(at: item, to: target)
        }

        try validateManifest(in: destination, slug: skill.slug)
        return try await headSHA(short: false)
    }

    // MARK: Updates

    /// Current remote HEAD (full SHA) for a lock entry from this registry — one
    /// `git ls-remote <remote> HEAD` call, no full refresh needed. Returns nil,
    /// without touching the network, for entries from other registries.
    func latestVersion(for entry: LockEntry) async throws -> String? {
        guard entry.registry == id else { return nil }
        let token = credential()
        let output = try await runNetworkGit(
            networkArgs(token: token) + ["ls-remote", authenticatedRemote(token: token), "HEAD"],
            cwd: nil,
            token: token
        )
        // Lines look like "<sha>\tHEAD"; take the first field of the first line.
        let firstLine = output.split(whereSeparator: \.isNewline).first ?? ""
        let sha = firstLine.split(whereSeparator: { $0 == "\t" || $0 == " " }).first
        return sha.map(String.init)
    }

    // MARK: Refresh

    /// Ensures the checkout exists and matches the remote HEAD, cloning on first
    /// use, fetching + resetting otherwise, and re-cloning on a corrupt cache.
    private func refresh() async throws {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let checkout = checkoutDirectory
        let gitDir = checkout.appendingPathComponent(".git")

        if FileManager.default.fileExists(atPath: gitDir.path) {
            do {
                let token = credential()
                try await runNetworkGit(
                    networkArgs(token: token) + ["fetch", "--depth", "1", "--quiet", "origin", "HEAD"],
                    cwd: checkout,
                    token: token
                )
                _ = try await gitRunner(["reset", "--hard", "--quiet", "FETCH_HEAD"], checkout)
                _ = try? await gitRunner(["clean", "-fd", "--quiet"], checkout)
                return
            } catch let error as GitMarketplaceError {
                // Auth failures are terminal; anything else is treated as a
                // corrupt cache and repaired by a fresh clone.
                if case .authenticationRequired = error { throw error }
            } catch {
                // Non-GitMarketplaceError: also treat as corruption.
            }
            try? FileManager.default.removeItem(at: checkout)
        } else {
            try? FileManager.default.removeItem(at: checkout)
        }

        try await cloneFresh(into: checkout)
    }

    private func cloneFresh(into checkout: URL) async throws {
        // The slug can contain path separators (github.com/owner/repo);
        // git clone won't create the intermediate directories itself.
        try FileManager.default.createDirectory(
            at: checkout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let token = credential()
        try await runNetworkGit(
            networkArgs(token: token)
                + ["clone", "--depth", "1", "--quiet", authenticatedRemote(token: token), checkout.path],
            cwd: nil,
            token: token
        )
    }

    /// Runs a network git command, classifying auth failures and stripping any
    /// injected token from a surfaced error.
    @discardableResult
    private func runNetworkGit(_ args: [String], cwd: URL?, token: String?) async throws -> String {
        do {
            return try await gitRunner(args, cwd)
        } catch {
            if isAuthFailure(error) {
                throw GitMarketplaceError.authenticationRequired(remote: slug)
            }
            throw sanitized(error, token: token)
        }
    }

    // MARK: Auth helpers

    /// Extra `-c` args disabling any credential helper when a token is injected.
    private func networkArgs(token: String?) -> [String] {
        guard token != nil, remoteURL.absoluteString.hasPrefix("https://") else { return [] }
        return ["-c", "credential.helper="]
    }

    /// The remote to hand git: for HTTPS remotes with a token, a URL rewritten
    /// to `https://x-access-token:<token>@host/…`; otherwise the remote as-is.
    private func authenticatedRemote(token: String?) -> String {
        let base = remoteURL.absoluteString
        guard let token, base.hasPrefix("https://") else { return base }
        var rest = String(base.dropFirst("https://".count))
        // Drop any existing userinfo before the host.
        if let at = rest.firstIndex(of: "@") {
            let firstSlash = rest.firstIndex(of: "/")
            if firstSlash == nil || at < firstSlash! {
                rest = String(rest[rest.index(after: at)...])
            }
        }
        return "https://x-access-token:\(token)@\(rest)"
    }

    private func isAuthFailure(_ error: Error) -> Bool {
        let text = failureText(error).lowercased()
        return text.contains("authentication failed")
            || text.contains("could not read username")
            || text.contains("could not read password")
            || text.contains("repository not found")
    }

    private func failureText(_ error: Error) -> String {
        if let git = error as? GitMarketplaceError, case let .gitFailed(_, stderr) = git {
            return stderr
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    /// Replaces the injected token in a surfaced error so it never leaks.
    private func sanitized(_ error: Error, token: String?) -> Error {
        guard let token, !token.isEmpty,
              let git = error as? GitMarketplaceError,
              case let .gitFailed(command, stderr) = git else {
            return error
        }
        let clean = stderr.replacingOccurrences(of: token, with: "***")
        return GitMarketplaceError.gitFailed(command: command, stderr: clean)
    }

    // MARK: Discovery

    private func discoverSkills() async throws -> [RegistrySkill] {
        let checkout = checkoutDirectory
        let head = (try? await headSHA(short: true)) ?? "HEAD"

        let manifestURL = checkout.appendingPathComponent(".claude-plugin/marketplace.json")
        let discovered: [Discovered]
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            discovered = try discoverPlugins(manifestURL: manifestURL, checkout: checkout, shortSHA: head)
        } else {
            discovered = discoverPlainTree(checkout: checkout, shortSHA: head)
        }

        return discovered.map { registrySkill(from: $0, shortSHA: head) }
    }

    private func discoverPlugins(manifestURL: URL, checkout: URL, shortSHA: String) throws -> [Discovered] {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw GitMarketplaceError.invalidManifest(error.localizedDescription)
        }
        let manifest: GitMarketplaceManifest
        do {
            manifest = try JSONDecoder().decode(GitMarketplaceManifest.self, from: data)
        } catch {
            throw GitMarketplaceError.invalidManifest("\(error)")
        }

        var result: [Discovered] = []
        for plugin in manifest.plugins {
            let pluginRoot = resolvePluginRoot(checkout: checkout, source: plugin.source?.path ?? ".")
            let skillsDir = pluginRoot.appendingPathComponent("skills", isDirectory: true)
            let version = plugin.version.flatMap { $0.isEmpty ? nil : $0 } ?? shortSHA
            for found in SkillScan.installations(in: skillsDir) {
                result.append(Discovered(
                    slug: found.slug,
                    relativePath: relativePath(of: found.directory, under: checkout),
                    metadata: found.metadata,
                    version: version
                ))
            }
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func discoverPlainTree(checkout: URL, shortSHA: String) -> [Discovered] {
        let skillsDir = checkout.appendingPathComponent("skills", isDirectory: true)
        var isDirectory: ObjCBool = false
        let base = FileManager.default.fileExists(atPath: skillsDir.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? skillsDir : checkout

        return SkillScan.installations(in: base).map { found in
            Discovered(
                slug: found.slug,
                relativePath: relativePath(of: found.directory, under: checkout),
                metadata: found.metadata,
                version: shortSHA
            )
        }
    }

    private func registrySkill(from discovered: Discovered, shortSHA: String) -> RegistrySkill {
        RegistrySkill(
            registry: id,
            identifier: discovered.relativePath,
            slug: discovered.slug,
            name: discovered.metadata.name ?? discovered.slug,
            summary: discovered.metadata.description,
            version: discovered.version,
            installCount: nil,
            sourceURL: webSourceURL(relativePath: discovered.relativePath, shortSHA: shortSHA),
            audit: nil
        )
    }

    /// A GitHub web URL for the skill's directory when the remote is github.com,
    /// pinned to the current short SHA (always valid); nil for other hosts.
    private func webSourceURL(relativePath: String, shortSHA: String) -> URL? {
        let parts = slug.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "github.com" else { return nil }
        let repo = "https://github.com/\(parts[1])/\(parts[2])"
        if shortSHA == "HEAD" { return URL(string: repo) }
        let encoded = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(repo)/tree/\(shortSHA)/\(encoded)")
    }

    // MARK: Path + validation helpers

    private func resolvePluginRoot(checkout: URL, source: String) -> URL {
        var path = source
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty || path == "." { return checkout }
        return checkout.appendingPathComponent(path, isDirectory: true)
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func validateManifest(in destination: URL, slug: String) throws {
        let manifest = destination.appendingPathComponent("SKILL.md")
        guard
            let text = try? String(contentsOf: manifest, encoding: .utf8),
            Frontmatter.parse(text).name != nil
        else {
            throw GitMarketplaceError.missingSkillManifest(slug: slug)
        }
    }

    private func headSHA(short: Bool) async throws -> String {
        let args = short ? ["rev-parse", "--short", "HEAD"] : ["rev-parse", "HEAD"]
        let output = try await gitRunner(args, checkoutDirectory)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: -

    private struct Discovered {
        let slug: String
        let relativePath: String
        let metadata: SkillMetadata
        let version: String
    }
}
