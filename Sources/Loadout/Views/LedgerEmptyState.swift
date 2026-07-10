import SwiftUI

/// The shared quiet empty state for the ledger's columns: an optional small
/// symbol, one serif line, and an optional detail line, centered on paper.
/// Deliberately hushed — an empty column is a resting state, not an alert.
struct LedgerEmptyState<Actions: View>: View {
    var systemImage: String?
    let title: String
    var detail: String?
    @ViewBuilder var actions: () -> Actions

    init(
        systemImage: String? = nil,
        title: String,
        detail: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Ledger.quieter)
                    .padding(.bottom, 2)
            }
            Text(title)
                .font(.system(size: 15, weight: .medium, design: .serif))
                .foregroundStyle(Ledger.quiet)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.quieter)
                    .multilineTextAlignment(.center)
            }
            actions()
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ledger.paper)
    }
}
