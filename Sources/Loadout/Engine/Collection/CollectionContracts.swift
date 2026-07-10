import Foundation

/// One skill as stored in the user's personal, cross-machine collection.
struct CollectionSkill: Identifiable, Hashable, Sendable, Codable {
    let slug: String
    let name: String
    let summary: String?
    /// SHA-256 over the skill's file tree (see `TreeHash`), recorded when the
    /// skill was published so downloads can be integrity-checked.
    let contentHash: String
    let updatedAt: Date

    var id: String { slug }
}

/// A cross-machine store for the user's personal skill collection.
///
/// Two implementations exist: `FolderCollection` (any folder — the mock, the
/// automated-test vehicle, and a plain iCloud-Drive-folder mode) and
/// `CloudKitCollection` (the real CloudKit-backed store, which degrades
/// gracefully to unavailable until the app is signed with the iCloud
/// capability). All work funnels through this protocol so the rest of the app
/// never depends on CloudKit being present.
@MainActor
protocol SkillCollection {
    /// Whether the store is usable right now. `CloudKitCollection` reports
    /// false until `activate()` confirms both the entitlement and an iCloud
    /// account; `FolderCollection` reports whether its backing volume exists.
    var isAvailable: Bool { get }

    /// Performs startup checks (entitlement, account). Default: no-op.
    func activate() async

    /// Human-readable reason when unavailable (e.g. "Sign into iCloud",
    /// "Loadout isn't signed with the iCloud capability yet"). Nil when
    /// `isAvailable` is true.
    var unavailabilityReason: String? { get }

    /// Every skill currently in the collection, newest update first is not
    /// guaranteed — callers sort as they wish.
    func list() async throws -> [CollectionSkill]

    /// Uploads/overwrites one skill's file tree from a local directory.
    func publish(slug: String, name: String, summary: String?, directory: URL) async throws

    /// Downloads a skill's file tree into `destination` (an existing empty
    /// directory) and returns the resolved `contentHash`.
    @discardableResult
    func download(slug: String, to destination: URL) async throws -> String

    /// Removes a skill from the collection.
    func remove(slug: String) async throws
}

extension SkillCollection {
    func activate() async {}
}

/// Failures the collection stores report; every case carries a descriptive
/// message so the UI can surface it verbatim.
enum CollectionError: Error, LocalizedError, CustomStringConvertible {
    case unavailable(reason: String)
    case notFound(slug: String)
    case hashMismatch(slug: String, expected: String, actual: String)
    case archiveFailed(String)
    case io(String)
    case accountUnavailable(String)
    case network(String)
    case quotaExceeded

    var description: String {
        switch self {
        case .unavailable(let reason):
            return reason
        case .notFound(let slug):
            return "Skill \"\(slug)\" is not in the collection."
        case .hashMismatch(let slug, let expected, let actual):
            return "Downloaded \"\(slug)\" is corrupt: expected content hash "
                + "\(expected.prefix(12))… but got \(actual.prefix(12))…."
        case .archiveFailed(let detail):
            return "Could not archive or unpack the skill files: \(detail)."
        case .io(let detail):
            return "A file error occurred: \(detail)."
        case .accountUnavailable(let detail):
            return detail
        case .network(let detail):
            return "iCloud is unreachable: \(detail)."
        case .quotaExceeded:
            return "Your iCloud storage is full; free up space and try again."
        }
    }

    var errorDescription: String? { description }
}
