import Foundation
import Yams

/// Parses the leading YAML frontmatter block of a SKILL.md file.
enum Frontmatter {
    /// Parses `text` (the full contents of a SKILL.md) into `SkillMetadata`.
    ///
    /// Frontmatter is the block between a leading `---` line and the next
    /// `---` line. Files without a frontmatter block yield empty metadata.
    /// `name` and `description` populate the typed fields; every other
    /// mapping key is stringified into `extra`.
    static func parse(_ text: String) -> SkillMetadata {
        guard let yaml = extractBlock(from: text) else {
            return SkillMetadata()
        }

        guard
            let parsed = try? Yams.load(yaml: yaml),
            let mapping = parsed as? [String: Any]
        else {
            return SkillMetadata()
        }

        var metadata = SkillMetadata()
        for (key, value) in mapping {
            let stringValue = stringify(value)
            switch key {
            case "name":
                metadata.name = stringValue
            case "description":
                metadata.description = stringValue
            default:
                metadata.extra[key] = stringValue
            }
        }
        return metadata
    }

    /// Parses the frontmatter of the SKILL.md at `url`, tolerating an
    /// unreadable file by returning empty metadata.
    static func parse(contentsOf url: URL) -> SkillMetadata {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return SkillMetadata()
        }
        return parse(text)
    }

    /// Returns the raw YAML between the opening and closing `---` fences, or
    /// nil when the text does not begin with a frontmatter fence.
    private static func extractBlock(from text: String) -> String? {
        // Normalize line endings so CRLF files parse identically.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        // The opening fence must be the first non-empty line.
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        guard index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        var body: [String] = []
        var cursor = index + 1
        while cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces) == "---" {
                return body.joined(separator: "\n")
            }
            body.append(lines[cursor])
            cursor += 1
        }
        // No closing fence: treat as if there were no frontmatter.
        return nil
    }

    /// Converts an arbitrary YAML scalar/collection into a stable string.
    private static func stringify(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let array as [Any]:
            return array.map(stringify).joined(separator: ", ")
        case let dict as [String: Any]:
            return dict
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \(stringify($0.value))" }
                .joined(separator: ", ")
        case is NSNull:
            return ""
        default:
            return String(describing: value)
        }
    }
}
