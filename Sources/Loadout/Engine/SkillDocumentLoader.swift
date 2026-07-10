import Foundation

/// The loaded body of a SKILL.md file, in the best form we could produce.
/// Read-only: loading never writes to disk.
enum SkillDocument: Sendable {
    case missing
    case attributed(AttributedString)
    case plain(String)

    /// Stable, log-friendly name of the case (used by the autodrive harness).
    var statusDescription: String {
        switch self {
        case .missing: "missing"
        case .attributed: "attributed"
        case .plain: "plain"
        }
    }
}

/// Reads and renders a skill directory's `SKILL.md` at display time. Shared by
/// `DetailView` and the debug autodrive harness so both exercise the same path.
enum SkillDocumentLoader {
    static func load(directory: URL) async -> SkillDocument {
        let url = directory.appendingPathComponent("SKILL.md")
        let content = await Task.detached(priority: .userInitiated) {
            try? String(contentsOf: url, encoding: .utf8)
        }.value

        guard let content else { return .missing }

        let body = stripFrontmatter(content)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: body, options: options) {
            return .attributed(attributed)
        }
        return .plain(body)
    }

    /// Drops a leading `---` YAML frontmatter block if present.
    static func stripFrontmatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return text
        }
        var index = 1
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                return lines[(index + 1)...]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            index += 1
        }
        return text
    }
}
