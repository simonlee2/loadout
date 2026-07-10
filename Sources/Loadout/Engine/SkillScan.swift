import Foundation

/// Shared helper for discovering `<dir>/*/SKILL.md` skill directories.
enum SkillScan {
    /// A skill directory found on disk, before origin/enablement is decided.
    struct Found {
        let slug: String
        let directory: URL
        let metadata: SkillMetadata
        let lastModified: Date?
    }

    /// Returns every immediate subdirectory of `skillsDir` that contains a
    /// SKILL.md. A missing `skillsDir` yields an empty list (never throws).
    ///
    /// - Parameter includeHidden: when false, subdirectories whose name begins
    ///   with `.` are skipped.
    static func installations(in skillsDir: URL, includeHidden: Bool = false) -> [Found] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [Found] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard isDirectory else { continue }
            if !includeHidden, entry.lastPathComponent.hasPrefix(".") { continue }

            let skillFile = entry.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: skillFile.path) else { continue }

            let metadata = Frontmatter.parse(contentsOf: skillFile)
            let modified = (try? skillFile.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            result.append(Found(
                slug: entry.lastPathComponent,
                directory: entry,
                metadata: metadata,
                lastModified: modified
            ))
        }
        return result.sorted { $0.slug < $1.slug }
    }
}
