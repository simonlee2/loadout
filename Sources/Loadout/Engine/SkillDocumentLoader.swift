import Foundation

/// One rendered block of a SKILL.md body. The loader parses the raw markdown
/// into this small vocabulary; the views decide fonts and colors. Inline
/// markdown (emphasis, `code`) inside paragraphs and bullets is pre-parsed
/// into `AttributedString` presentation intents.
enum DocBlock: Sendable, Equatable {
    /// A section heading (source `##`/`###`…; a leading `#` H1 is dropped).
    case heading(String)
    /// A prose paragraph, hard-wrapped source lines already joined.
    case paragraph(AttributedString)
    /// A bullet or numbered list, one entry per item.
    case bullets([AttributedString])
    /// A fenced code block, verbatim (fence lines removed).
    case code(String)
}

/// The loaded body of a SKILL.md file, in the best form we could produce.
/// Read-only: loading never writes to disk.
enum SkillDocument: Sendable {
    case missing
    case blocks([DocBlock])
    case plain(String)

    /// Stable, log-friendly name of the case (used by the autodrive harness).
    var statusDescription: String {
        switch self {
        case .missing: "missing"
        case .blocks: "blocks"
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
        return .blocks(parseBlocks(body))
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

    // MARK: Block parsing

    /// Line-based markdown block pass. Rules:
    /// - a leading H1 is dropped (the detail header already names the skill);
    ///   any other `#`-heading becomes `.heading` with its marker stripped
    /// - consecutive non-blank prose lines are joined into one `.paragraph`
    ///   (unwrapping hard-wrapped source), inline markdown parsed
    /// - `-`/`*`/`+`/`1.` items group into `.bullets`; indented continuation
    ///   lines join their item
    /// - ``` fences collect verbatim into `.code`
    static func parseBlocks(_ body: String) -> [DocBlock] {
        var blocks: [DocBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var seenContent = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: " "))))
            paragraph = []
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets.map(inline)))
            bullets = []
        }

        for rawLine in body.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inCode {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                    seenContent = true
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushBullets()
                inCode = true
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushBullets()
                continue
            }

            if let heading = headingText(trimmed) {
                flushParagraph()
                flushBullets()
                // Drop a leading H1: the serif title above already names the
                // skill. Later H1s (rare) render as ordinary headings.
                if !(heading.level == 1 && !seenContent) {
                    blocks.append(.heading(heading.text))
                }
                seenContent = true
                continue
            }

            if let item = bulletText(trimmed) {
                flushParagraph()
                bullets.append(item)
                seenContent = true
                continue
            }

            if !bullets.isEmpty {
                // Indented / wrapped continuation of the previous list item.
                bullets[bullets.count - 1] += " " + trimmed
                seenContent = true
                continue
            }

            paragraph.append(trimmed)
            seenContent = true
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        flushBullets()
        return blocks
    }

    /// `## Title` → (2, "Title"); nil for non-heading lines.
    private static func headingText(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let marker = line.prefix { $0 == "#" }
        let rest = line.dropFirst(marker.count)
        guard rest.first == " " || rest.isEmpty else { return nil }
        return (marker.count, rest.trimmingCharacters(in: .whitespaces))
    }

    /// `- item` / `* item` / `3. item` → "item"; nil otherwise.
    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") {
                return rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Inline markdown (emphasis, `code`, links) for one paragraph or bullet.
    /// Falls back to the literal text when parsing fails.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}
