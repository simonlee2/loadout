import Foundation
import Observation

/// Failures the library reports; every case carries a descriptive message.
enum SkillLibraryError: Error, LocalizedError, CustomStringConvertible {
    case noTargetAgents
    case unknownAgent(AgentID)
    case alreadyInstalled(slug: String)
    case deploymentCollision(slug: String, agent: AgentID, path: String)
    case invalidSkill(slug: String, reason: String)
    case notInstalled(slug: String)

    var description: String {
        switch self {
        case .noTargetAgents:
            return "No target agents were given for the install."
        case .unknownAgent(let agent):
            return "No deploy root is configured for agent \(agent.displayName)."
        case .alreadyInstalled(let slug):
            return "Skill \"\(slug)\" is already in the library lockfile."
        case .deploymentCollision(let slug, let agent, let path):
            return "\(agent.displayName) already has an unmanaged \"\(slug)\" at \(path); refusing to overwrite."
        case .invalidSkill(let slug, let reason):
            return "Fetched skill \"\(slug)\" is invalid: \(reason)."
        case .notInstalled(let slug):
            return "Skill \"\(slug)\" is not in the library."
        }
    }

    var errorDescription: String? { description }
}

/// The canonical skill library (decisions D2 + D4): exactly one copy of each
/// managed skill under `directory`, deployed into each agent's skills folder
/// as a **symlink** to that copy, with a pretty-printed JSON provenance
/// lockfile alongside. Every filesystem mutation is journaled so installs are
/// reversible.
///
/// Write scope is strict: this type only ever writes inside `directory`, the
/// lockfile (`directory/../lockfile.json`), fresh temp dirs, and the given
/// `deployRoots`. It never touches real agent dirs in tests (roots are
/// injectable).
///
/// Journaling choices:
/// - `install` records one `pathAdd` for the library copy (attributed to the
///   first target agent) and one `pathAdd` per deployment symlink (attributed
///   to that symlink's agent), each recorded BEFORE the path is created so a
///   revert deletes it. Creating an agent's parent skills directory (e.g. an
///   absent `~/.codex/skills`) is NOT journaled — only the leaf symlink is.
/// - `remove` shelves the library copy via `recordDirectoryMove` (content
///   preserved, reversible) and then deletes the deployment symlinks
///   un-journaled. See `remove(slug:journal:)` for the reversibility limit.
@MainActor
@Observable
final class SkillLibrary: SkillInstalling {
    /// Provenance records for every managed skill, sorted by slug.
    private(set) var lockEntries: [LockEntry] = []

    private let directory: URL
    private let deployRoots: [AgentID: URL]

