import XCTest
import GRDB
import UIKit
@testable import feedmine

/// Tests for CardPreparationCoordinator: deduplication, commit validation,
/// context guards, peek correctness, and readiness-driven promotion.
@MainActor
final class CardPreparationCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(id: String, title: String = "Title") -> FeedItem {
        FeedItem(
            id: id, sourceTitle: "Source", sourceURL: "https://example.com",
            category: "news", title: title, excerpt: "Excerpt",
            url: "https://example.com/\(id)", imageURL: nil,
            publishedAt: Date()
        )
    }

    private func makeContext(epoch: UInt64 = 1) -> FeedPresentationContext {
        FeedPresentationContext(
            epoch: epoch, mode: .main,
            filterGeneration: 0, presetGeneration: 0
        )
    }

    private func makeCoordinator() -> CardPreparationCoordinator {
        // A migração real, não uma `image_resolution` forjada: o schema falso tinha
        // colunas diferentes das do record e escondia o defeito de mapeamento do GRDB
        // (revisão S25).
        let db = try! DatabaseQueue()
        try! FeedStore.migrate(db)
        let store = MediaAssetStore(db: db)
        let policy = RunwayPolicy.forDevice()
        return CardPreparationCoordinator(mediaStore: store, policy: policy)
    }

    // MARK: - Deduplication: replaceEditorialSequence

    func test_replaceEditorialSequence_deduplicatesIntraBatchDuplicates() async {
        let coordinator = makeCoordinator()
        let items = [
            makeItem(id: "A"), makeItem(id: "B"),
            makeItem(id: "A"), makeItem(id: "C"),
            makeItem(id: "B")
        ]
        let ctx = makeContext()

        await coordinator.replaceEditorialSequence(items, context: ctx)

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 3, "Duplicate IDs within batch should be filtered to unique")
    }

    func test_replaceEditorialSequence_preservesFirstOccurrence() async {
        let coordinator = makeCoordinator()
        let items = [
            makeItem(id: "A", title: "First"),
            makeItem(id: "A", title: "Second")
        ]
        let ctx = makeContext()

        await coordinator.replaceEditorialSequence(items, context: ctx)

        // First occurrence of "A" is kept; second is dropped.
        // Since items have no images, they won't be render-ready yet.
        // But the editorial sequence should have only 1 item.
        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 1, "Only first occurrence should be kept")

        // `count == 1` alone accepted a silent inversion of the winner — a card
        // holding "Second" passed, because both duplicates have the same ID and the
        // same count. The prepared card carries the item, so it names the survivor.
        await coordinator.fillRunway(targetRenderReady: 1, context: ctx)
        let ready = await coordinator.waitForContiguousPrefix(
            minimumCount: 1, maximumCount: 1,
            deadline: ContinuousClock().now.advanced(by: .seconds(30)), context: ctx
        )
        XCTAssertEqual(
            ready.first?.item.title, "First",
            "the surviving card must be the first occurrence, not the last one seen"
        )
    }

    // MARK: - Deduplication: appendEditorialSequence

    func test_appendEditorialSequence_filtersExistingIDs() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A"), makeItem(id: "B")],
            context: ctx
        )

        await coordinator.appendEditorialSequence(
            [makeItem(id: "B"), makeItem(id: "C")],
            context: ctx
        )

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 3, "Only C should be added; B already exists")
    }

    func test_appendEditorialSequence_deduplicatesIntraBatch() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx
        )

        await coordinator.appendEditorialSequence(
            [makeItem(id: "B"), makeItem(id: "B"), makeItem(id: "C"), makeItem(id: "B")],
            context: ctx
        )

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 3, "Intra-batch duplicates in append should be filtered")
    }

    func test_appendEditorialSequence_rejectsWrongContext() async {
        let coordinator = makeCoordinator()
        let ctx1 = makeContext(epoch: 1)
        let ctx2 = makeContext(epoch: 2)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx1
        )

        await coordinator.appendEditorialSequence(
            [makeItem(id: "B")], context: ctx2
        )

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 1, "Append with wrong context should be ignored")
    }

    // MARK: - commitPublished validation

    func test_commitPublished_rejectsStaleContext() async {
        let coordinator = makeCoordinator()
        let ctx1 = makeContext(epoch: 1)
        let ctx2 = makeContext(epoch: 2)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx1
        )
        await coordinator.replaceEditorialSequence(
            [makeItem(id: "B")], context: ctx2
        )

        // Try to commit with the stale context (ctx1).
        let result = await coordinator.commitPublished(
            expectedIDs: ["A"], context: ctx1
        )
        XCTAssertFalse(result, "Commit with stale context should be rejected")
    }

    func test_commitPublished_rejectsMismatchedPrefix() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()
        // Items without images — none will be render-ready.
        // commitPublished should reject because the peek returns empty prefix,
        // not the expected IDs.
        let items = (0..<5).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)

        let result = await coordinator.commitPublished(
            expectedIDs: ["0", "1", "2"], context: ctx
        )
        XCTAssertFalse(
            result,
            "Commit with IDs not matching render-ready prefix should be rejected"
        )
    }

    func test_commitPublished_acceptsValidPrefix() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        // Since items have imageURL: nil, the coordinator will resolve them
        // as .none immediately (no image to fetch). Let's verify by
        // preparing them and then committing.
        let items = (0..<3).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)

        // fillRunway should prepare items. Since imageURL is nil, they'll
        // resolve to .none and become render-ready quickly.
        await coordinator.fillRunway(targetRenderReady: 3, context: ctx)

        // Wait for the condition the assertions are about — the contiguous prefix reaching
        // three render-ready cards — instead of a fixed 500ms. The old sleep turned a slow
        // preparation into a silent pass: the `guard` below returned without asserting anything.
        let ready = await coordinator.waitForContiguousPrefix(
            minimumCount: 3,
            maximumCount: 3,
            deadline: ContinuousClock().now.advanced(by: .seconds(30)),
            context: ctx
        )
        XCTAssertEqual(ready.count, 3, "all three image-less items must become render-ready within 30s")

        let peeked = await coordinator.peekRenderReadyPrefix(
            maximumCount: 3, context: ctx
        )
        XCTAssertEqual(peeked.count, 3, "the render-ready prefix must hold all three items")

        let result = await coordinator.commitPublished(
            expectedIDs: peeked.map(\.id), context: ctx
        )
        XCTAssertTrue(result, "Commit with matching prefix should succeed")
    }

    // MARK: - peekRenderReadyPrefix

    func test_peekRenderReadyPrefix_rejectsWrongContext() async {
        let coordinator = makeCoordinator()
        let ctx1 = makeContext(epoch: 1)
        let ctx2 = makeContext(epoch: 2)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx1
        )

        let cards = await coordinator.peekRenderReadyPrefix(
            maximumCount: 10, context: ctx2
        )
        XCTAssertTrue(cards.isEmpty, "Peek with wrong context should return empty")
    }

    func test_peekRenderReadyPrefix_isNonDestructive() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        let items = (0..<3).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)
        await coordinator.fillRunway(targetRenderReady: 3, context: ctx)
        // Readiness signal instead of a fixed 500ms: without three ready cards the
        // "same IDs on repeated calls" assertion could pass on two peeks that both saw nothing.
        let ready = await coordinator.waitForContiguousPrefix(
            minimumCount: 3,
            maximumCount: 3,
            deadline: ContinuousClock().now.advanced(by: .seconds(30)),
            context: ctx
        )
        XCTAssertEqual(ready.count, 3, "all three image-less items must become render-ready within 30s")

        let first = await coordinator.peekRenderReadyPrefix(
            maximumCount: 3, context: ctx
        )
        let second = await coordinator.peekRenderReadyPrefix(
            maximumCount: 3, context: ctx
        )

        XCTAssertEqual(
            first.map(\.id), second.map(\.id),
            "Peek must be non-destructive — same IDs on repeated calls"
        )
    }

    // MARK: - waitForContiguousPrefix

    func test_waitForContiguousPrefix_returnsImmediatelyWhenReady() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        let items = (0..<5).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)
        await coordinator.fillRunway(targetRenderReady: 5, context: ctx)
        // Establish the precondition by signal — five ready cards — before starting the clock:
        // the old 500ms sleep left it to luck whether anything was ready, and the test then
        // skipped its only assertion.
        let ready = await coordinator.waitForContiguousPrefix(
            minimumCount: 5, maximumCount: 5,
            deadline: ContinuousClock().now.advanced(by: .seconds(30)), context: ctx
        )
        XCTAssertEqual(ready.count, 5, "all five image-less items must become render-ready within 30s")

        let start = ContinuousClock().now
        let cards = await coordinator.waitForContiguousPrefix(
            minimumCount: 1, maximumCount: 5,
            deadline: ContinuousClock().now.advanced(by: .seconds(5)), context: ctx
        )
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(cards.count, 5, "an already-ready prefix must be returned whole")
        XCTAssertLessThan(
            elapsed, .seconds(1),
            "Should return near-instantly when cards are already ready"
        )
    }

    func test_waitForContiguousPrefix_returnsEmptyOnWrongContext() async {
        let coordinator = makeCoordinator()
        let ctx1 = makeContext(epoch: 1)
        let ctx2 = makeContext(epoch: 2)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx1
        )

        let deadline = ContinuousClock().now.advanced(by: .seconds(30))
        let cards = await coordinator.waitForContiguousPrefix(
            minimumCount: 1, maximumCount: 5, deadline: deadline, context: ctx2
        )
        XCTAssertTrue(cards.isEmpty, "Should return empty for wrong context")
    }

    // MARK: - editorialAheadCount

    func test_editorialAheadCount_decreasesAfterCommit() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        let items = (0..<5).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)
        await coordinator.fillRunway(targetRenderReady: 5, context: ctx)
        // Signal first: the commit below must act on a prefix that is actually ready, so wait
        // for it instead of sleeping a fixed 500ms and skipping the assertions when it was not.
        let ready = await coordinator.waitForContiguousPrefix(
            minimumCount: 5, maximumCount: 5,
            deadline: ContinuousClock().now.advanced(by: .seconds(30)), context: ctx
        )
        XCTAssertEqual(ready.count, 5, "all five image-less items must become render-ready within 30s")

        let before = await coordinator.editorialAheadCount
        XCTAssertEqual(before, 5, "All 5 items ahead of publish index")

        let peeked = await coordinator.peekRenderReadyPrefix(
            maximumCount: 5, context: ctx
        )
        XCTAssertEqual(peeked.count, 5, "the render-ready prefix must hold all five items")
        _ = await coordinator.commitPublished(
            expectedIDs: peeked.map(\.id), context: ctx
        )
        let after = await coordinator.editorialAheadCount
        XCTAssertEqual(
            after, 5 - peeked.count,
            "Ahead count should decrease by committed count"
        )
    }

    // MARK: - epoch guard

    func test_replaceEditorialSequence_rejectsOlderEpoch() async {
        let coordinator = makeCoordinator()
        let ctxNew = makeContext(epoch: 5)
        let ctxOld = makeContext(epoch: 3)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctxNew
        )
        // Try to install older epoch — should be rejected.
        await coordinator.replaceEditorialSequence(
            [makeItem(id: "B")], context: ctxOld
        )

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 1, "Older epoch should not replace newer one")
    }

    // MARK: - commitPublished O(1) advance

    func test_commitPublished_advancesByExactCount() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        let items = (0..<10).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)
        await coordinator.fillRunway(targetRenderReady: 10, context: ctx)
        // Wait for three render-ready cards — the precondition the commit below is about —
        // rather than sleeping 500ms and silently returning when they were not ready yet.
        let ready = await coordinator.waitForContiguousPrefix(
            minimumCount: 3, maximumCount: 3,
            deadline: ContinuousClock().now.advanced(by: .seconds(30)), context: ctx
        )
        XCTAssertEqual(ready.count, 3, "three image-less items must become render-ready within 30s")

        let peeked = await coordinator.peekRenderReadyPrefix(
            maximumCount: 3, context: ctx
        )
        XCTAssertEqual(peeked.count, 3, "the render-ready prefix must hold three items")

        let committed = await coordinator.commitPublished(
            expectedIDs: peeked.map(\.id), context: ctx
        )
        XCTAssertTrue(committed)

        let remaining = await coordinator.editorialAheadCount
        XCTAssertEqual(remaining, 7, "Should have 7 items remaining after committing 3")
    }
}

