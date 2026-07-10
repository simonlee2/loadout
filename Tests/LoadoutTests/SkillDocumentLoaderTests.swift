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

    @Test func loadsRealSkillMarkdownAsAttributed() async {
        let fixture = Fixture()
        let dir = fixture.writeSkill(
            slug: "demo",
            under: ["skills"],
            description: "Demo skill."
        )
        let document = await SkillDocumentLoader.load(directory: dir)
        // A readable SKILL.md renders as attributed (never .missing).
        #expect(document.statusDescription == "attributed")
    }

    @Test func missingFileReportsMissing() async {
        let fixture = Fixture()
        let dir = fixture.makeDir("skills", "no-skill-md")
        let document = await SkillDocumentLoader.load(directory: dir)
        #expect(document.statusDescription == "missing")
    }
}
