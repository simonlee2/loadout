import Foundation
import CloudKit
import Security

/// The real, CloudKit-backed personal collection.
///
/// ## Availability is gated on the entitlement FIRST
/// `CKContainer.default()` (and any container lookup) **traps and crashes the
/// process** when the app is not signed with an iCloud entitlement — there is
/// no throwing path to catch. Entitlements do not live in `Info.plist`, so the
/// only reliable runtime probe is to read the current task's entitlements via
/// the Security framework (`SecTaskCopyValueForEntitlement` for
/// `com.apple.developer.icloud-services`). This type therefore NEVER touches
/// `CKContainer` until that entitlement is confirmed present. Until then
/// `isAvailable` stays false and `unavailabilityReason` explains why, so the
/// whole feature degrades gracefully in an unsigned build (which is the current
/// state — signing is pending).
///
/// ## Schema (private database, default zone)
/// - Record type `Skill`, `recordName` = slug (so a slug maps to exactly one
///   record and upserts are natural).
/// - Fields: `name` (String), `summary` (String?), `contentHash` (String),
///   `archive` (CKAsset — a zip of the skill directory produced by `ditto`).
///
/// ## Testing
/// Real CloudKit can't be unit-tested here. The two things that ARE pure are
/// unit-tested directly: the entitlement guard (expected to report unavailable
/// in the unsigned test runner without crashing) and the zip/unzip round-trip
/// (`CloudKitArchive`). The CK calls are funnelled through small private
/// methods so they at least compile-check.
@MainActor
final class CloudKitCollection: SkillCollection {
    /// MUST match the `com.apple.developer.icloud-container-identifiers`
    /// entry in Loadout's entitlement once the app is signed.
    static let containerIdentifier = "iCloud.com.simonlee.Loadout"

    /// The entitlement key whose presence proves the app can safely touch
    /// CloudKit without trapping.
    private static let icloudEntitlementKey = "com.apple.developer.icloud-services"

    private static let recordType = "Skill"
    private enum Field {
        static let name = "name"
        static let summary = "summary"
        static let contentHash = "contentHash"
        static let archive = "archive"
    }

    private(set) var isAvailable = false
    private(set) var unavailabilityReason: String? =
        "Loadout hasn't checked iCloud yet."

    // Created ONLY after the entitlement guard passes (see `activate`), so an
    // unsigned build never instantiates a container and never traps.
    private var database: CKDatabase?

    init() {}

    // MARK: Activation / availability

