import Foundation
import Testing
@testable import LoadoutKit

@Suite struct SkillDocumentLoaderTests {
    @Test func stripsLeadingFrontmatterBlock() {
        let text = """
        ---
        name: my-skill
        description: A thing.
        ---

        # Body

        Prose.
        """
        let body = SkillDocumentLoader.stripFrontmatter(text)
        #expect(!body.contains("name: my-skill"))
        #expect(body.hasPrefix("# Body"))
        #expect(body.contains("Prose."))
    }

    @Test func leavesBodyWithoutFrontmatterUnchanged() {
        let text = "# Just a heading\n\nNo frontmatter here.\n"
        #expect(SkillDocumentLoader.stripFrontmatter(text) == text)
    }

    @Test func loadsRealSkillMarkdownAsBlocks() async {
        let fixture = Fixture()
        let dir = fixture.writeSkill(
            slug: "demo",
            under: ["skills"],
            description: "Demo skill."
        )
        let document = await SkillDocumentLoader.load(directory: dir)
        // A readable SKILL.md renders as parsed blocks (never .missing).
        #expect(document.statusDescription == "blocks")
    }

    @Test func missingFileReportsMissing() async {
        let fixture = Fixture()
        let dir = fixture.makeDir("skills", "no-skill-md")
        let document = await SkillDocumentLoader.load(directory: dir)
        #expect(document.statusDescription == "missing")
    }

    // MARK: Block parsing

    @Test func dropsLeadingH1() {
        let blocks = SkillDocumentLoader.parseBlocks("# My Skill\n\nBody prose.")
        #expect(blocks.count == 1)
        #expect(blocks.first == .paragraph(AttributedString("Body prose.")))
    }

    @Test func keepsH2AndH3AsHeadings() {
        let blocks = SkillDocumentLoader.parseBlocks("""
        # Title

        ## Usage

        Prose.

        ### Notes
        """)
        #expect(blocks == [
            .heading("Usage"),
            .paragraph(AttributedString("Prose.")),
            .heading("Notes"),
        ])
    }

    @Test func unwrapsHardWrappedParagraphLines() {
        let blocks = SkillDocumentLoader.parseBlocks("""
        This sentence was hard-wrapped
        in the source file.

        Second paragraph.
        """)
        #expect(blocks == [
            .paragraph(AttributedString("This sentence was hard-wrapped in the source file.")),
            .paragraph(AttributedString("Second paragraph.")),
        ])
    }

    @Test func collectsFencedCodeVerbatim() {
        let blocks = SkillDocumentLoader.parseBlocks("""
        Before.

        ```swift
        let a = 1
        let b = 2
        ```

        After.
        """)
        #expect(blocks == [
            .paragraph(AttributedString("Before.")),
            .code("let a = 1\nlet b = 2"),
            .paragraph(AttributedString("After.")),
        ])
    }

    @Test func groupsBulletsWithContinuationLines() {
        let blocks = SkillDocumentLoader.parseBlocks("""
        - first item
          wraps onto a second line
        - second item
        1. numbered item
        """)
        #expect(blocks == [
            .bullets([
                AttributedString("first item wraps onto a second line"),
                AttributedString("second item"),
                AttributedString("numbered item"),
            ]),
        ])
    }

    @Test func nonLeadingH1StaysAHeading() {
        let blocks = SkillDocumentLoader.parseBlocks("Intro.\n\n# Later Heading")
        #expect(blocks == [
            .paragraph(AttributedString("Intro.")),
            .heading("Later Heading"),
        ])
    }
}
