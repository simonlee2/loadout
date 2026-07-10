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

    /// Error from the most recent toggle/uninstall/revert, for UI alerts.
    var lastActionError: String?

    private let scanners: [any AgentScanner]
    private var writers: [AgentID: any AgentConfigWriter] = [:]
    private(set) var journal: ChangeJournal?

    init(scanners: [any AgentScanner]) {
        self.scanners = scanners
    }

    /// Enables the write side (M1). Until called, every toggle is read-only
    /// disabled and the store behaves exactly like M0.
    func configureWriting(writers: [any AgentConfigWriter], journal: ChangeJournal) {
        self.writers = Dictionary(uniqueKeysWithValues: writers.map { ($0.agent, $0) })
        self.journal = journal
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

    // MARK: - Write side (M1)

    func canToggle(_ installation: SkillInstallation) -> Bool {
        writers[installation.agent]?.canToggle(installation) ?? false
    }

    func canUninstall(_ installation: SkillInstallation) -> Bool {
        writers[installation.agent]?.canUninstall(installation) ?? false
    }

    func toggleScope(_ installation: SkillInstallation) -> ToggleScope {
        writers[installation.agent]?.toggleScope(installation) ?? .skill
    }

    /// Installations gated by the same plugin-scope toggle (including the
    /// given one) — what a `.plugin` toggle actually flips.
    func siblings(of installation: SkillInstallation) -> [SkillInstallation] {
        guard case .plugin(let name) = toggleScope(installation) else { return [installation] }
        return installations.filter {
            $0.agent == installation.agent && $0.origin == .plugin(name: name)
        }
    }

    func setEnabled(_ enabled: Bool, for installation: SkillInstallation) async {
        await performWrite(on: installation) { writer, journal in
            try writer.setSkillEnabled(installation, enabled: enabled, journal: journal)
        }
    }

    func uninstall(_ installation: SkillInstallation) async {
        await performWrite(on: installation) { writer, journal in
            try writer.uninstall(installation, journal: journal)
        }
    }

    func revert(_ change: ConfigChange) async {
        guard let journal else { return }
        do {
            try journal.revert(change)
        } catch {
            lastActionError = "Revert failed: \(error.localizedDescription)"
        }
        await rescan()
    }

    private func performWrite(
        on installation: SkillInstallation,
        _ operation: (any AgentConfigWriter, ChangeJournal) throws -> ConfigChange
    ) async {
        guard let writer = writers[installation.agent], let journal else {
            lastActionError = "Writing isn't configured for \(installation.agent.displayName)."
            return
        }
        do {
            _ = try operation(writer, journal)
        } catch {
            lastActionError = error.localizedDescription
        }
        await rescan()
    }
}
