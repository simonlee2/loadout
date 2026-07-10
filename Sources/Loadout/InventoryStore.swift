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

    // MARK: - Project scope

    private var projectOverrides: (any ProjectOverriding)?
    private(set) var projectPreferences: ProjectPreferences?
    /// Projects currently visible in the UI (hidden ones included only when
    /// `showHidden` is on).
    private(set) var projects: [ProjectRef] = []
    /// The full combined list with per-item flags, for the sidebar.
    private(set) var projectItems: [ProjectItem] = []

    struct ProjectItem: Identifiable, Hashable, Sendable {
        let ref: ProjectRef
        let isHidden: Bool
        let isManual: Bool
        var id: String { ref.id }
    }

    func configureProjects(
        _ overriding: any ProjectOverriding,
        preferences: ProjectPreferences
    ) {
        projectOverrides = overriding
        projectPreferences = preferences
        refreshProjects()
    }

    func refreshProjects() {
        let auto = (try? projectOverrides?.projects()) ?? []
        let autoPaths = Set(auto.map(\.path))
        let manual = (projectPreferences?.added ?? [])
            .filter { !autoPaths.contains($0) }
            .filter { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                    && isDir.boolValue
            }
            .map { ProjectRef(path: $0) }
        let hidden = projectPreferences?.hidden ?? []

        projectItems = (auto.map { ($0, false) } + manual.map { ($0, true) })
            .map { ref, isManual in
                ProjectItem(ref: ref, isHidden: hidden.contains(ref.path), isManual: isManual)
            }
            .sorted { $0.ref.name.localizedCaseInsensitiveCompare($1.ref.name) == .orderedAscending }

        let showHidden = projectPreferences?.showHidden ?? false
        projects = projectItems
            .filter { showHidden || !$0.isHidden }
            .map(\.ref)
    }

    func hideProject(_ path: String) {
        projectPreferences?.hide(path)
        refreshProjects()
    }

    func unhideProject(_ path: String) {
        projectPreferences?.unhide(path)
        refreshProjects()
    }

    func addManualProject(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            lastActionError = "\(url.lastPathComponent) isn't a folder."
            return
        }
        projectPreferences?.add(url.path)
        refreshProjects()
    }

    func removeManualProject(_ path: String) {
        projectPreferences?.removeAdded(path)
        refreshProjects()
    }

    func setShowHiddenProjects(_ show: Bool) {
        projectPreferences?.showHidden = show
        refreshProjects()
    }

    func projectSkillStates(in project: ProjectRef) -> [ProjectSkillState] {
        do {
            return try projectOverrides?.skillStates(in: project) ?? []
        } catch {
            lastActionError = "Couldn't read project skills: \(error.localizedDescription)"
            return []
        }
    }

    func setSkill(_ slug: String, enabled: Bool, in project: ProjectRef) async {
        guard let projectOverrides, let journal else {
            lastActionError = "Project overrides aren't configured."
            return
        }
        do {
            _ = try projectOverrides.setSkill(slug, enabled: enabled, in: project, journal: journal)
        } catch {
            lastActionError = error.localizedDescription
        }
        await rescan()
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
