import Foundation

/// Pure, line-based diff used to build the update-review preview
/// (`FileChange.diff`). It produces unified-diff-style lines ("+ " / "- " /
/// "  ") with long unchanged runs collapsed to a few lines of context around
/// each change, and refuses binary or oversized inputs (returning an empty
/// preview so the review UI just shows the change kind).
///
/// The diff itself is a classic longest-common-subsequence walk over lines —
/// deterministic, allocation-light, and easy to reason about in tests. It is
/// intentionally free of any filesystem or model dependency.
enum FileDiff {
    /// Text files larger than this (on either side) get no inline preview.
    static let maxPreviewBytes = 64 * 1024
    /// A NUL byte anywhere in this leading window marks the blob as binary.
    static let binarySniffBytes = 8 * 1024
    /// Unchanged lines kept on each side of a change before collapsing to "…".
    static let defaultContext = 2

    /// True when `data` looks binary: a NUL byte in its first 8 KB.
    static func isBinary(_ data: Data) -> Bool {
        data.prefix(binarySniffBytes).contains(0)
    }

    /// Unified-diff-style preview between two blobs, or `[]` when either side
    /// is binary or larger than `maxPreviewBytes`. Identical text also yields
    /// `[]` (no change to show).
    static func preview(old: Data, new: Data, context: Int = defaultContext) -> [String] {
        guard old.count <= maxPreviewBytes, new.count <= maxPreviewBytes else { return [] }
        guard !isBinary(old), !isBinary(new) else { return [] }

        let oldLines = splitLines(String(decoding: old, as: UTF8.self))
        let newLines = splitLines(String(decoding: new, as: UTF8.self))
        return collapse(diff(oldLines, newLines), context: context)
    }

    // MARK: - Line splitting

    /// Splits text into lines on "\n", dropping the single trailing empty
    /// element a final newline produces (so "a\n" and "a" diff identically).
    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Diff

    enum LineOp: Equatable {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// Longest-common-subsequence diff of two line arrays into an ordered op
    /// list. Deletions from `a` are emitted before insertions from `b` at each
    /// divergence, matching unified-diff convention.
    static func diff(_ a: [String], _ b: [String]) -> [LineOp] {
        let n = a.count, m = b.count
        // lcs[i][j] = LCS length of a[i...] and b[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j]
                        ? lcs[i + 1][j + 1] + 1
                        : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var ops: [LineOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.equal(a[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(a[i])); i += 1
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }

    // MARK: - Collapse

    /// Renders ops to preview lines, keeping only `context` unchanged lines
    /// around each change and replacing every skipped run (leading, interior,
    /// or trailing) with a single "…" marker. Returns `[]` when there are no
    /// changes at all.
    private static func collapse(_ ops: [LineOp], context: Int) -> [String] {
        let changed = ops.map { op -> Bool in
            if case .equal = op { return false } else { return true }
        }
        guard changed.contains(true) else { return [] }

        var keep = Array(repeating: false, count: ops.count)
        for (index, isChanged) in changed.enumerated() where isChanged {
            let lo = max(0, index - context)
            let hi = min(ops.count - 1, index + context)
            for k in lo...hi { keep[k] = true }
        }

        var result: [String] = []
        var gap = false
        for (index, op) in ops.enumerated() {
            if keep[index] {
                if gap { result.append("…"); gap = false }
                result.append(render(op))
            } else {
                gap = true
            }
        }
        if gap { result.append("…") }
        return result
    }

    private static func render(_ op: LineOp) -> String {
        switch op {
        case .equal(let line): return "  " + line
        case .delete(let line): return "- " + line
        case .insert(let line): return "+ " + line
        }
    }
}
