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
    case adoptUnsupportedOrigin(slug: String, origin: String)
    case adoptSourceMissing(slug: String, path: String)
    case adoptSourceIsSymlink(slug: String, path: String)

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
        case .adoptUnsupportedOrigin(let slug, let origin):
            return "Skill \"\(slug)\" is a \(origin) skill; only user-scope skills can be adopted."
        case .adoptSourceMissing(let slug, let path):
            return "Skill \"\(slug)\" has no directory at \(path); nothing to adopt."
        case .adoptSourceIsSymlink(let slug, let path):
            return "Skill \"\(slug)\" at \(path) is already a symlink; it looks managed already."
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
/// - `adopt` journals a `pathAdd` ONLY for each additional sync symlink; the
///   library move and the origin-replacement symlink are deliberately not
///   journaled so no revert can ever delete the only copy of the user's
///   content. See `adopt(_:syncTo:journal:)` for the full design.
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

    // MARK: - Adopt

    /// Adopts an existing UNMANAGED user skill into the library (D1's
    /// adopt-later, D2's sync): `installation.directory` is MOVED to
    /// `<library>/<slug>`, a symlink to that copy replaces it at the original
    /// location (so the origin agent sees identical content at the same
    /// path), and each `syncTo` agent's skills root gets its own symlink.
    /// The lock entry records registry "local", the original path as the
    /// identifier, and version `local-<first 12 contentHash chars>`.
    ///
    /// Reversibility design — the no-content-loss invariant: no sequence of
    /// journal reverts may ever delete the only copy of the user's skill
    /// content. A `pathAdd` for the library copy would delete that content on
    /// revert, and reverting the origin-replacement symlink's `pathAdd` after
    /// it would leave nothing anywhere. The library move and the replacement
    /// symlink are therefore NOT journaled; only the *additional* sync
    /// symlinks are (`pathAdd` each — pure links whose deletion never touches
    /// content). The reversal path for the adopt itself is
    /// `remove(slug:journal:)`, which shelves the library copy via
    /// `recordDirectoryMove` (content preserved and restorable).
    ///
    /// A mid-adopt failure (e.g. a collision with an unmanaged same-slug
    /// directory in a `syncTo` agent) restores the original state best-effort
    /// — created sync symlinks are reverted, the replacement symlink is
    /// removed, and the directory is moved back — before rethrowing.
    func adopt(
        _ installation: SkillInstallation,
        syncTo agents: [AgentID],
        journal: ChangeJournal
    ) async throws {
        let slug = installation.slug
        let originalDir = installation.directory
        let fileManager = FileManager.default

        // 1. Preconditions — all checked before anything is touched.
        guard installation.origin == .user else {
            throw SkillLibraryError.adoptUnsupportedOrigin(
                slug: slug, origin: installation.origin.label
            )
        }
        guard !lockEntries.contains(where: { $0.slug == slug }) else {
            throw SkillLibraryError.alreadyInstalled(slug: slug)
        }
        var info = stat()
        guard lstat(originalDir.path, &info) == 0 else {
            throw SkillLibraryError.adoptSourceMissing(slug: slug, path: originalDir.path)
        }
        // lstat, so a symlink (e.g. already pointing into the library) is
        // seen as such and never followed.
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw SkillLibraryError.adoptSourceIsSymlink(slug: slug, path: originalDir.path)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SkillLibraryError.invalidSkill(slug: slug, reason: "source path is not a directory")
        }
        let libraryDir = directory.appendingPathComponent(slug, isDirectory: true)
        guard !pathExists(libraryDir) else {
            throw SkillLibraryError.alreadyInstalled(slug: slug)
        }
        // The origin agent's root got the replacement symlink, so it is
        // skipped; duplicates are collapsed. Sync collisions are checked
        // per-agent inside the mutation loop below (they surface after the
        // move and exercise the restore path).
        var seen = Set<AgentID>()
        let syncAgents = agents.filter { $0 != installation.agent && seen.insert($0).inserted }
        for agent in syncAgents where deployRoots[agent] == nil {
            throw SkillLibraryError.unknownAgent(agent)
        }

        // 2. Mutations. On any failure, restore the original state
        // best-effort and rethrow.
        let entriesSnapshot = lockEntries
        var createdChanges: [ConfigChange] = []
        var movedToLibrary = false
        var originLinkCreated = false
        do {
            // Move the user's directory into the library — un-journaled by
            // design (see the doc comment); `remove(slug:)` is the reversal.
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: originalDir, to: libraryDir)
            movedToLibrary = true

            // Replace the original location with a symlink to the copy —
            // also un-journaled (reverting it would strand the content).
            try fileManager.createSymbolicLink(at: originalDir, withDestinationURL: libraryDir)
            originLinkCreated = true

            let contentHash = try TreeHash.hash(directory: libraryDir)

            var deployments = [
                Deployment(agent: installation.agent, path: originalDir.path, kind: .symlink)
            ]
            for agent in syncAgents {
                let root = deployRoots[agent]!
                // Create the parent skills dir if absent — NOT journaled.
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                let linkURL = root.appendingPathComponent(slug, isDirectory: true)
                if pathExists(linkURL) {
                    throw SkillLibraryError.deploymentCollision(
                        slug: slug, agent: agent, path: linkURL.path
                    )
                }
                let change = try journal.recordPathAdd(
                    agent: agent,
                    summary: "Sync adopted skill \(slug) to \(agent.displayName)",
                    path: linkURL
                )
                createdChanges.append(change)
                try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: libraryDir)
                deployments.append(Deployment(agent: agent, path: linkURL.path, kind: .symlink))
            }

            let entry = LockEntry(
                slug: slug,
                registry: "local",
                identifier: originalDir.path,
                version: "local-\(contentHash.prefix(12))",
                contentHash: contentHash,
                fetchedAt: Date(),
                deployments: deployments
            )
            lockEntries.append(entry)
            lockEntries.sort { $0.slug < $1.slug }
            try persist()
        } catch {
            // Best-effort restore: sync symlinks first (journal reverts),
            // then the replacement symlink (frees the original path), then
            // move the content back where it came from.
            for change in createdChanges.reversed() {
                try? journal.revert(change)
            }
            if originLinkCreated {
                try? fileManager.removeItem(at: originalDir)
            }
            if movedToLibrary {
                try? fileManager.moveItem(at: libraryDir, to: originalDir)
            }
            lockEntries = entriesSnapshot
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

    // MARK: - Update

    /// Downloads the upstream version of a managed skill into a fresh staging
    /// temp dir and computes the per-file changes vs. the current library copy.
    /// Mutates nothing (no library writes, no lockfile write, no journal
    /// entries); the caller either `applyUpdate`s the returned staging tree or
    /// `discardUpdate`s it.
    func stageUpdate(
        slug: String,
        using adapter: any RegistryAdapter
    ) async throws -> StagedUpdate {
        guard let entry = lockEntries.first(where: { $0.slug == slug }) else {
            throw SkillLibraryError.notInstalled(slug: slug)
        }

        // Reconstruct just enough of a RegistrySkill for `fetch`: the adapter
        // derives the repo from `identifier` and the skill dir from `slug`
        // (see SkillsShAdapter.repoSource / fetch). Other fields are unused
        // by fetch and left nil.
        let skill = RegistrySkill(
            registry: entry.registry,
            identifier: entry.identifier,
            slug: entry.slug,
            name: entry.slug,
            summary: nil,
            version: nil,
            installCount: nil,
            sourceURL: nil,
            audit: nil
        )

        // Fetch into a fresh staging dir and validate before diffing.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadout-update-\(UUID().uuidString)", isDirectory: true)
        let newVersion: String
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            newVersion = try await adapter.fetch(skill, to: stagingDir)
            let skillFile = stagingDir.appendingPathComponent("SKILL.md", isDirectory: false)
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
            try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }

        // Diff the staged tree against the current library copy.
        let libraryDir = directory.appendingPathComponent(slug, isDirectory: true)
        let changes: [FileChange]
        do {
            changes = try Self.computeChanges(old: libraryDir, new: stagingDir)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }

        return StagedUpdate(
            slug: slug,
            newVersion: newVersion,
            stagingDirectory: stagingDir,
            changes: changes
        )
    }

    /// Applies a staged update: the current library copy is shelved (reversible)
    /// and the staged tree is moved into its place, then the lock entry's
    /// version/hash/fetchedAt are refreshed. Deployment symlinks point at the
    /// (unchanged) library path, so they keep resolving to the new content
    /// automatically.
    ///
    /// Undo design — the journal-ordering that makes a straight revert work:
    /// `ChangeJournal.revert` of a `directoryMove` does `moveItem(shelf → path)`,
    /// which THROWS if `path` is occupied. After an applied update the new copy
    /// sits at that path, so shelving the old copy alone would be
    /// un-revertible. We therefore record TWO entries, ordered so a
    /// newest-first revert unwinds cleanly:
    ///   1. `directoryMove` of the OLD copy (appended first / older) — its
    ///      revert restores the old copy, but only once the path is free.
    ///   2. `pathAdd` for the NEW copy at the same path (appended last / newest)
    ///      — its revert deletes the new copy, freeing the path.
    /// Reverting newest-first (pathAdd, then directoryMove) thus deletes the new
    /// copy and restores the old one, byte-for-byte. Same-agent attribution and
    /// the exact sequence are covered by the undo test.
    func applyUpdate(_ staged: StagedUpdate, journal: ChangeJournal) async throws {
        let slug = staged.slug
        guard let index = lockEntries.firstIndex(where: { $0.slug == slug }) else {
            throw SkillLibraryError.notInstalled(slug: slug)
        }
        guard pathExists(staged.stagingDirectory) else {
            throw SkillLibraryError.invalidSkill(
                slug: slug, reason: "staged update directory \(staged.stagingDirectory.path) is missing"
            )
        }

        let entry = lockEntries[index]
        let attributionAgent = entry.deployments.first?.agent ?? .claudeCode
        let libraryDir = directory.appendingPathComponent(slug, isDirectory: true)

        let entriesSnapshot = lockEntries
        var createdChanges: [ConfigChange] = []
        do {
            // 1. Shelve the current copy first (older journal entry). This IS
            //    the move; the old copy now lives on the shelf.
            if pathExists(libraryDir) {
                let moveChange = try journal.recordDirectoryMove(
                    agent: attributionAgent,
                    summary: "Update \(slug) to \(staged.newVersion) (previous copy shelved)",
                    directory: libraryDir
                )
                createdChanges.append(moveChange)
            }

            // 2. Record a pathAdd for the new copy BEFORE moving it in (newest
            //    journal entry) so a newest-first revert deletes it, freeing
            //    the path for the directoryMove revert.
            let addChange = try journal.recordPathAdd(
                agent: attributionAgent,
                summary: "Install updated \(slug) copy (\(staged.newVersion))",
                path: libraryDir
            )
            createdChanges.append(addChange)

            // 3. Move the staged tree into the canonical location.
            try FileManager.default.moveItem(at: staged.stagingDirectory, to: libraryDir)

            // 4. Recompute the hash and refresh the lock entry.
            let contentHash = try TreeHash.hash(directory: libraryDir)
            lockEntries[index] = LockEntry(
                slug: entry.slug,
                registry: entry.registry,
                identifier: entry.identifier,
                version: staged.newVersion,
                contentHash: contentHash,
                fetchedAt: Date(),
                deployments: entry.deployments
            )
            try persist()
        } catch {
            // Best-effort rollback: newest-first revert deletes any new copy,
            // then restores the shelved old copy.
            for change in createdChanges.reversed() {
                try? journal.revert(change)
            }
            lockEntries = entriesSnapshot
            throw error
        }
    }

    /// Per-file changes between the current library copy (`old`) and a staged
    /// tree (`new`): walks both as sorted relative paths, classifies each as
    /// added/removed/modified (byte comparison), and attaches a `FileDiff`
    /// preview for text files.
    private static func computeChanges(old: URL, new: URL) throws -> [FileChange] {
        let oldFiles = try relativeFiles(under: old)
        let newFiles = try relativeFiles(under: new)
        let allPaths = Set(oldFiles.keys).union(newFiles.keys).sorted()

        var changes: [FileChange] = []
        for path in allPaths {
            switch (oldFiles[path], newFiles[path]) {
            case let (nil, newURL?):
                let data = (try? Data(contentsOf: newURL)) ?? Data()
                changes.append(FileChange(
                    relativePath: path, kind: .added,
                    diff: FileDiff.preview(old: Data(), new: data)
                ))
            case let (oldURL?, nil):
                let data = (try? Data(contentsOf: oldURL)) ?? Data()
                changes.append(FileChange(
                    relativePath: path, kind: .removed,
                    diff: FileDiff.preview(old: data, new: Data())
                ))
            case let (oldURL?, newURL?):
                let oldData = (try? Data(contentsOf: oldURL)) ?? Data()
                let newData = (try? Data(contentsOf: newURL)) ?? Data()
                if oldData != newData {
                    changes.append(FileChange(
                        relativePath: path, kind: .modified,
                        diff: FileDiff.preview(old: oldData, new: newData)
                    ))
                }
            case (nil, nil):
                break
            }
        }
        return changes
    }

    /// Maps every regular file under `root` to its root-relative path. Returns
    /// an empty map when `root` does not exist. Symlinks are ignored (fetched
    /// skill trees contain only regular files).
    private static func relativeFiles(under root: URL) throws -> [String: URL] {
        let fileManager = FileManager.default
        var result: [String: URL] = [:]
        guard fileManager.fileExists(atPath: root.path) else { return result }
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return result }

        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let full = url.standardizedFileURL.path
            if full.hasPrefix(prefix) {
                result[String(full.dropFirst(prefix.count))] = url
            }
        }
        return result
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