// MARK: - MediaAssetStore single-flight under cancellation

/// Lives in this file because the test target's project is not generated by XcodeGen: a new file
/// would need project.pbxproj surgery, and `xcodegen generate` rewrites hand-maintained keys in
/// `Info.plist` (it dropped `BGTaskSchedulerPermittedIdentifiers` and reset the build number when
/// tried). The class below is unrelated to the coordinator tests above it.
private actor WaitGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen { continuation.resume(); return }
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        let pending = waiter
        waiter = nil
        pending?.resume()
    }

    var opened: Bool { isOpen }
}

final class MediaAssetStoreSharedWaitTests: XCTestCase {

    /// The property that makes the single-flight usable under cancellation: the caller that leaves
    /// gets its answer **now**, while the work it was waiting for continues for the callers that
    /// stayed. `Task.value` does neither — it ignores cancellation, so the caller waited for the
    /// shared resolution (here: until the gate opens, i.e. for the safety timer) and the answer
    /// arrived late, with the limiter slot held until then.
    func test_cancelledWaiterReturnsBeforeSharedResolutionAndDoesNotCancelIt() async throws {
        let gate = WaitGate()
        let shared = Task<String, Error> {
            await gate.wait()
            return "resolved"
        }

        let stayer = Task { try await awaitSharedTaskRespectingCancellation(shared) }

        let leaverReturned = WaitGate()
        let leaver = Task<String, Error> {
            do {
                let value = try await awaitSharedTaskRespectingCancellation(shared)
                await leaverReturned.open()
                return value
            } catch {
                await leaverReturned.open()
                throw error
            }
        }

        // Let both waiters attach to the shared task before the cancellation lands.
        await Task.yield()

        // Whoever loses the race below must still end the test rather than stall the suite:
        // the target runs without test timeouts, so a hang here would hang the whole run.
        let safety = Task {
            try? await Task.sleep(for: .seconds(5))
            await gate.open()
        }

        leaver.cancel()
        await leaverReturned.wait()

        let waitedForSharedWork = await gate.opened
        XCTAssertFalse(
            waitedForSharedWork,
            "o waiter cancelado só voltou depois de a resolução compartilhada terminar"
        )

        await gate.open()
        let stayerValue = try await stayer.value
        XCTAssertEqual(stayerValue, "resolved", "quem espera deve receber o resultado")
        XCTAssertFalse(shared.isCancelled, "quem desiste não pode cancelar o trabalho dos outros")

        _ = try? await leaver.value
        safety.cancel()
    }
}

