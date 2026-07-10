import SwiftUI

/// Footer status line: skill count, relative scan time, and a warning affordance
/// that surfaces scan errors in a popover.
struct StatusBarView: View {
    let store: InventoryStore
    @State private var showingErrors = false

    private var summary: String {
        let count = store.rows.count
        let noun = count == 1 ? "skill" : "skills"
        if let lastScan = store.lastScan {
            let relative = lastScan.formatted(.relative(presentation: .named))
            return "\(count) \(noun) · scanned \(relative)"
        }
        return "\(count) \(noun)"
    }

    var body: some View {
        HStack(spacing: 8) {
            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(Ledger.quiet)

            Spacer()

            if !store.scanErrors.isEmpty {
                Button {
                    showingErrors.toggle()
                } label: {
                    Label("\(store.scanErrors.count)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .help("Scan errors")
                .popover(isPresented: $showingErrors, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan Errors")
                            .font(.headline)
                        ForEach(store.scanErrors, id: \.self) { error in
                            Label(error, systemImage: "xmark.octagon")
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Ledger.paper2)
    }
}
