import Foundation

/// Builds and tears down a unique temporary fixture directory tree.
final class Fixture {
    let root: URL

    init(_ name: String = "loadout-\(UUID().uuidString)") {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates a directory at the given path components under `root`.
    @discardableResult
    func makeDir(_ components: String...) -> URL {
        let url = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `contents` to a file at the given path components under `root`,
    /// creating intermediate directories.
    @discardableResult
    func writeFile(_ contents: String, at components: String...) -> URL {
        let url = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes a minimal SKILL.md into a skill directory named `slug` under the
    /// given parent path components.
    @discardableResult
    func writeSkill(slug: String, under components: [String], name: String? = nil,
                    description: String? = nil) -> URL {
        let displayName = name ?? slug
        var front = "---\nname: \(displayName)\n"
        if let description { front += "description: \(description)\n" }
        front += "---\n\n# \(displayName)\n"
        let path = components + [slug, "SKILL.md"]
        let url = path.reduce(root) { $0.appendingPathComponent($1) }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? front.write(to: url, atomically: true, encoding: .utf8)
        return url.deletingLastPathComponent()
    }
}
