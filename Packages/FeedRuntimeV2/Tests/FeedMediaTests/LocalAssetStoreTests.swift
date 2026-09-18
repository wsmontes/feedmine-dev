import FeedDomain
import Foundation
import XCTest
@testable import FeedMedia

/// PR-06, the minimal local media commit: identity is the digest of the exact bytes, and the bytes are
/// durable before anything may reference them (plan §10, ADR-001 D11/D12, ADR-004 D10).
///
/// Every test runs against a real directory in `$TMPDIR` that teardown removes; nothing here reads the
/// network, the clock or a database. The publication side of the same contract — that no card references
/// bytes the store never committed — is proven in `FeedRuntimeTests/PublicationCoordinatorTests`, because
/// `FeedMedia` may not see `FeedStorage`.
final class LocalAssetStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedmedia-pr06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func store(interruption: LocalAssetStore.Interruption? = nil) -> LocalAssetStore {
        LocalAssetStore(rootDirectory: directory, interruption: interruption)
    }

    private func descriptor(
        for bytes: Data,
        recipeVersion: Int = 1,
        pixelWidth: Int? = 600,
        pixelHeight: Int? = 200,
        mimeType: String? = "image/png"
    ) throws -> MediaAssetDescriptor {
        MediaAssetDescriptor(
            identity: MediaAssetIdentity(
                assetVersionID: AssetVersionID(
                    contentDigest: ContentDigest.sha256(bytes),
                    recipeVersion: try MediaRecipeVersion(recipeVersion)
                ),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                mimeType: mimeType
            ),
            byteCount: bytes.count
        )
    }

    private func request(
        bytes: Data,
        digest: String? = nil,
        recipeVersion: Int = 1,
        candidateKey: String = "image#0",
        role: MediaRole = .image
    ) throws -> PublishedAssetRequest {
        try PublishedAssetRequest(
            candidateKey: candidateKey,
            role: role,
            bytes: bytes,
            contentDigest: digest ?? ContentDigest.sha256(bytes).hex,
            recipeVersion: recipeVersion,
            mimeType: "image/png",
            pixelWidth: 600,
            pixelHeight: 200
        )
    }

    // MARK: - Identity and the immutable destination

    /// The committed path *is* the content address, and the bytes are exactly the bytes handed in.
    func testCommitWritesImmutableContentAddressedBytes() throws {
        let bytes = Data("the exact bytes of one asset".utf8)
        let descriptor = try descriptor(for: bytes)
        let commit = try store().commit(bytes: bytes, expecting: descriptor)

        let hex = descriptor.assetVersionID.contentDigest.hex
        XCTAssertEqual(commit.relativePath, "\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex)_r1")
        XCTAssertEqual(commit.assetVersionID, descriptor.assetVersionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commit.fileURL.path))
        XCTAssertEqual(try store().storedBytes(for: descriptor.assetVersionID), bytes)
        XCTAssertTrue(store().contains(descriptor.assetVersionID))
        XCTAssertEqual(try store().orphanTemporaryFiles(), [], "a committed asset leaves no temporary file")

        // A second commit of the same identity is a no-op, not a rewrite: the destination is the asset.
        let again = try store().commit(bytes: bytes, expecting: descriptor)
        XCTAssertEqual(again.fileURL, commit.fileURL)
        XCTAssertEqual(try store().storedBytes(for: descriptor.assetVersionID), bytes)
    }

    /// Identity is `(digest, recipe)`, and a URL is nowhere in it: two byte strings are two assets even
    /// when they came from the same locator, and re-using an identity for different bytes is refused.
    func testAssetIdentityIsTheDigestAndNeverALocator() throws {
        let first = Data("first bytes from a stable url".utf8)
        let second = Data("different bytes from the same url".utf8)
        let firstDescriptor = try descriptor(for: first)
        let secondDescriptor = try descriptor(for: second)

        XCTAssertNotEqual(firstDescriptor.assetVersionID, secondDescriptor.assetVersionID)
        let firstCommit = try store().commit(bytes: first, expecting: firstDescriptor)
        let secondCommit = try store().commit(bytes: second, expecting: secondDescriptor)
        XCTAssertNotEqual(firstCommit.fileURL, secondCommit.fileURL)
        XCTAssertEqual(try store().storedBytes(for: firstDescriptor.assetVersionID), first)
        XCTAssertEqual(try store().storedBytes(for: secondDescriptor.assetVersionID), second)

        // The same identity with different bytes is a substitution, never a silent overwrite.
        XCTAssertThrowsError(try store().commit(bytes: second, expecting: firstDescriptor)) { error in
            XCTAssertEqual(
                error as? PublishedAssetCommitError,
                .digestMismatch(
                    expected: firstDescriptor.assetVersionID.contentDigest.hex,
                    actual: ContentDigest.sha256(second).hex
                )
            )
        }
        XCTAssertEqual(
            try store().storedBytes(for: firstDescriptor.assetVersionID),
            first,
            "the refused commit left the committed bytes alone"
        )

        // A different recipe version is a different asset over the same bytes.
        let recipeTwo = try descriptor(for: first, recipeVersion: 2)
        XCTAssertNotEqual(recipeTwo.assetVersionID, firstDescriptor.assetVersionID)
        XCTAssertNotEqual(
            try store().commit(bytes: first, expecting: recipeTwo).relativePath,
            firstCommit.relativePath
        )
    }

    /// Validation happens before anything is written, and it reports which half disagreed.
    func testCommitValidatesDigestAndByteCountBeforeWriting() throws {
        let bytes = Data("validated before it is written".utf8)
        let descriptor = try descriptor(for: bytes)

        let wrongDigest = MediaAssetDescriptor(
            identity: MediaAssetIdentity(
                assetVersionID: AssetVersionID(
                    contentDigest: ContentDigest.sha256(Data("another asset".utf8)),
                    recipeVersion: try MediaRecipeVersion(1)
                ),
                pixelWidth: 600,
                pixelHeight: 200,
                mimeType: "image/png"
            ),
            byteCount: bytes.count
        )
        XCTAssertThrowsError(try store().commit(bytes: bytes, expecting: wrongDigest)) { error in
            guard case .digestMismatch = error as? PublishedAssetCommitError else {
                return XCTFail("expected a digest mismatch, got \(error)")
            }
        }

        let wrongCount = MediaAssetDescriptor(identity: descriptor.identity, byteCount: bytes.count + 1)
        XCTAssertThrowsError(try store().commit(bytes: bytes, expecting: wrongCount)) { error in
            XCTAssertEqual(
                error as? PublishedAssetCommitError,
                .byteCountMismatch(expected: bytes.count + 1, actual: bytes.count)
            )
        }

        // Nothing was written by either refusal: no asset, no temporary file.
        XCTAssertFalse(store().contains(descriptor.assetVersionID))
        XCTAssertEqual(try store().orphanTemporaryFiles(), [])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [],
            "a refused commit creates no directory tree either"
        )
    }

    // MARK: - Crash points

    /// A crash after the temporary write and before the immutable move: no asset exists, and the
    /// temporary file is an orphan that collection reclaims (ADR-001 D11's edge case).
    func testCrashBeforeTheMoveLeavesACollectableOrphan() throws {
        let bytes = Data("bytes that never reached their destination".utf8)
        let descriptor = try descriptor(for: bytes)
        let crashing = store(interruption: .beforeMove)

        XCTAssertThrowsError(try crashing.commit(bytes: bytes, expecting: descriptor)) { error in
            XCTAssertEqual(
                error as? PublishedAssetCommitError,
                .durabilityFailed(LocalAssetStore.interruptionProbe)
            )
        }

        XCTAssertFalse(crashing.contains(descriptor.assetVersionID), "no asset was published")
        XCTAssertNil(try crashing.storedBytes(for: descriptor.assetVersionID))
        let orphans = try crashing.orphanTemporaryFiles()
        XCTAssertEqual(orphans.count, 1)
        XCTAssertTrue(orphans[0].lastPathComponent.hasPrefix(LocalAssetStore.temporaryPrefix))

        let released = crashing.collectOrphanTemporaryFiles()
        XCTAssertEqual(released, bytes.count, "collection reports the bytes it freed")
        XCTAssertEqual(try crashing.orphanTemporaryFiles(), [])
        XCTAssertFalse(crashing.contains(descriptor.assetVersionID))
    }

    /// A crash after the move but before the directory was synced: the store refuses the commit, so the
    /// caller can never reference it; the bytes that did land are reclaimed by collection, not adopted.
    func testCrashBeforeDirectorySyncRefusesTheCommitAndLeavesNoReference() throws {
        let bytes = Data("moved but not yet made durable".utf8)
        let descriptor = try descriptor(for: bytes)
        let crashing = store(interruption: .beforeDirectorySync)

        XCTAssertThrowsError(try crashing.commit(bytes: bytes, expecting: descriptor)) { error in
            XCTAssertEqual(
                error as? PublishedAssetCommitError,
                .durabilityFailed(LocalAssetStore.interruptionProbe)
            )
        }
        XCTAssertEqual(try crashing.orphanTemporaryFiles(), [], "the move had already happened")

        // A later commit re-verifies the identity and completes: the bytes are the bytes.
        let commit = try store().commit(bytes: bytes, expecting: descriptor)
        XCTAssertEqual(try store().storedBytes(for: descriptor.assetVersionID), bytes)
        XCTAssertEqual(commit.assetVersionID, descriptor.assetVersionID)

        // And collection is what removes bytes nothing references.
        let released = store().remove([descriptor.assetVersionID])
        XCTAssertEqual(released, bytes.count)
        XCTAssertNil(try store().storedBytes(for: descriptor.assetVersionID))
        XCTAssertFalse(store().contains(descriptor.assetVersionID))
    }

    // MARK: - The ports

    /// The publication port: bytes come from the runtime as hex and integers, and the store answers with
    /// the description the published reference will name.
    func testPublicationPortCommitsAndValidatesBytes() async throws {
        let bytes = Data("publication-port bytes".utf8)
        let store = store()
        let commit = try await store.commit(try request(bytes: bytes))

        XCTAssertEqual(commit.contentDigest, ContentDigest.sha256(bytes).hex)
        XCTAssertEqual(commit.byteCount, bytes.count)
        XCTAssertEqual(commit.recipeVersion, 1)
        XCTAssertEqual(commit.mimeType, "image/png")
        XCTAssertEqual(
            commit.relativePath,
            "\(commit.contentDigest.prefix(2))/\(commit.contentDigest.dropFirst(2).prefix(2))/"
                + "\(commit.contentDigest)_r1",
            "the published path is the same content address the media pipeline uses"
        )
        XCTAssertEqual(commit.mediaReference.aspectRatio, 3.0)

        // A request whose digest does not describe its bytes is refused: a card can never reference
        // bytes other than the ones it priced.
        let lying = try request(bytes: bytes, digest: String(repeating: "00", count: 32))
        do {
            _ = try await store.commit(lying)
            XCTFail("bytes that do not match their identity must be refused")
        } catch let error as PublishedAssetCommitError {
            guard case .digestMismatch = error else {
                return XCTFail("expected a digest mismatch, got \(error)")
            }
        }
        XCTAssertEqual(try store.orphanTemporaryFiles(), [])

        // The same request twice: one identity, one file.
        _ = try await store.commit(try request(bytes: bytes))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1)
    }

    /// The media pipeline's own port is served by the same store, so preparation and publication cannot
    /// diverge into two identity schemes.
    func testMediaPublishingPortUsesTheSameIdentityScheme() async throws {
        let bytes = Data("prepared by the media pipeline".utf8)
        let descriptor = try descriptor(for: bytes)
        let store = store()

        try await store.publish(bytes, descriptor: descriptor)
        let published = try await store.localBytes(for: descriptor.assetVersionID)
        XCTAssertEqual(published, bytes, "the pipeline's port names the same bytes by the same identity")
        XCTAssertTrue(store.contains(descriptor.assetVersionID))

        let released = await store.reclaim([descriptor.assetVersionID])
        XCTAssertEqual(released, bytes.count)
        let afterReclaim = try await store.localBytes(for: descriptor.assetVersionID)
        XCTAssertNil(afterReclaim)
        let secondReclaim = await store.reclaim([descriptor.assetVersionID])
        XCTAssertEqual(secondReclaim, 0, "reclaiming twice frees nothing")
    }

    /// A digest of the wrong shape never reaches the file system, and the store's own validation is the
    /// only thing that decides identity.
    func testMalformedIdentityIsRefused() throws {
        XCTAssertThrowsError(
            try PublishedAssetRequest(
                candidateKey: "image#0",
                role: .image,
                bytes: Data("bytes".utf8),
                contentDigest: "not-a-digest",
                recipeVersion: 1,
                mimeType: "image/png"
            )
        ) { error in
            XCTAssertEqual(error as? PublishedAssetCommitError, .invalidDigest("not-a-digest"))
        }
        XCTAssertThrowsError(
            try PublishedAssetRequest(
                candidateKey: "image#0",
                role: .image,
                bytes: Data(),
                contentDigest: String(repeating: "ab", count: 32),
                recipeVersion: 1,
                mimeType: "image/png"
            )
        ) { error in
            XCTAssertEqual(error as? PublishedAssetCommitError, .emptyBytes)
        }
    }
}
