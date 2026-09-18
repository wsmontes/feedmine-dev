import FeedDomain
import Foundation

/// The minimal immutable asset commit (ADR-001 D11, ADR-004 D10, plan §10).
///
/// Publication never references bytes that were not written first, and the order below is the whole
/// point of the type:
///
/// ```
/// validate digest and byte count
///   → write a temporary file
///   → fsync it, so its content is durable
///   → move it to its immutable, content-addressed destination
///   → fsync the directory, so the rename itself is durable
///   → only now may the caller reference the asset in the publication transaction
/// ```
///
/// A crash before the reference leaves an orphan: the file is collectable and no row names it. The
/// reverse order — referencing bytes that were never durably written — is not reachable through this
/// type, which is INV-7.
///
/// Identity is `(sha256 of the exact bytes, recipe version)`, never a URL: a server can swap the bytes
/// behind a stable URL, and the published card must keep its own (ADR-001 D12, INV-8).
public struct LocalAssetStore: Sendable {
    /// How much durability a commit has to establish before the bytes may be referenced.
    ///
    /// ADR-004 leaves the concrete level open per asset class; the default file-and-directory level is
    /// the one a published asset needs, and it is what the commit tests exercise.
    public enum Durability: String, Hashable, Sendable, CaseIterable {
        /// `fsync` the file and then its parent directory: the rename is durable too.
        case fileAndDirectory
        /// `fsync` the file only.
        case fileOnly
    }

    /// A fault a test arms to prove a crash point. Production never arms one.
    public enum Interruption: String, Hashable, Sendable, CaseIterable {
        /// The process died after the temporary file was written and before the immutable move. The
        /// temporary file stays behind as an orphan, which is what a real crash leaves.
        case beforeMove
        /// The process died after the move and before the directory was synced.
        case beforeDirectorySync
    }

    /// What a successful commit produced.
    public struct Commit: Hashable, Sendable {
        public let assetVersionID: AssetVersionID
        public let descriptor: MediaAssetDescriptor
        public let relativePath: String
        public let fileURL: URL
    }

    public let rootDirectory: URL
    public let durability: Durability
    private let interruption: Interruption?

    public init(
        rootDirectory: URL,
        durability: Durability = .fileAndDirectory,
        interruption: Interruption? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.durability = durability
        self.interruption = interruption
    }

    /// The prefix of a temporary file, so orphans are distinguishable from committed assets.
    public static let temporaryPrefix = ".pending-"

    /// Where an asset lives, relative to the root: `ab/cd/<digest>_r<recipe>`.
    ///
    /// Sharded by the first two digest bytes so one directory never holds every asset, and named by the
    /// identity so a path *is* the content address.
    public func relativePath(for id: AssetVersionID) -> String {
        let hex = id.contentDigest.hex
        let first = String(hex.prefix(2))
        let second = String(hex.dropFirst(2).prefix(2))
        return "\(first)/\(second)/\(hex)_r\(id.recipeVersion.rawValue)"
    }

    public func fileURL(for id: AssetVersionID) -> URL {
        rootDirectory.appendingPathComponent(relativePath(for: id), isDirectory: false)
    }

    public func contains(_ id: AssetVersionID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    // MARK: - The commit

    /// Validates the bytes against the identity the composition priced, then makes them durable.
    ///
    /// Committing an identity that is already on disk is a no-op that returns the same commit, so a
    /// retry after a lost response neither rewrites nor duplicates bytes.
    public func commit(bytes: Data, expecting descriptor: MediaAssetDescriptor) throws -> Commit {
        let identity = descriptor.assetVersionID

        // Step 1: the bytes must be exactly the asset the caller says they are. A mismatch is refused
        // here, so different bytes can never end up filed under an identity a card already published.
        let actual = ContentDigest.sha256(bytes)
        guard actual == identity.contentDigest else {
            throw PublishedAssetCommitError.digestMismatch(
                expected: identity.contentDigest.hex,
                actual: actual.hex
            )
        }
        guard descriptor.byteCount == bytes.count else {
            throw PublishedAssetCommitError.byteCountMismatch(
                expected: descriptor.byteCount,
                actual: bytes.count
            )
        }

        let destination = fileURL(for: identity)
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PublishedAssetCommitError.fileSystem("\(error)")
        }

        // Already committed: the destination is content-addressed, so a file there is this asset.
        if FileManager.default.fileExists(atPath: destination.path) {
            return Commit(
                assetVersionID: identity,
                descriptor: descriptor,
                relativePath: relativePath(for: identity),
                fileURL: destination
            )
        }

        // Step 2: the temporary file, inside the destination's directory so the move below is a rename
        // on one filesystem and cannot half-succeed.
        let temporary = directory.appendingPathComponent("\(Self.temporaryPrefix)\(UUID().uuidString)")
        do {
            try bytes.write(to: temporary, options: [])
        } catch {
            throw PublishedAssetCommitError.fileSystem("\(error)")
        }

        if interruption == .beforeMove {
            // A crash here leaves the temporary file: an orphan with no row naming it, which
            // `collectOrphanTemporaryFiles()` reclaims.
            throw PublishedAssetCommitError.durabilityFailed(Self.interruptionProbe)
        }

        // Step 3: the bytes themselves must be durable before the rename that publishes them.
        guard Self.syncToDisk(path: temporary.path) else {
            try? FileManager.default.removeItem(at: temporary)
            throw PublishedAssetCommitError.durabilityFailed(temporary.path)
        }

        // Step 4: the immutable move.
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            let lostRace = FileManager.default.fileExists(atPath: destination.path)
            try? FileManager.default.removeItem(at: temporary)
            // Another writer published this identity first: the destination already *is* the asset,
            // because the identity is the content address.
            guard lostRace else { throw PublishedAssetCommitError.fileSystem("\(error)") }
        }