/// Contratos de persistência de imagem que a suíte não cobria: o round-trip do
/// `ImageResolutionRecord` contra o schema **real** (não uma tabela forjada) e a
/// regra de que um bitmap já em memória nunca é reportado como miss.
@MainActor
final class ImageResolutionPersistenceTests: XCTestCase {

    private func makeMigratedQueue() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try FeedStore.migrate(db)
        return db
    }

    private func insertFeedItem(id: String, into db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO feed_item
                      (id, source_url, source_title, region, category, title, excerpt, url,
                       published_at, fetched_at)
                    VALUES (?, 'https://example.com/feed', 'Source', 'world', 'news', 'Title',
                            'Excerpt', 'https://example.com/a', 0, 0)
                    """,
                arguments: [id]
            )
        }
    }

    private func makeRecord(cacheKey: String, width: Int, height: Int, bytes: Int) -> ImageResolutionRecord {
        ImageResolutionRecord(
            itemID: "item-1",
            candidateFingerprint: "fp",
            state: ImageResolutionOutcome.resolved.rawValue,
            cacheKey: cacheKey,
            resolvedURL: "https://example.com/i.png",
            pixelWidth: width,
            pixelHeight: height,
            byteCount: bytes,
            attemptCount: 1,
            lastAttemptAt: 1,
            nextRetryAt: nil,
            failureClass: ImageResolutionSource.directImageURL.rawValue,
            failureCode: nil,
            updatedAt: 1
        )
    }

    private func makePNG(width: Int, height: Int) -> Data {
        // Escala 1: sem isso o renderer desenha em 3× no simulador e o PNG sai
        // com o triplo dos pixels pedidos.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData()!
    }

    /// O record é gravado pelo caminho Codable do GRDB contra a tabela criada pela
    /// migração real. Se o mapeamento de tabela/colunas divergir do schema, `save`
    /// falha — e nada na suíte atual percebe, porque o único harness de
    /// MediaAssetStore forja uma `image_resolution` com outras colunas.
    func testImageResolutionRecordRoundTripsAgainstTheRealSchema() async throws {
        let db = try makeMigratedQueue()
        try insertFeedItem(id: "item-1", into: db)

        let cacheKey = "img_\(UUID().uuidString)"
        let record = makeRecord(cacheKey: cacheKey, width: 120, height: 60, bytes: 4096)
        try await db.write { db in
            try record.save(db)
        }

        let fetched = try await db.read { db in
            try ImageResolutionRecord
                .filter(ImageResolutionRecord.Columns.cacheKey == cacheKey)
                .fetchOne(db)
        }

        XCTAssertEqual(fetched?.itemID, "item-1")
        XCTAssertEqual(fetched?.pixelWidth, 120)
        XCTAssertEqual(fetched?.pixelHeight, 60)
        XCTAssertEqual(fetched?.byteCount, 4096)
        XCTAssertEqual(fetched?.state, ImageResolutionOutcome.resolved.rawValue)
    }

    /// O irmão `ImageRetryQueueRecord` é gravado por SQL cru hoje, mas o mapeamento
    /// tem de existir para o dia em que passe a usar as APIs de record do GRDB.
    func testImageRetryQueueRecordRoundTripsAgainstTheRealSchema() async throws {
        let db = try makeMigratedQueue()
        try insertFeedItem(id: "item-2", into: db)

        let record = ImageRetryQueueRecord(
            itemID: "item-2",
            state: "pending",
            retryCount: 0,
            nextRetryAt: 60,
            lastError: nil,
            createdAt: 1,
            updatedAt: 1
        )
        try await db.write { db in
            try record.save(db)
        }

        let fetched = try await db.read { db in
            try ImageRetryQueueRecord.fetchOne(db, key: "item-2")
        }
        XCTAssertEqual(fetched?.state, "pending")
        XCTAssertEqual(fetched?.nextRetryAt, 60)
    }

    /// `resolve` com o bitmap já em memória devolvia `nil` quando a leitura do
    /// metadado falhava — o card virava placeholder apesar da imagem pronta.
    func testResolveKeepsABitmapThatIsAlreadyInMemory() async throws {
        let db = try makeMigratedQueue()
        let store = MediaAssetStore(db: db)

        let cacheKey = "img_\(UUID().uuidString)"
        let data = makePNG(width: 64, height: 32)
        try await DiskImageCache().store(data, key: cacheKey)

        let decoded = await store.decodedImage(for: cacheKey)
        XCTAssertNotNil(decoded, "a imagem semeada precisa decodificar, senão o teste não prova nada")

        // (1) Sem linha de metadado: o bitmap em memória continua sendo um asset resolvido.
        let withoutRow = await store.resolve(
            request: ImageResolutionRequest(itemID: "item-1", url: nil, cacheKey: cacheKey, source: .directImageURL)
        )
        XCTAssertNotNil(withoutRow, "bitmap já em memória não pode ser reportado como miss")
        XCTAssertEqual(withoutRow?.pixelWidth, 64)
        XCTAssertEqual(withoutRow?.pixelHeight, 32)
        XCTAssertEqual(withoutRow?.byteCount, data.count)

        // (2) Com a linha gravada, o metadado persistido manda (não a reconstrução).
        try insertFeedItem(id: "item-1", into: db)
        let persisted = makeRecord(cacheKey: cacheKey, width: 7, height: 9, bytes: 11)
        try await db.write { db in
            try persisted.save(db)
        }

        let withRow = await store.resolve(
            request: ImageResolutionRequest(itemID: "item-1", url: nil, cacheKey: cacheKey, source: .directImageURL)
        )
        XCTAssertEqual(withRow?.pixelWidth, 7, "a linha persistida deve vencer a reconstrução")
        XCTAssertEqual(withRow?.pixelHeight, 9)
        XCTAssertEqual(withRow?.byteCount, 11)

        await DiskImageCache().remove(key: cacheKey)
    }
}

// MARK: - ImageResolutionQueue: retry scheduling and lease recovery

/// Records what the queue reports. Only used as a `configure(delegate:)`
/// argument here — none of these tests depend on a callback.
@MainActor
private final class RecordingImageResolutionDelegate: ImageResolutionQueueDelegate {
    private(set) var resolvedIDs: [String] = []
    private(set) var exhaustedIDs: [String] = []

    func imageResolutionQueue(didResolveImageFor itemID: String) { resolvedIDs.append(itemID) }
    func imageResolutionQueue(didExhaustRetriesFor itemID: String) { exhaustedIDs.append(itemID) }
}

/// S01. The queue's poll loop asked "is anything eligible *right now*" and, on
/// `no`, stopped — so the row it had just rescheduled 30 s (up to 6 h) into the
/// future sat in the table with nobody to wake up for it, and a row left
/// `in_progress` by a run that died mid-resolution was selected by no query at
/// all. Both tests reach the row only if the loop gets to it, and neither
/// touches the network: the item exists but offers no artwork path, so a
/// completed attempt always ends in a terminal write (`failed`).
@MainActor
final class ImageResolutionQueueSchedulingTests: XCTestCase {

    private func makeMigratedQueue() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try FeedStore.migrate(db)
        return db
    }

    /// An item with no artwork source at all: `url` is not an http(s) URL, so
    /// `canResolveArticleImage` is false, and `image_url` is absent. `resolve`
    /// therefore finishes with `markFailed` — the state change these tests watch.
    private func insertArtworklessItem(id: String, into db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO feed_item
                      (id, source_url, source_title, region, category, title, excerpt, url,
                       published_at, fetched_at)
                    VALUES (?, 'https://example.com/feed', 'Source', 'world', 'news', 'Title',
                            'Excerpt', '', 0, 0)
                    """,
                arguments: [id]
            )
        }
    }

    private func insertQueueRow(
        id: String, state: String, nextRetryAt: Int, updatedAt: Int, into db: DatabaseQueue
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO image_retry_queue
                      (item_id, state, retry_count, next_retry_at, created_at, updated_at)
                    VALUES (?, ?, 3, ?, ?, ?)
                    """,
                arguments: [id, state, nextRetryAt, updatedAt, updatedAt]
            )
        }
    }

    private func state(of id: String, in db: DatabaseQueue) async throws -> String? {
        try await db.read { db in
            try String.fetchOne(
                db, sql: "SELECT state FROM image_retry_queue WHERE item_id = ?",
                arguments: [id]
            )
        }
    }

    /// Bounded wait: this target runs without `-test-timeouts-enabled`, so a wait
    /// without a deadline would hang the whole run instead of failing one test.
    private func waitForState(
        _ expected: String, of id: String, in db: DatabaseQueue, timeout: TimeInterval = 15
    ) async throws -> String? {
        let deadline = ContinuousClock().now.advanced(by: .seconds(timeout))
        var current = try await state(of: id, in: db)
        while current != expected, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            current = try await state(of: id, in: db)
        }
        return current
    }

    /// The retry date is a second away: the loop has to wait for it and come
    /// back. The old loop found nothing eligible, cleared its task and left the
    /// row `pending` forever.
    func test_wakesAtTheScheduledRetryDateInsteadOfAbandoningTheRow() async throws {
        let db = try makeMigratedQueue()
        let itemID = "ghost-\(UUID().uuidString)"
        try insertArtworklessItem(id: itemID, into: db)
        let now = Int(Date().timeIntervalSince1970)
        try insertQueueRow(id: itemID, state: "pending", nextRetryAt: now + 1, updatedAt: now, into: db)

        let queue = ImageResolutionQueue(db: db)
        await queue.configure(delegate: RecordingImageResolutionDelegate())
        defer { Task { await queue.stop() } }

        let finalState = try await waitForState("failed", of: itemID, in: db)
        XCTAssertEqual(
            finalState, "failed",
            "a linha pendente com data futura nunca foi acordada pelo poll"
        )
    }

    /// A run that died between writing `in_progress` and writing the outcome
    /// leaves a row no query selects: reopening the app must put it back in the
    /// queue instead of losing the item's retry.
    func test_recoversAnInProgressRowLeftBehindAtStartup() async throws {
        let db = try makeMigratedQueue()
        let itemID = "orphan-\(UUID().uuidString)"
        try insertArtworklessItem(id: itemID, into: db)
        let now = Int(Date().timeIntervalSince1970)
        try insertQueueRow(id: itemID, state: "in_progress", nextRetryAt: now, updatedAt: now, into: db)

        let queue = ImageResolutionQueue(db: db)
        await queue.configure(delegate: RecordingImageResolutionDelegate())
        defer { Task { await queue.stop() } }

        let finalState = try await waitForState("failed", of: itemID, in: db)
        XCTAssertEqual(
            finalState, "failed",
            "a linha in_progress órfã nunca voltou para a fila"
        )
    }
}

// MARK: - S06: retry of an already published card must not re-enter the runway

/// Records that the coordinator asked the store to heal a published card.
private final class MediaUpgradeRecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var upgrades = 0

    func record() {
        lock.lock()
        upgrades += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return upgrades
    }
}

/// S06 with the order controlled: the card is published **first**, and only then
/// does the retry for that same item finish.
///
/// `storeResolved`/`storeRenderReady` accepted that late write unconditionally,
/// so an ID that `commitPublished` had already removed from `orderedItems` —
/// and that `trimToPublishedIndex()` had removed from the maps — came back into
/// `resolvedByID`/`renderReadyByID`. `fillRunway` reads
/// `renderReadyByID.count` as its ready depth, so an orphan entry counted as
/// runway that no composition could ever publish.
///
/// The order does not depend on timing luck: the item's deadline (2 ms) is far
/// shorter than the disk resolution of the 9 MP image seeded for its URL, so the
/// placeholder card is ready — and published — while that resolution is still
/// running. The retry is what must *not* be lost: it still reaches
/// `mediaUpgradeHandler` (the recorder proves it ran), which is the path that
/// heals a published card in place. Only the runway write is refused.
@MainActor
final class CardPreparationPublishedRetryTests: XCTestCase {

    private func makePNG(side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        )
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.pngData()!
    }

    func test_lateRetryForAPublishedCardDoesNotReenterTheRunway() async throws {
        // 9 MP on disk, no network anywhere in this test: the image is served by
        // the same disk cache the resolution path reads first.
        let imageURL = URL(string: "https://cdn.example.com/slow-\(UUID().uuidString).png")!
        let cacheKey = ImageCacheKey.forURL(imageURL)
        try await DiskImageCache().store(makePNG(side: 3000), key: cacheKey)
        defer { Task { await DiskImageCache().remove(key: cacheKey) } }

        let db = try DatabaseQueue()
        try FeedStore.migrate(db)
        let store = MediaAssetStore(db: db)
        var policy = RunwayPolicy()
        // Short enough that a 9 MP disk resolution cannot win the race.
        policy.initialViewportDeadline = .milliseconds(2)
        let coordinator = CardPreparationCoordinator(mediaStore: store, policy: policy)

        let upgrades = MediaUpgradeRecorderBox()
        await coordinator.setMediaUpgradeHandler { _ in upgrades.record() }

        let item = FeedItem(
            id: "card-1", sourceTitle: "Source", sourceURL: "https://example.com",
            category: "news", title: "Title", excerpt: "Excerpt",
            url: "https://example.com/card-1", imageURL: imageURL.absoluteString,
            publishedAt: Date()
        )
        let ctx = FeedPresentationContext(
            epoch: 1, mode: .main, filterGeneration: 0, presetGeneration: 0
        )

        await coordinator.replaceEditorialSequence([item], context: ctx)
        await coordinator.fillRunway(targetRenderReady: 1, context: ctx)

        // 1. The card exists and goes out without artwork — the state the retry
        //    then works on.
        let ready = await coordinator.waitForContiguousPrefix(
            minimumCount: 1, maximumCount: 1,
            deadline: ContinuousClock().now.advanced(by: .seconds(15)), context: ctx
        )
        guard let card = ready.first else {
            return XCTFail("o card precisa existir antes de o retry terminar")
        }
        if case .image = card.media {
            XCTFail("o card saiu com a imagem: o deadline curto não foi exercido e o retry não é o caminho testado")
        }

        // 2. Publish it. From here on the ID is out of `orderedItems`.
        let committed = await coordinator.commitPublished(expectedIDs: [card.id], context: ctx)
        XCTAssertTrue(committed, "o placeholder precisa ser publicado antes do retry")

        // 3. Let the late retry finish (bounded wait: the target runs without test timeouts).
        let waitDeadline = ContinuousClock().now.advanced(by: .seconds(15))
        while upgrades.count == 0, ContinuousClock().now < waitDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(
            upgrades.count, 0,
            "o retry tardio precisa ter resolvido e pedido o heal do card publicado"
        )

        // 4. What the fix is about: no runway entry for a card that is already out.
        let diagnostics = await coordinator.editorialDiagnostics
        XCTAssertTrue(
            diagnostics.contains("ready=0 "),
            "o retry tardio recriou uma entrada de runway para um card publicado: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.contains("resolved=0 "),
            "o retry tardio recriou uma entrada resolvida para um card publicado: \(diagnostics)"
        )
    }
}
