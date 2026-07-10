import SwiftUI
import AppKit

/// "Paper Ledger" design tokens: a warm, editorial, typography-first surface for
/// the content and detail columns. The native sidebar keeps its system glass and
/// is deliberately untouched by anything here.
///
/// Every color is an appearance-dynamic `Color` (resolved through an `NSColor`
/// dynamic provider) so both Light and Dark render with an intentional warm
/// palette — Dark is a warm-charcoal companion to Light's warm paper, not a
/// naive inversion.
enum Ledger {

    // MARK: Palette

    /// The reading surface. Light: warm paper (#faf8f4). Dark: warm charcoal.
    static let paper = dynamic(light: 0xFAF8F4, dark: 0x1C1A17)
    /// A slightly deeper paper for chips / insets. Light #f4f1ea.
    static let paper2 = dynamic(light: 0xF4F1EA, dark: 0x24211D)
    /// Raised surface for a selected row / detail card. Light: pure white lift.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x2A2620)

    /// Primary ink for names and headings. Light #211d18, Dark warm off-white.
    static let ink = dynamic(light: 0x211D18, dark: 0xECE7DD)
    /// Softer ink for body copy and secondary labels. Light #4a443c.
    static let inkSoft = dynamic(light: 0x4A443C, dark: 0xC3BCAE)
    /// Quiet gray for one-line descriptions. Light #8f887c.
    static let quiet = dynamic(light: 0x8F887C, dark: 0x928B7E)
    /// Quieter still — metadata, counts, dashes. Light #a8a294.
    static let quieter = dynamic(light: 0xA8A294, dark: 0x6F695F)

    /// Hairline between rows / under headings. Light #e7e2d8.
    static let line = dynamic(light: 0xE7E2D8, dark: 0x36322B)
    /// The even softer per-row rule. Light #efeae0.
    static let lineSoft = dynamic(light: 0xEFEAE0, dark: 0x2B2823)

    /// Deep warm teal — "managed" status, selection stroke, accents. Brightened
    /// for Dark so it reads on charcoal.
    static let accent = dynamic(light: 0x0F6B6B, dark: 0x57B3AC)
    /// A hair darker teal for pressed / ink-on-teal contexts.
    static let accentInk = dynamic(light: 0x0D5A5A, dark: 0x6CC3BC)
    /// Sage green — "synced".
    static let sage = dynamic(light: 0x5B8A57, dark: 0x8BB583)
    /// Warm orange — "update" / "differs".
    static let orange = dynamic(light: 0xC26B23, dark: 0xE09250)

    // MARK: Spacing

    enum Space {
        /// Content measure — the readable column width, centered like the mockup.
        static let measure: CGFloat = 860
        /// Horizontal inset inside the measure.
        static let gutter: CGFloat = 32
        /// Top breathing room before the first section heading.
        static let top: CGFloat = 24
        /// Vertical padding inside a ledger row.
        static let rowV: CGFloat = 10
        /// Horizontal padding inside a ledger row.
        static let rowH: CGFloat = 10
        /// Gap between a section heading and its first row.
        static let afterHeading: CGFloat = 2
        /// Gap above a section heading (except the first).
        static let beforeHeading: CGFloat = 24
    }

    // MARK: Type styles

    /// Serif section / detail headings (`.fontDesign(.serif)`), used ONLY for
    /// headings — never body copy.
    static func serifHeading(_ size: CGFloat = 21) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    // MARK: Dynamic color plumbing

    /// Builds an appearance-dynamic `Color` from two hex values.
    static func dynamic(light: UInt, dark: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// 0xRRGGBB → opaque sRGB color.
    convenience init(hex: UInt) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Status word

extension RowStatus {
    /// The small-caps ledger word for this status, and its tint. `nil` means the
    /// row shows no status word (single-agent / uncomparable rows stay quiet).
    var ledgerWord: (text: String, tint: Color)? {
        switch self {
        case .update(let display): ("update \(display)", Ledger.orange)
        case .synced: ("synced", Ledger.sage)
        case .differs: ("differs", Ledger.orange)
        case .managed: ("managed", Ledger.accent)
        case .agentOnly, .unknown: nil
        }
    }
}

/// A quiet small-caps status word, color only when meaningful. Renders an empty
/// fixed-width slot for statuses with no word so trailing clusters stay aligned.
struct LedgerStatusLabel: View {
    let status: RowStatus
    var width: CGFloat = 96

    var body: some View {
        Group {
            if let word = status.ledgerWord {
                Text(word.text)
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .foregroundStyle(word.tint)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(width: width, alignment: .trailing)
    }
}

// MARK: - Agent monogram

extension AgentID {
    /// Two-letter monogram for the compact ledger presence cluster.
    var monogram: String {
        switch self {
        case .claudeCode: "CC"
        case .codex: "CX"
        }
    }
}