    /// Confirms the app may use CloudKit and, if so, that an iCloud account is
    /// signed in. Safe to call on an unsigned build: it returns early with a
    /// reason and never constructs a `CKContainer`.
    func activate() async {
        guard Self.hasICloudEntitlement() else {
            isAvailable = false
            unavailabilityReason = "Loadout isn't signed with the iCloud capability yet."
            database = nil
            return
        }

        // Entitlement present — now it is safe to touch CloudKit.
        let container = CKContainer(identifier: Self.containerIdentifier)
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                database = container.privateCloudDatabase
                isAvailable = true
                unavailabilityReason = nil
            case .noAccount:
                fail("Sign into iCloud in System Settings to use your collection.")
            case .restricted:
                fail("iCloud access is restricted on this Mac.")
            case .couldNotDetermine:
                fail("Couldn't determine your iCloud account status; try again.")
            case .temporarilyUnavailable:
                fail("iCloud is temporarily unavailable; try again shortly.")
            @unknown default:
                fail("iCloud is unavailable.")
            }
        } catch {
            fail(Self.map(error).description)
        }
    }

    private func fail(_ reason: String) {
        isAvailable = false
        unavailabilityReason = reason
        database = nil
    }

    /// Reads the current task's entitlements via the Security framework. Returns
    /// false (never crashes) in an unsigned/entitlement-less process.
    static func hasICloudEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, icloudEntitlementKey as CFString, &error)
        error?.release()
        // Presence of ANY value for the iCloud-services entitlement is enough;
        // its shape is an array of enabled services.
        return value != nil
    }

    // MARK: SkillCollection

    // CloudKit's auto-created schema doesn't allow whole-type queries
    // (recordName isn't queryable), so the collection maintains its own
    // index record — everything is fetched by ID, which needs no indexes.
    private static let indexRecordName = "collection-index"
    private static let indexRecordType = "CollectionIndex"
    private static let indexEntriesField = "entries"

    func list() async throws -> [CollectionSkill] {
        let database = try requireDatabase()
        let index = try await fetchIndexRecord(database)
        return Self.decodeIndexEntries(index).sorted { $0.slug < $1.slug }
    }

    private func fetchIndexRecord(_ database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: CKRecord.ID(recordName: Self.indexRecordName))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw Self.map(error)
        }
    }

    private static func decodeIndexEntries(_ record: CKRecord?) -> [CollectionSkill] {
        guard let json = record?[indexEntriesField] as? String,
              let data = json.data(using: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CollectionSkill].self, from: data)) ?? []
    }

    private func saveIndex(_ entries: [CollectionSkill], database: CKDatabase) async throws {
        let record = try await fetchIndexRecord(database)
            ?? CKRecord(
                recordType: Self.indexRecordType,
                recordID: CKRecord.ID(recordName: Self.indexRecordName)
            )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries.sorted { $0.slug < $1.slug })
        record[Self.indexEntriesField] = String(data: data, encoding: .utf8)! as CKRecordValue
        do {
            _ = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys, atomically: true
            )
        } catch {
            throw Self.map(error)
        }
    }

    func publish(slug: String, name: String, summary: String?, directory: URL) async throws {
        let database = try requireDatabase()
        let contentHash = try TreeHash.hash(directory: directory)
        let archive = try CloudKitArchive.zip(directory: directory)
        defer { try? FileManager.default.removeItem(at: archive) }

        let recordID = CKRecord.ID(recordName: slug)
        // Upsert: reuse the existing record when present so its metadata (and
        // the private-zone placement) are preserved; otherwise create anew.
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        } catch {
            throw Self.map(error)
        }

        record[Field.name] = name as CKRecordValue
        record[Field.summary] = summary as CKRecordValue?
        record[Field.contentHash] = contentHash as CKRecordValue
        record[Field.archive] = CKAsset(fileURL: archive)

        do {
            _ = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys, atomically: true
            )
        } catch {
            throw Self.map(error)
        }

        var entries = Self.decodeIndexEntries(try await fetchIndexRecord(database))
        entries.removeAll { $0.slug == slug }
        entries.append(CollectionSkill(
            slug: slug, name: name, summary: summary,
            contentHash: contentHash, updatedAt: Date()
        ))
        try await saveIndex(entries, database: database)
    }

    @discardableResult
    func download(slug: String, to destination: URL) async throws -> String {
        let database = try requireDatabase()
        let recordID = CKRecord.ID(recordName: slug)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            throw CollectionError.notFound(slug: slug)
        } catch {
            throw Self.map(error)
        }

        guard
            let asset = record[Field.archive] as? CKAsset,
            let assetURL = asset.fileURL
        else {
            throw CollectionError.io("record \(slug) has no archive asset")
        }
        let expectedHash = (record[Field.contentHash] as? String) ?? ""

        try CloudKitArchive.unzip(assetURL, to: destination)
        let actual = try TreeHash.hash(directory: destination)
        if !expectedHash.isEmpty, actual != expectedHash {
            throw CollectionError.hashMismatch(slug: slug, expected: expectedHash, actual: actual)
        }
        return actual
    }

    func remove(slug: String) async throws {
        let database = try requireDatabase()
        do {
            _ = try await database.modifyRecords(
                saving: [], deleting: [CKRecord.ID(recordName: slug)],
                savePolicy: .allKeys, atomically: true
            )
        } catch let error as CKError where error.code == .unknownItem {
            throw CollectionError.notFound(slug: slug)
        } catch {
            throw Self.map(error)
        }

        var entries = Self.decodeIndexEntries(try await fetchIndexRecord(database))
        entries.removeAll { $0.slug == slug }
        try await saveIndex(entries, database: database)
    }

    // MARK: Seam / mapping

    private func requireDatabase() throws -> CKDatabase {
        guard isAvailable, let database else {
            throw CollectionError.unavailable(
                reason: unavailabilityReason ?? "iCloud is unavailable."
            )
        }
        return database
    }

    private static func skill(from record: CKRecord) -> CollectionSkill? {
        guard
            let name = record[Field.name] as? String,
            let contentHash = record[Field.contentHash] as? String
        else { return nil }
        return CollectionSkill(
            slug: record.recordID.recordName,
            name: name,
            summary: record[Field.summary] as? String,
            contentHash: contentHash,
            updatedAt: record.modificationDate ?? Date.distantPast
        )
    }

    /// Maps a CloudKit error to a descriptive `CollectionError`.
    static func map(_ error: Error) -> CollectionError {
        guard let ckError = error as? CKError else {
            return .io(error.localizedDescription)
        }
        switch ckError.code {
        case .notAuthenticated:
            return .accountUnavailable("Sign into iCloud to use your collection.")
        case .accountTemporarilyUnavailable:
            return .accountUnavailable("Your iCloud account is temporarily unavailable.")
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return .network(ckError.localizedDescription)
        case .quotaExceeded:
            return .quotaExceeded
        case .unknownItem:
            return .notFound(slug: "?")
        default:
            return .io(ckError.localizedDescription)
        }
    }
}

/// Zip/unzip of a skill directory via `/usr/bin/ditto`, used by
/// `CloudKitCollection` for the `archive` asset. Pure and side-effect-local
/// (temp files only), so it is unit-tested directly with fixture trees.
///
/// `ditto -c -k <dir> <zip>` (no `--keepParent`) archives the *contents* of
/// `dir` at the archive root; `ditto -x -k <zip> <dest>` restores that tree
/// directly under `dest`. A round-trip therefore reproduces the tree exactly,
/// so `TreeHash` is preserved.
enum CloudKitArchive {
    /// Zips `directory`'s contents into a fresh temp `.zip` file and returns it.
    /// The caller owns the returned file and should delete it when done.
    static func zip(directory: URL) throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadout-collection-\(UUID().uuidString).zip", isDirectory: false)
        try runDitto(["-c", "-k", directory.path, output.path])
        return output
    }

    /// Extracts `archive` into `destination`, creating it if needed.
    static func unzip(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try runDitto(["-x", "-k", archive.path, destination.path])
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw CollectionError.archiveFailed("could not launch ditto: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CollectionError.archiveFailed("ditto exited \(process.terminationStatus): \(message)")
        }
    }
}