    /// `directory/../lockfile.json` — i.e. App Support/Loadout/lockfile.json
    /// when `directory` is the default App Support/Loadout/library.
    private var lockfileURL: URL {
        directory.deletingLastPathComponent().appendingPathComponent("lockfile.json", isDirectory: false)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        directory: URL = URL.applicationSupportDirectory
            .appendingPathComponent("Loadout", isDirectory: true)
            .appendingPathComponent("library", isDirectory: true),
        deployRoots: [AgentID: URL] = [
            .claudeCode: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true),
            .codex: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true),
        ]
    ) {
        self.directory = directory
        self.deployRoots = deployRoots
        load()
    }

    // MARK: - Install

    func install(
        _ skill: RegistrySkill,
        using adapter: any RegistryAdapter,
        to agents: [AgentID],
        journal: ChangeJournal
    ) async throws {
        let slug = skill.slug

        // 1. Refuse duplicates and collisions with anything we don't manage.
        guard !agents.isEmpty else { throw SkillLibraryError.noTargetAgents }
        guard !lockEntries.contains(where: { $0.slug == slug }) else {
            throw SkillLibraryError.alreadyInstalled(slug: slug)
        }
        for agent in agents {
            guard let root = deployRoots[agent] else {
                throw SkillLibraryError.unknownAgent(agent)
            }
            let target = root.appendingPathComponent(slug, isDirectory: true)
            if pathExists(target) {
                throw SkillLibraryError.deploymentCollision(
                    slug: slug, agent: agent, path: target.path
                )
            }
        }

        // 2. Fetch into a fresh temp dir and validate before touching anything.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadout-fetch-\(UUID().uuidString)", isDirectory: true)
        let resolvedVersion: String
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            resolvedVersion = try await adapter.fetch(skill, to: tempDir)
            let skillFile = tempDir.appendingPathComponent("SKILL.md", isDirectory: false)
            guard FileManager.default.fileExists(atPath: skillFile.path) else {
                throw SkillLibraryError.invalidSkill(slug: slug, reason: "no SKILL.md")
            }
            let metadata = Frontmatter.parse(contentsOf: skillFile)
            guard metadata.name != nil, metadata.description != nil else {
                throw SkillLibraryError.invalidSkill(
                    slug: slug, reason: "SKILL.md is missing name or description"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }

        // 3-6. Journaled mutations. On any failure, revert everything created
        // this call (best effort) so a failed install leaves no debris.
        let entriesSnapshot = lockEntries
        var createdChanges: [ConfigChange] = []
        let attributionAgent = agents[0]
        let libraryDir = directory.appendingPathComponent(slug, isDirectory: true)
        do {
            // 3. Move the fetched tree into the library (journaled first).
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let libraryChange = try journal.recordPathAdd(
                agent: attributionAgent,
                summary: "Add \(slug) to Loadout library (\(skill.registry)@\(resolvedVersion))",
                path: libraryDir
            )
            createdChanges.append(libraryChange)
            try FileManager.default.moveItem(at: tempDir, to: libraryDir)

            // 4. Content hash over the canonical tree.
            let contentHash = try TreeHash.hash(directory: libraryDir)

            // 5. Deploy a symlink into each target agent's skills dir.
            var deployments: [Deployment] = []
            for agent in agents {
                let root = deployRoots[agent]!
                // Create the parent skills dir if absent — NOT journaled.
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let linkURL = root.appendingPathComponent(slug, isDirectory: true)
                let linkChange = try journal.recordPathAdd(
                    agent: agent,
                    summary: "Install \(slug) for \(agent.displayName) (\(skill.registry)@\(resolvedVersion))",
                    path: linkURL
                )
                createdChanges.append(linkChange)
                try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: libraryDir)
                deployments.append(Deployment(agent: agent, path: linkURL.path, kind: .symlink))
            }

            // 6. Append the provenance record and persist the lockfile.
            let entry = LockEntry(
                slug: slug,
                registry: skill.registry,
                identifier: skill.identifier,
                version: resolvedVersion,
                contentHash: contentHash,
                fetchedAt: Date(),
                deployments: deployments
            )
            lockEntries.append(entry)
            lockEntries.sort { $0.slug < $1.slug }
            try persist()
        } catch {
            // 7. Best-effort revert of everything created this call.
            for change in createdChanges.reversed() {
                try? journal.revert(change)
            }
            lockEntries = entriesSnapshot
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    // MARK: - Remove

    /// Removes a managed skill: the library copy is shelved via
    /// `recordDirectoryMove` (content preserved), then the deployment symlinks
    /// are deleted un-journaled, and the lock entry is dropped.
    ///
    /// Reversibility limitation (M2, intentional): `ChangeJournal` has no kind
    /// that captures "a symlink was deleted", so the symlink removals are not
    /// journaled. Reverting the shelved-directory entry restores the canonical
    /// library copy with its full contents, but does NOT recreate the
    /// deployment symlinks — they must be re-established by re-installing (or a
    /// future link-repair action). Deleting the symlinks only after the copy is
    /// safely shelved keeps content loss impossible.
    func remove(slug: String, journal: ChangeJournal) async throws {
        guard let entry = lockEntries.first(where: { $0.slug == slug }) else {
            throw SkillLibraryError.notInstalled(slug: slug)
        }

        // Shelve the canonical copy first (reversible, content preserved).
        let libraryDir = directory.appendingPathComponent(slug, isDirectory: true)
        if pathExists(libraryDir) {
            _ = try journal.recordDirectoryMove(
                agent: entry.deployments.first?.agent ?? .claudeCode,
                summary: "Remove \(slug) from Loadout library",
                directory: libraryDir
            )
        }

        // Then delete the (now dangling) deployment symlinks — un-journaled.
        for deployment in entry.deployments {
            let url = URL(fileURLWithPath: deployment.path)
            if pathExists(url) {
                try FileManager.default.removeItem(at: url)
            }
        }

        lockEntries.removeAll { $0.slug == slug }
        try persist()
    }

    // MARK: - Persistence

    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(lockEntries)
        try data.write(to: lockfileURL, options: .atomic)
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: lockfileURL),
            let entries = try? Self.decoder.decode([LockEntry].self, from: data)
        else { return }
        lockEntries = entries.sorted { $0.slug < $1.slug }
    }

    // MARK: - Helpers

    /// True if anything (file, directory, or even a dangling symlink) exists at
    /// `url`. Uses `lstat` so symlinks are detected without being followed.
    private func pathExists(_ url: URL) -> Bool {
        var buffer = stat()
        return lstat(url.path, &buffer) == 0
    }
}
