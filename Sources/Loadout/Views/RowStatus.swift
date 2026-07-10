import SwiftUI
import Foundation

/// Computed sync/attention status for one matrix row. `compute` is pure given
/// its inputs (plus the hash cache), so it can be unit-tested directly.
enum RowStatus: Equatable {
    /// Managed by Loadout's library, with the recorded version.
    case managed(version: String)
    /// A newer upstream version is available; `display` is already shortened.
    case update(display: String)
    /// Present in every agent and content-identical (or library-managed).
    case synced
    /// Present in more than one agent, unmanaged, and the trees differ.
    case differs
    /// Present in exactly one agent.
    case agentOnly(AgentID)
    /// In more than one agent but the trees can't be read to compare.
    case unknown

    /// Resolves a row to its status. Priority (highest first): update available,
    /// library-managed, then cross-agent tree comparison, then single-agent.
    @MainActor
    static func compute(
        _ row: SkillRow,
        lockVersions: [String: String],
        updatesAvailable: [String: String],
        cache: RowStatusCache
    ) -> RowStatus {
        if let latest = updatesAvailable[row.slug] {
            return .update(display: shortVersion(latest))
        }
        if let version = lockVersions[row.slug] {
            return .managed(version: version)
        }

        let agents = Set(row.installations.map(\.agent))
        if agents.count >= 2 {
            var hashes: [String] = []
            for installation in row.installations {
                guard let hash = cache.treeHash(for: installation) else {
                    return .unknown
                }
                hashes.append(hash)
            }
            return Set(hashes).count == 1 ? .synced : .differs
        }

        if let only = row.installations.first {
            return .agentOnly(only.agent)
        }
        return .unknown
    }

    /// True when the row should surface in the "Needs Attention" smart list:
    /// an update is available, the trees differ, or an installation is a
    /// dangling symlink.
    @MainActor
    static func needsAttention(
        _ row: SkillRow,
        lockVersions: [String: String],
        updatesAvailable: [String: String],
        cache: RowStatusCache
    ) -> Bool {
        if updatesAvailable[row.slug] != nil { return true }
        if row.installations.contains(where: { isDanglingSymlink($0.directory) }) { return true }
        if case .differs = compute(
            row,
            lockVersions: lockVersions,
            updatesAvailable: updatesAvailable,
            cache: cache
        ) {
            return true
        }
        return false
    }

    /// A symlink whose destination no longer exists. `lstat` identifies the
    /// link itself; `stat` (which follows it) failing means the target is gone.
    static func isDanglingSymlink(_ url: URL) -> Bool {
        let path = url.path
        var linkInfo = stat()
        guard lstat(path, &linkInfo) == 0 else { return false }
        guard (linkInfo.st_mode & S_IFMT) == S_IFLNK else { return false }
        var targetInfo = stat()
        return stat(path, &targetInfo) != 0
    }

    /// Shows a commit SHA as its short form; leaves semver-style tags intact.
    static func shortVersion(_ value: String) -> String {
        if value.count >= 7, value.allSatisfy(\.isHexDigit) {
            return String(value.prefix(7))
        }
        return value
    }
}

/// Per-installation tree-hash memo, keyed by directory path + last-modified so a
/// rescan that touches a skill invalidates just that entry. Deliberately not
/// `@Observable`: it's mutated during view body evaluation (a read), and
/// triggering observation there would be a re-render cycle. Hashing missing or
/// unreadable directories is cached as `nil` ("unknown") so it isn't retried.
@MainActor
final class RowStatusCache {
    private var hashes: [String: String?] = [:]

    func treeHash(for installation: SkillInstallation) -> String? {
        let stamp = installation.lastModified.map { String($0.timeIntervalSince1970) } ?? "nil"
        let key = "\(installation.directory.path)|\(stamp)"
        if let cached = hashes[key] { return cached }
        let value = try? TreeHash.hash(directory: installation.directory)
        hashes[key] = value
        return value
    }
}

/// The matrix "Status" cell: colored chips for managed/update/synced/differs,
/// a plain secondary label for single-agent rows, and a faint dash when the
/// cross-agent comparison can't be made.
struct StatusCell: View {
    let status: RowStatus

    var body: some View {
        switch status {
        case .managed(let version):
            StatusChip(text: "Managed \(RowStatus.shortVersion(version))", tint: .accentColor)
        case .update(let display):
            StatusChip(text: "Update \(display)", tint: .orange)
        case .synced:
            StatusChip(text: "Synced", tint: .green)
        case .differs:
            StatusChip(text: "Differs", tint: .orange)
        case .agentOnly(let agent):
            Text("\(agent.displayName) only")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .unknown:
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }
}

/// A tinted status pill. Mirrors `OriginChip`'s geometry with a colored fill.
struct StatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
