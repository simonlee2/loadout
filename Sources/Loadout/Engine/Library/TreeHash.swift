import Foundation
import CryptoKit

/// Deterministic content hash of a skill's file tree — the provenance
/// fingerprint stored in `LockEntry.contentHash` (decision D4).
///
/// The hash is SHA-256 over the tree in a stable order: every file's
/// relative path is collected, the list is sorted, and for each entry the
/// relative-path bytes followed by the file's bytes are fed into one hasher.
/// Symlinks encountered inside the tree contribute their link-target string
/// (they are never followed), so the hash is independent of where the tree
/// physically lives on disk.
enum TreeHash {
    /// Returns the lowercase hex SHA-256 of the tree rooted at `directory`.
    static func hash(directory: URL) throws -> String {
        var entries: [(relativePath: String, url: URL)] = []
        try collect(directory: directory, base: directory, into: &entries)
        entries.sort { $0.relativePath < $1.relativePath }

        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: Data(entry.relativePath.utf8))
            if isSymbolicLink(entry.url) {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)
                hasher.update(data: Data(target.utf8))
            } else {
                hasher.update(data: try Data(contentsOf: entry.url))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Recursively gathers files and symlinks (never descending into a
    /// symlinked directory) as `(relativePath, url)` pairs.
    private static func collect(
        directory: URL,
        base: URL,
        into entries: inout [(relativePath: String, url: URL)]
    ) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for url in contents {
            if isSymbolicLink(url) {
                // Hash the link itself (its target string); never follow it.
                entries.append((relativePath(of: url, base: base), url))
                continue
            }
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                try collect(directory: url, base: base, into: &entries)
            } else {
                entries.append((relativePath(of: url, base: base), url))
            }
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Path of `url` relative to `base`, stripping the shared prefix so the
    /// result is stable regardless of the tree's absolute location.
    private static func relativePath(of url: URL, base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        let prefix = basePath + "/"
        if fullPath.hasPrefix(prefix) {
            return String(fullPath.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }
}
