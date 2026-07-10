import SwiftUI

/// Renders a parsed SKILL.md (`[DocBlock]`) on the Paper Ledger surface.
/// Typography only — the loader owns the parsing, this view owns the look:
/// quiet uppercase section headings, unwrapped body paragraphs, hanging-indent
/// bullets, and mono code on the deeper paper.
struct SkillDocView: View {
    let blocks: [DocBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: DocBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Ledger.inkSoft)
                .padding(.top, 16)

        case .paragraph(let text):
            paragraphText(text)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 13))
                            .foregroundStyle(Ledger.quieter)
                        paragraphText(item)
                    }
                }
            }
            .padding(.leading, 4)

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ledger.inkSoft)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Ledger.paper2, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Body copy: 13pt inkSoft with generous line spacing; inline-`code` runs
    /// restyled to small mono on the deeper paper.
    private func paragraphText(_ text: AttributedString) -> some View {
        Text(styledInline(text))
            .font(.system(size: 13))
            .lineSpacing(4.5)
            .foregroundStyle(Ledger.inkSoft)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Applies the ledger's inline-code treatment to `code` presentation runs.
    private func styledInline(_ text: AttributedString) -> AttributedString {
        var styled = text
        for run in styled.runs {
            guard let intent = run.inlinePresentationIntent,
                  intent.contains(.code) else { continue }
            styled[run.range].font = .system(size: 12, design: .monospaced)
            styled[run.range].backgroundColor = Ledger.paper2
        }
        return styled
    }
}
