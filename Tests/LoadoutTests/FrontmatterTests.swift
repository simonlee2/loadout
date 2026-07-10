import Foundation
import Testing
@testable import Loadout

@Suite struct FrontmatterTests {
    @Test func parsesNameAndDescription() {
        let text = """
        ---
        name: my-skill
        description: Does a thing. Use when appropriate.
        ---

        # Body
        """
        let meta = Frontmatter.parse(text)
        #expect(meta.name == "my-skill")
        #expect(meta.description == "Does a thing. Use when appropriate.")
        #expect(meta.extra.isEmpty)
    }

    @Test func missingDescriptionLeavesNil() {
        let text = """
        ---
        name: only-name
        ---
        """
        let meta = Frontmatter.parse(text)
        #expect(meta.name == "only-name")
        #expect(meta.description == nil)
    }

    @Test func noFrontmatterReturnsEmpty() {
        let text = "# Just a heading\n\nSome prose without frontmatter.\n"
        let meta = Frontmatter.parse(text)
        #expect(meta.name == nil)
        #expect(meta.description == nil)
        #expect(meta.extra.isEmpty)
    }

    @Test func extraKeysLandInExtra() {
        let text = """
        ---
        name: rich
        description: A skill.
        license: MIT
        version: 2
        allowed-tools: Read, Write
        ---
        """
        let meta = Frontmatter.parse(text)
        #expect(meta.name == "rich")
        #expect(meta.extra["license"] == "MIT")
        // Non-string scalar is stringified.
        #expect(meta.extra["version"] == "2")
        #expect(meta.extra["allowed-tools"] == "Read, Write")
    }

    @Test func stringifiesListValues() {
        let text = """
        ---
        name: listy
        tags:
          - alpha
          - beta
        ---
        """
        let meta = Frontmatter.parse(text)
        #expect(meta.extra["tags"] == "alpha, beta")
    }

    @Test func handlesQuotedMultilineDescription() {
        let text = """
        ---
        name: quoted
        description: "First line
          continues here."
        ---
        """
        let meta = Frontmatter.parse(text)
        #expect(meta.name == "quoted")
        #expect(meta.description?.contains("First line") == true)
        #expect(meta.description?.contains("continues here.") == true)
    }
}
