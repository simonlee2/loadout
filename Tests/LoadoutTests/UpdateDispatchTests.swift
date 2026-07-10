import Foundation
import Testing
@testable import Loadout

/// stageUpdate/applyUpdate must be protocol REQUIREMENTS: RegistryStore holds
/// the library as `any SkillInstalling`, and extension-only methods would
/// statically dispatch to the throwing defaults instead of the conformer.
@Suite struct UpdateDispatchTests {
    @Test @MainActor func stageUpdateDispatchesDynamically() async throws {
        let library: any SkillInstalling = PreviewLibrary()
        let staged = try await library.stageUpdate(
            slug: "code-review",
            using: PreviewRegistryAdapter()
        )
        #expect(staged.slug == "code-review")
        #expect(!staged.changes.isEmpty)
    }
}
