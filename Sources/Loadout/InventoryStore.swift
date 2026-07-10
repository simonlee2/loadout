import Foundation
import Observation
import os

/// Observable source of truth for the inventory UI. Owns the scanners,
/// runs rescans off the main thread, and groups results into matrix rows.
@MainActor
@Observable
final class InventoryStore {
    private(set) var installations: [SkillInstallation] = []
    private(set) var scanErrors: [String] = []
    private(set) var lastScan: Date?
    private(set) var isScanning = false

    private let scanners: [any AgentScanner]

    init(scanners: [any AgentScanner]) {
        self.scanners = scanners
    }

    /// Agents that produced at least one installation (columns of the matrix).
    var activeAgents: [AgentID] {
        AgentID.allCases.filter { agent in
            installations.contains { $0.agent == agent }
        }
    }

    /// Matrix rows: installations grouped by slug, sorted by name.
    var rows: [SkillRow] {
        let grouped = Dictionary(grouping: installations, by: \.slug)
        return grouped
            .map { SkillRow(slug: $0.key, installations: $0.value.sorted { $0.agent.rawValue < $1.agent.rawValue }) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scanners = self.scanners
        let result: (installs: [SkillInstallation], errors: [String]) = await Task.detached(priority: .userInitiated) {
            var installs: [SkillInstallation] = []
            var errors: [String] = []
            for scanner in scanners {
                do {
                    installs.append(contentsOf: try scanner.scan())
                } catch {
                    errors.append("\(scanner.agent.displayName): \(error.localizedDescription)")
                }
            }
            return (installs, errors)
        }.value

        installations = result.installs
        scanErrors = result.errors
        lastScan = Date()

        let byAgent = AgentID.allCases
            .map { agent in "\(agent.rawValue)=\(result.installs.count { $0.agent == agent })" }
            .joined(separator: " ")
        Logger(subsystem: "com.cardinalblue.loadout", category: "scan")
            .notice("scan complete: \(result.installs.count) installations (\(byAgent)) errors=\(result.errors.count)")
    }
}
