import Foundation
import Testing
@testable import LoadoutKit

@Suite struct FileDiffTests {

    // MARK: - Modified lines

    @Test func modifiedLineProducesReplacementPreview() {
        let old = Data("line1\nline2\nline3\n".utf8)
        let new = Data("line1\nCHANGED\nline3\n".utf8)

        // Whole file is within the context window, so every line is shown.
        #expect(FileDiff.preview(old: old, new: new) == [
            "  line1",
            "- line2",
            "+ CHANGED",
            "  line3",
        ])
    }

    @Test func addedAndRemovedLinesGetPlusMinusPrefixes() {
        // Pure insertion (old empty) -> all "+ " lines.
        #expect(FileDiff.preview(old: Data(), new: Data("a\nb\n".utf8)) == ["+ a", "+ b"])
        // Pure deletion (new empty) -> all "- " lines.
        #expect(FileDiff.preview(old: Data("a\nb\n".utf8), new: Data()) == ["- a", "- b"])
    }

    // MARK: - Context collapse

    @Test func distantUnchangedRunsCollapseToEllipsis() {
        let old = Data("a\nb\nc\nd\ne\nf\ng\n".utf8)
        let new = Data("a\nb\nc\nD\ne\nf\ng\n".utf8)

        // Change is at line "d". With 2 lines of context the leading "a" and
        // trailing "g" are omitted, each replaced by a single "…" marker.
        #expect(FileDiff.preview(old: old, new: new) == [
            "…",
            "  b",
            "  c",
            "- d",
            "+ D",
            "  e",
            "  f",
            "…",
        ])
    }

    @Test func separateChangesEachKeepContext() {
        let old = Data("a\nb\nc\nd\ne\nf\ng\nh\ni\n".utf8)
        // Change first and last lines; the middle unchanged run collapses.
        let new = Data("A\nb\nc\nd\ne\nf\ng\nh\nI\n".utf8)

        #expect(FileDiff.preview(old: old, new: new) == [
            "- a",
            "+ A",
            "  b",
            "  c",
            "…",
            "  g",
            "  h",
            "- i",
            "+ I",
        ])
    }

    // MARK: - Identical

    @Test func identicalFilesProduceNoPreview() {
        let data = Data("same\ncontent\n".utf8)
        #expect(FileDiff.preview(old: data, new: data).isEmpty)
    }

    @Test func trailingNewlineIsNormalized() {
        // "a" and "a\n" split to the same line array -> no change.
        #expect(FileDiff.preview(old: Data("a".utf8), new: Data("a\n".utf8)).isEmpty)
    }

    // MARK: - Binary / oversized

    @Test func binaryContentIsDetected() {
        let binary = Data([0x41, 0x42, 0x00, 0x43])
        #expect(FileDiff.isBinary(binary))
        #expect(!FileDiff.isBinary(Data("plain text".utf8)))
    }

    @Test func binaryInputYieldsEmptyPreview() {
        let binary = Data([0x00, 0x01, 0x02])
        let text = Data("hello\n".utf8)
        #expect(FileDiff.preview(old: binary, new: text).isEmpty)
        #expect(FileDiff.preview(old: text, new: binary).isEmpty)
    }

    @Test func oversizedInputYieldsEmptyPreview() {
        let big = Data(repeating: UInt8(ascii: "x"), count: FileDiff.maxPreviewBytes + 1)
        let small = Data("x\n".utf8)
        #expect(FileDiff.preview(old: small, new: big).isEmpty)
    }
}
