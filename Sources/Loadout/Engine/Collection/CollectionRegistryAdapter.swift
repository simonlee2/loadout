import Foundation

/// Bridges an `any SkillCollection` into the existing `RegistryAdapter` browse +
/// install pipeline, so the user's personal collection appears as just another
/// registry ("My Collection") and installs "just work" through `SkillLibrary`.
///
/// - `featured()` / `search(_:)` list the collection and map each entry to a
///   `RegistrySkill` (registry `my-collection`, identifier = slug).
/// - `fetch(_:to:)` downloads the skill's tree into `destination` and returns a
///   deterministic `col-<hash-prefix>` version, matching the version reported by
///   the browse rows so update badges compare equal.
///
/// It is `@MainActor` because `SkillCollection` is main-actor isolated; a
/// `@MainActor` type is implicitly `Sendable`, satisfying `RegistryAdapter`.
@MainActor
struct CollectionRegistryAdapter: RegistryAdapter {
    /// Stable registry id, matched by `LockEntry.registry` for provenance.
    nonisolated let id = "my-collection"
    nonisolated let displayName = "My Collection"

    let collection: any SkillCollection

    init(collection: any SkillCollection) {
        self.collection = collection
    }

    func featured() async throws -> [RegistrySkill] {
        try await collection.list().map(Self.registrySkill(from:))
    }

    func search(_ query: String) async throws -> [RegistrySkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = try await collection.list()
        let matched = trimmed.isEmpty ? all : all.filter {
            $0.slug.lowercased().contains(trimmed)
                || $0.name.lowercased().contains(trimmed)
                || ($0.summary?.lowercased().contains(trimmed) ?? false)
        }
        return matched.map(Self.registrySkill(from:))
    }

    @discardableResult
    func fetch(_ skill: RegistrySkill, to destination: URL) async throws -> String {
        let hash = try await collection.download(slug: skill.slug, to: destination)
        return Self.version(forHash: hash)
    }

    // MARK: Mapping

    private static func registrySkill(from skill: CollectionSkill) -> RegistrySkill {
        RegistrySkill(
            registry: "my-collection",
            identifier: skill.slug,
            slug: skill.slug,
            name: skill.name,
            summary: skill.summary,
            version: version(forHash: skill.contentHash),
            installCount: nil,
            sourceURL: nil,
            audit: nil
        )
    }

    /// Deterministic, comparable version derived from the content hash.
    static func version(forHash hash: String) -> String {
        "col-\(hash.prefix(12))"
    }
}
