import Foundation
import Testing
@testable import Loadout

/// Offline tests for `SkillsShAdapter.latestVersion(for:)`. Every network
/// call is served by an injected transport — no live network.
@Suite struct SkillsShLatestVersionTests {

    static let headSHA = "9b1c6f2e8d4a5b3c7e0f1a2d4c6b8e0f2a4c6e8d"

    // MARK: Helpers

    /// Thread-safe call counter so tests can assert exactly how many
    /// requests the adapter issued.
    final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    /// A transport that answers every request with the given status/body and
    /// bumps `counter`.
    static func transport(
        status: Int = 200, body: String, counter: RequestCounter? = nil
    ) -> SkillsShAdapter.Transport {
        { request in
            counter?.increment()
            let url = request.url!
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    /// A git-clone closure that must never run (latestVersion never clones).
    static let failingClone: SkillsShAdapter.GitClone = { _, _ in
        throw SkillsShError.fetchFailed("git clone must not run in this test")
    }

    static func entry(
        registry: String = "skills.sh",
        identifier: String = "vercel-labs/skills/find-skills"
    ) -> LockEntry {
        LockEntry(
            slug: "find-skills",
            registry: registry,
            identifier: identifier,
            version: "4ce6d48ac44c8b637db87b2102fea3baca719df1",
            contentHash: String(repeating: "0", count: 64),
            fetchedAt: Date(),
            deployments: []
        )
    }

    // MARK: Cases

    @Test func latestVersionResolvesHeadSHAWithOneRequest() async throws {
        let counter = RequestCounter()
        let adapter = SkillsShAdapter(
            transport: Self.transport(
                body: #"{"sha":"\#(Self.headSHA)","commit":{"message":"chore"}}"#,
                counter: counter
            ),
            gitClone: Self.failingClone
        )

        let latest = try await adapter.latestVersion(for: Self.entry())

        #expect(latest == Self.headSHA)
        #expect(counter.count == 1)
    }

    @Test func latestVersionForOtherRegistryReturnsNilWithoutNetwork() async throws {
        let counter = RequestCounter()
        let adapter = SkillsShAdapter(
            transport: Self.transport(body: "must not be called", counter: counter),
            gitClone: Self.failingClone
        )

        let latest = try await adapter.latestVersion(
            for: Self.entry(registry: "local", identifier: "/Users/someone/.claude/skills/my-skill")
        )

        #expect(latest == nil)
        #expect(counter.count == 0)
    }

    @Test func latestVersionHTTPErrorThrows() async {
        let adapter = SkillsShAdapter(
            transport: Self.transport(status: 500, body: "boom"),
            gitClone: Self.failingClone
        )

        await #expect(throws: SkillsShError.httpStatus(
            500, endpoint: "https://api.github.com/repos/vercel-labs/skills/commits/HEAD"
        )) {
            _ = try await adapter.latestVersion(for: Self.entry())
        }
    }
}