        if interruption == .beforeDirectorySync {
            throw PublishedAssetCommitError.durabilityFailed(Self.interruptionProbe)
        }

        // Step 5: make the rename itself durable, so a reference created afterwards cannot name bytes
        // the filesystem has not committed to.
        if durability == .fileAndDirectory, !Self.syncToDisk(path: directory.path) {
            throw PublishedAssetCommitError.durabilityFailed(directory.path)
        }

        return Commit(
            assetVersionID: identity,
            descriptor: descriptor,
            relativePath: relativePath(for: identity),
            fileURL: destination
        )
    }

    // MARK: - Reads and collection

    /// The bytes of an asset, or `nil` when they are not local.
    ///
    /// `nil` is the honest answer after an authorized purge: the identity survives in
    /// `asset_version`, and the card falls back to its deterministic placeholder (ADR-001 D14).
    public func storedBytes(for id: AssetVersionID) throws -> Data? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Every temporary file a crashed commit left behind, sorted.
    ///
    /// These are orphans by construction: a commit only reaches the publication transaction after the
    /// move succeeded, so a temporary file can never be referenced by a card.
    public func orphanTemporaryFiles() throws -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }
        var orphans: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix(Self.temporaryPrefix) {
            orphans.append(url)
        }
        return orphans.sorted { $0.path < $1.path }
    }

    /// Removes the orphans `orphanTemporaryFiles()` reports and returns how many bytes that released.
    @discardableResult
    public func collectOrphanTemporaryFiles() -> Int {
        var released = 0
        for url in (try? orphanTemporaryFiles()) ?? [] {
            released += Self.byteCount(of: url)
            try? FileManager.default.removeItem(at: url)
        }
        return released
    }

    /// Deletes committed bytes and returns how many bytes that released.
    ///
    /// Publication references are what pin bytes; this call removes them, and a caller that removes
    /// bytes a retained edition or an offline bookmark still pins is the bug `purgeRefusesWhilePinActive`
    /// exists to catch (ADR-004 D8).
    @discardableResult
    public func remove(_ ids: [AssetVersionID]) -> Int {
        var released = 0
        for id in ids {
            let url = fileURL(for: id)
            released += Self.byteCount(of: url)
            try? FileManager.default.removeItem(at: url)
        }
        return released
    }

    // MARK: - Internals

    static let interruptionProbe = "localAssetStoreInterrupted"

    /// `fsync` a file or a directory. A directory has no content to flush; the call makes the entries it
    /// holds — the rename that published the asset — durable.
    static func syncToDisk(path: String) -> Bool {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        return fsync(descriptor) == 0
    }

    private static func byteCount(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - The publication port

/// The runtime's bytes port. `LocalAssetStore` is its production implementation, so publication and
/// media preparation share exactly one writer and one identity scheme (ADR-001 D11, plan §10).
extension LocalAssetStore: PublishedAssetCommitting {
    public func commit(_ request: PublishedAssetRequest) async throws -> PublishedAssetCommit {
        // One validation, one hash: `commit(bytes:expecting:)` hashes the bytes once and refuses a
        // substitution with the expected and actual digests.
        let descriptor = MediaAssetDescriptor(
            identity: MediaAssetIdentity(
                assetVersionID: AssetVersionID(
                    contentDigest: try Self.digest(hex: request.contentDigest),
                    recipeVersion: try MediaRecipeVersion(request.recipeVersion)
                ),
                pixelWidth: request.pixelWidth,
                pixelHeight: request.pixelHeight,
                mimeType: request.mimeType
            ),
            byteCount: request.bytes.count
        )
        let commit = try commit(bytes: request.bytes, expecting: descriptor)
        return PublishedAssetCommit(
            contentDigest: commit.assetVersionID.contentDigest.hex,
            byteCount: request.bytes.count,
            recipeVersion: commit.assetVersionID.recipeVersion.rawValue,
            mimeType: request.mimeType,
            pixelWidth: request.pixelWidth,
            pixelHeight: request.pixelHeight,
            relativePath: commit.relativePath
        )
    }

    /// The digest of a lowercase hex string, in the shape `PublishedAssetRequest` guarantees.
    public static func digest(hex: String) throws -> ContentDigest {
        guard hex.count == ContentDigest.byteCount * 2 else {
            throw PublishedAssetCommitError.invalidDigest(hex)
        }
        var bytes = Data()
        bytes.reserveCapacity(ContentDigest.byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw PublishedAssetCommitError.invalidDigest(hex)
            }
            bytes.append(byte)
            index = next
        }
        return try ContentDigest(bytes: bytes)
    }
}

// MARK: - The media pipeline's bytes port

/// The same store behind `FeedMedia`'s own port, so preparation and publication do not each grow a
/// writer. Both ports name the asset by `(content digest, recipe version)`.
extension LocalAssetStore: MediaAssetPublishing {
    public func localBytes(for id: AssetVersionID) async throws -> Data? {
        try storedBytes(for: id)
    }

    public func publish(_ bytes: Data, descriptor: MediaAssetDescriptor) async throws {
        _ = try commit(bytes: bytes, expecting: descriptor)
    }

    public func reclaim(_ ids: [AssetVersionID]) async -> Int {
        remove(ids)
    }
}
