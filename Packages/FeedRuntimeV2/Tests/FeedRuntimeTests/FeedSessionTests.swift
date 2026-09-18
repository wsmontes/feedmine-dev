import XCTest
import Foundation
import GRDB
@testable import FeedDomain
@testable import FeedRuntime
@testable import FeedStorage

/// The session end to end on a real on-disk database: warm restore with no composition, the cursor
/// surviving a relaunch, teardown releasing everything, and window churn not touching published rows.
///
/// The composition path is a spy, so "no Selection and no network on a warm start" is provable rather
/// than asserted in prose: the spy is the only outbound effect this module can start.
final class FeedSessionTests: XCTestCase {
    private var directory: URL!
    private var database: RuntimeDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedruntime-pr07-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
    }

    override func tearDownWithError() throws {
        database = nil
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private var repository: PublicationRepository { PublicationRepository(database: database) }

    /// Publishes one active edition with `count` frozen cards, through the real repository.
    @discardableResult
    private func publishEdition(
        count: Int,
        scopeKey: String = "main",
        revisionTag: String = "revision-a"
    ) throws -> (context: ContextKey, edition: EditionSnapshot, cards: [PublishedCardRecord]) {
        let context = try SessionFixture.context(scopeKey)
        let revision = try SessionFixture.revision(revisionTag)
        let draft = try repository.beginEdition(
            context: context,
            editorialRevision: revision,
            epoch: 1,
            seed: Data("edition-seed".utf8),
            successorOf: nil,
            at: SessionFixture.instant
        )
        let token = try repository.token(for: draft.editionID)
        let cards = try (0..<count).map { index in
            CardInsertRecord(
                frozen: try PublishedCardPayload.Frozen(
                    editionID: draft.editionID,
                    segmentOrdinal: 0,
                    absoluteOrdinal: index,
                    origin: PublishedOrigin(
                        originRecordID: try OriginRecordID(Int64(index + 1)),
                        originRevisionID: try OriginRevisionID(Int64(index + 1)),
                        sourceID: nil,
                        providerID: nil,
                        sourceDisplayName: "Source",
                        providerDisplayName: nil
                    ),
                    title: "Card \(index)",
                    primaryText: "Excerpt \(index)",
                    publishedAt: SessionFixture.instant,
                    publishedAtKind: .authored,
                    observationAt: SessionFixture.instant,
                    media: .none,
                    primaryAction: nil,
                    interactionSummary: nil,
                    renderContract: RenderContract.resolved(media: .none),
                    editorialRevision: revision,
                    publicationSchemaVersion: PublicationSchema.currentVersion
                ),
                assetReferences: []
            )
        }
        _ = try repository.commit(
            SegmentCommitRequest(
                token: token,
                segmentOrdinal: 0,
                absoluteOrdinalStart: 0,
                segmentSeed: Data("segment-seed".utf8),
                policyRevision: revision.digest,
                committedAt: SessionFixture.instant,
                activation: .activate(successorOf: nil),
                cards: cards,
                assets: [],
                mediaPreparations: [],
                pinnedRevisions: []
            )
        )
        let edition = try XCTUnwrap(try repository.edition(draft.editionID))
        return (context, edition, try repository.cards(in: draft.editionID))
    }

    private func makeSession(
        context: ContextKey,
        composer: SpySessionComposer,
        userActions: SpyUserActions = SpyUserActions(),
        clock: TestMonotonicClock = TestMonotonicClock(),
        windowConfiguration: FeedWindowConfiguration = .baseline
    ) throws -> FeedSession {
        FeedSession(
            state: FeedSessionState(
                stamp: SessionStamp(1),
                context: context,
                historyScope: .main,
                historyPolicy: try HistoryPolicy(
                    scope: .main,
                    applySeen: true,
                    showOverlay: true,
                    autoExclude: true,
                    version: 1
                ),
                renderEnvironment: try SessionFixture.renderEnvironment(),
                windowConfiguration: windowConfiguration
            ),
            repository: repository,
            checkpoints: SessionCheckpointStore(database: database),
            facts: ExposureFactStore(database: database),
            composer: composer,
            userActions: userActions,
            clock: clock,
            editorialClock: TestEditorialClock(now: SessionFixture.instant)
        )
    }

    /// Publishes a successor edition for the same context, reusing the canonical rows of the first.
    @discardableResult
    private func publishSuccessor(
        count: Int,
        after edition: EditionSnapshot,
        context: ContextKey
    ) throws -> EditionSnapshot {
        let draft = try repository.beginEdition(
            context: context,
            editorialRevision: edition.editorialRevision,
            epoch: edition.epoch + 1,
            seed: Data("successor-seed".utf8),
            successorOf: edition.editionID,
            at: SessionFixture.instant
        )
        let token = try repository.token(for: draft.editionID)
        let cards = try (0..<count).map { index in
            CardInsertRecord(
                frozen: try PublishedCardPayload.Frozen(
                    editionID: draft.editionID,
                    segmentOrdinal: 0,
                    absoluteOrdinal: index,
                    origin: PublishedOrigin(
                        originRecordID: try OriginRecordID(Int64(index + 100)),
                        originRevisionID: try OriginRevisionID(Int64(index + 100)),
                        sourceID: nil,
                        providerID: nil,
                        sourceDisplayName: "Source",
                        providerDisplayName: nil
                    ),
                    title: "Successor \(index)",
                    primaryText: "Excerpt \(index)",
                    publishedAt: SessionFixture.instant,
                    publishedAtKind: .authored,
                    observationAt: SessionFixture.instant,
                    media: .none,
                    primaryAction: nil,
                    interactionSummary: nil,
                    renderContract: RenderContract.resolved(media: .none),
                    editorialRevision: edition.editorialRevision,
                    publicationSchemaVersion: PublicationSchema.currentVersion
                ),
                assetReferences: []
            )
        }
        _ = try repository.commit(
            SegmentCommitRequest(
                token: token,
                segmentOrdinal: 0,
                absoluteOrdinalStart: 0,
                segmentSeed: Data("successor-segment".utf8),
                policyRevision: edition.editorialRevision.digest,
                committedAt: SessionFixture.instant,
                activation: .activate(successorOf: edition.editionID),
                cards: cards,
                assets: [],
                mediaPreparations: [],
                pinnedRevisions: []
            )
        )
        return try XCTUnwrap(try repository.edition(draft.editionID))
    }

    private func checkpoint(
        context: ContextKey,
        edition: EditionID,
        card: PublicationCardID,
        ordinal: Int,
        fraction: Double
    ) throws -> SessionCheckpoint {
        SessionCheckpoint(
            context: context,
            editionID: edition,
            anchor: try FeedWindowAnchor(
                editionID: edition,
                cardID: card,
                absoluteOrdinal: ordinal,
                offsetFraction: fraction
            ),
            renderEnvironmentRevision: try SessionFixture.renderEnvironment(),
            policyVersion: "1",
            updatedAtMs: 42
        )
    }

    // MARK: - Warm start (plan §19 #17)

    /// The named contract: a compatible edition restores the session with no selection and no network.
    ///
    /// The spy is the proof. `SpySessionComposer` is the only outbound effect this module can start, and
    /// it has no scripted composition at all: a single call would throw and leave the session degraded.
    func testCompatibleEditionRestoresWithoutSelection() async throws {
        let published = try publishEdition(count: 3)
        let anchorCard = published.cards[1].payload.cardID
        let store = SessionCheckpointStore(database: database)
        let saved = try checkpoint(
            context: published.context,
            edition: published.edition.editionID,
            card: anchorCard,
            ordinal: 1,
            fraction: 0.5
        )
        try store.save(saved)

        let composer = SpySessionComposer()
        let userActions = SpyUserActions()
        let session = try makeSession(context: published.context, composer: composer, userActions: userActions)

        let started = await session.start()
        let snapshot = try XCTUnwrap(started)

        XCTAssertEqual(snapshot.editionID, published.edition.editionID)
        XCTAssertEqual(snapshot.cards.map(\.id), published.cards.map(\.payload.cardID))
        XCTAssertEqual(snapshot.cards.map(\.absoluteOrdinal), [0, 1, 2])
        XCTAssertEqual(snapshot.contextKey, published.context.canonicalSerialization)
        XCTAssertEqual(
            composer.totalCallCount,
            0,
            "a warm restore performs no composition and no Selection"
        )
        XCTAssertEqual(userActions.callCount, 0, "a restore writes no durable user state")

        let state = await session.currentState()
        XCTAssertEqual(state.availability, .presenting)
        XCTAssertEqual(state.visibleEdition, published.edition.editionID)
        XCTAssertEqual(state.window.anchor, saved.anchor, "the cursor is where the reader left it")
        XCTAssertTrue(state.window.anchorIsMaterialized)
        XCTAssertEqual(state.window.viewport, FeedWindow.Viewport(firstVisibleOrdinal: 1, lastVisibleOrdinal: 1))
        XCTAssertEqual(state.editorialRevision, published.edition.editorialRevision)

        let statistics = await session.currentStatistics()
        XCTAssertEqual(statistics.restores, 1)
        XCTAssertEqual(statistics.restoreRefusals, 0)
        XCTAssertEqual(statistics.compositions, 0)
        await session.teardown()
    }

    /// A relaunch restores the same cursor: the checkpoint is durable, so the anchor is not a memory.
    func testCursorSurvivesARelaunchWithoutAnyComposition() async throws {
        let published = try publishEdition(count: 6)
        let store = SessionCheckpointStore(database: database)
        try store.save(
            try checkpoint(
                context: published.context,
                edition: published.edition.editionID,
                card: published.cards[4].payload.cardID,
                ordinal: 4,
                fraction: 0.75
            )
        )

        let first = try makeSession(context: published.context, composer: SpySessionComposer())
        _ = await first.start()
        await first.teardown()

        // A new session over the same database, as the next launch would be.
        let secondComposer = SpySessionComposer()
        let second = try makeSession(context: published.context, composer: secondComposer)
        let relaunched = await second.start()
        let snapshot = try XCTUnwrap(relaunched)

        XCTAssertEqual(snapshot.editionID, published.edition.editionID)
        let state = await second.currentState()
        XCTAssertEqual(state.window.anchor?.cardID, published.cards[4].payload.cardID)
        XCTAssertEqual(state.window.anchor?.absoluteOrdinal, 4)
        XCTAssertEqual(state.window.anchor?.offsetFraction, 0.75)
        XCTAssertEqual(secondComposer.totalCallCount, 0)
        await second.teardown()
    }

    /// With no edition at all, the session composes exactly once and presents what the composer froze.
    func testColdStartComposesOnceAndPresentsTheComposition() async throws {
        // The stored edition belongs to another scope, so this context is cold: the composer is the only
        // thing that can answer, and the session asks it exactly once.
        let context = try SessionFixture.context("cold")
        let published = try publishEdition(count: 2, scopeKey: "main")
        let composer = SpySessionComposer(
            compositions: [
                FeedSessionComposition(edition: published.edition, cards: published.cards)
            ]
        )
        let session = try makeSession(context: context, composer: composer)

        let cold = await session.start()
        let snapshot = try XCTUnwrap(cold)
        await session.drainPendingWork()

        XCTAssertEqual(snapshot.editionID, published.edition.editionID)
        XCTAssertEqual(composer.composeCalls, [context])
        XCTAssertEqual(composer.reasons, [.cold])
        let statistics = await session.currentStatistics()
        XCTAssertEqual(statistics.restoreRefusals, 1)
        XCTAssertEqual(statistics.compositions, 1)
        await session.teardown()
    }

    // MARK: - Teardown and exposure

    /// Teardown closes every open interval, persists what was confirmed, clears the material and
    /// releases what the composer held. Nothing is left running.
    func testTeardownClosesIntervalsPersistsFactsAndReleasesPins() async throws {
        let published = try publishEdition(count: 4)
        let composer = SpySessionComposer()
        let clock = TestMonotonicClock()
        let session = try makeSession(context: published.context, composer: composer, clock: clock)
        _ = await session.start()

        let firstCard = published.cards[0].payload.cardID
        await session.send(.cardVisibility(
            try ViewportObservation(cardID: firstCard, visibleFraction: 0.9, edge: .entered)
        ))
        await session.send(.cardVisibility(
            try ViewportObservation(cardID: firstCard, visibleFraction: 0.9, edge: .sample)
        ))
        await session.send(.opened(cardID: firstCard, operationID: "op-read-teardown"))
        await session.drainPendingWork()

        await session.teardown()

        let state = await session.currentState()
        XCTAssertTrue(state.closedConsumer)
        XCTAssertEqual(state.availability, .closed)
        XCTAssertEqual(state.window.referenceCount, 0)
        XCTAssertEqual(state.materialCount, 0)
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertTrue(state.pendingPage.isEmpty)

        let facts = ExposureFactStore(database: database)
        XCTAssertGreaterThan(try facts.factCount(), 0, "confirmed exposure is durable")
        let left = try XCTUnwrap(
            try database.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM exposure_fact WHERE event_type = 'viewportLeft'"
                )
            }
        )
        XCTAssertEqual(left["close_reason"] as String?, "sessionEnd")
        XCTAssertEqual(left["card_id"] as Int64?, firstCard.rawValue)
        let opened = try facts.fact(forKey: ExposureFact.key(
            type: .opened,
            editionID: published.edition.editionID,
            cardID: firstCard,
            scope: .main,
            visitOrdinal: 0,
            direction: nil,
            userStateOperationID: nil
        ))
        XCTAssertEqual(opened?.eventType, .opened)

        let statistics = await session.currentStatistics()
        XCTAssertGreaterThanOrEqual(statistics.pinReleases, 1, "teardown releases what it held")
        XCTAssertEqual(composer.releaseCalls, [[published.edition.editionID]])
        XCTAssertEqual(composer.composeCalls, [], "teardown never selects")
    }

    /// The screen's whole exposure vocabulary is one Bool: a row crossed its visibility threshold. The
    /// app states it as the contract's own entry edge at the policy's own `minVisibleFraction` — the
    /// bound the callback fired under — and this pins that the session records the visit from that
    /// statement alone, with no sample and no second edge. It is the only exposure signal the build has,
    /// so the fact store cannot be left needing one it never sends.
    func testTheVisibilityCallbacksEntryEdgeIsDurableOnItsOwn() async throws {
        let published = try publishEdition(count: 2)
        let session = try makeSession(context: published.context, composer: SpySessionComposer())
        _ = await session.start()
        await session.drainPendingWork()

        let card = published.cards[0].payload.cardID
        await session.send(.cardVisibility(try ViewportObservation(
            cardID: card,
            visibleFraction: ExposurePolicy.baseline.minVisibleFraction,
            edge: .entered
        )))
        await session.drainPendingWork()
        await session.teardown()

        let facts = ExposureFactStore(database: database)
        let entered = try facts.fact(forKey: ExposureFact.key(
            type: .viewportEntered,
            editionID: published.edition.editionID,
            cardID: card,
            scope: .main,
            visitOrdinal: 0,
            direction: nil,
            userStateOperationID: nil
        ))
        XCTAssertEqual(
            entered?.eventType,
            .viewportEntered,
            "the visit is durable from the entry edge the screen states, without a sample"
        )
        XCTAssertEqual(entered?.maxVisibleFraction, ExposurePolicy.baseline.minVisibleFraction)

        let statistics = await session.currentStatistics()
        XCTAssertGreaterThanOrEqual(statistics.exposureFactsPersisted, 1)
    }

    /// The reader opening a card is the explicit reader session ADR-007 D5 grants `read` for, and it
    /// travels the durable path a bookmark travels: the session calls the app's port, adopts the state
    /// the port confirms, paints it on the card it publishes, and records the `read` fact under the same
    /// operation id — which the store folds into `history_projection.read_at_ms` for that card and scope.
    ///
    /// Every assertion below is a stored row or a published card: the port's own log says the call
    /// happened (under the operation id the intent carried, which is what D7 keys the fact by), the fact
    /// row is read back by that same key, and the projection is read through the same store a policy
    /// would. Nothing here reads a call site.
    func testAnOpenMarksTheCardReadDurablyForThatCardAndScope() async throws {
        let published = try publishEdition(count: 2)
        let userActions = SpyUserActions()
        let session = try makeSession(
            context: published.context,
            composer: SpySessionComposer(),
            userActions: userActions
        )
        _ = await session.start()
        await session.drainPendingWork()

        let card = published.cards[0].payload.cardID
        await session.send(.opened(cardID: card, operationID: "op-read-1"))
        await session.drainPendingWork()

        XCTAssertEqual(
            userActions.readCalls,
            [SpyUserActions.ReadCall(cardID: card, operationID: "op-read-1")],
            "the open reaches the app's durable port under the operation id the intent carried"
        )
        let publishedSnapshot = await session.currentSnapshot()
        let painted = try XCTUnwrap(publishedSnapshot?.cards.first { $0.id == card })
        XCTAssertTrue(painted.isRead, "the published card carries the confirmed read state")

        await session.teardown()

        let facts = ExposureFactStore(database: database)
        let read = try facts.fact(forKey: ExposureFact.key(
            type: .read,
            editionID: published.edition.editionID,
            cardID: card,
            scope: .main,
            visitOrdinal: 0,
            direction: nil,
            userStateOperationID: "op-read-1"
        ))
        XCTAssertEqual(read?.eventType, .read, "the read is a durable fact, keyed by its operation id")
        XCTAssertEqual(read?.userStateOperationID, "op-read-1")

        let projection = try XCTUnwrap(
            try HistoryProjectionStore(database: database).projection(scope: .main, cardID: card)
        )
        XCTAssertNotNil(
            projection.readAtMs,
            "history_projection.read_at_ms is the read state a reader comes back to"
        )
        XCTAssertNil(projection.readClearedAtMs)

        // The other card of the same edition was never opened, so the fact is per card and not per visit.
        let untouched = published.cards[1].payload.cardID
        let other = try HistoryProjectionStore(database: database).projection(scope: .main, cardID: untouched)
        XCTAssertNil(other?.readAtMs ?? nil, "an unopened card on the same surface stays unread")
    }

    /// After teardown the session is inert, and the snapshot stream is finished instead of hanging.
    func testClosedSessionIsInertAndFinishesItsStream() async throws {
        let published = try publishEdition(count: 2)
        let composer = SpySessionComposer()
        let session = try makeSession(context: published.context, composer: composer)
        let stream = await session.snapshots()
        _ = await session.start()
        await session.teardown()

        await session.send(.refresh)
        await session.send(.opened(cardID: published.cards[0].payload.cardID, operationID: "op-read-closed"))
        await session.renderEnvironmentChanged(try SessionFixture.renderEnvironment(dynamicType: "xxLarge"))
        await session.catalogChangedPassively()
        await session.drainPendingWork()

        let statistics = await session.currentStatistics()
        XCTAssertEqual(statistics.compositions, 0, "a closed session composes nothing")
        XCTAssertEqual(composer.composeCallCount, 0, "a closed session selects nothing")
        XCTAssertEqual(composer.releaseCalls.count, 1, "and it released what it held, exactly once")

        var iterator = stream.makeAsyncIterator()
        var seen = 0
        while await iterator.next() != nil { seen += 1 }
        XCTAssertGreaterThanOrEqual(seen, 1, "the stream delivered the last snapshot and then finished")
    }

    /// A scroll schedules a local page read and starts no composition: the observation is small, and the
    /// replenishment is the runtime's own work (plan §11, I-20).
    func testViewportSchedulesALocalPageAndNeverComposes() async throws {
        let published = try publishEdition(count: 30)
        let composer = SpySessionComposer()
        let session = try makeSession(
            context: published.context,
            composer: composer,
            windowConfiguration: try FeedWindowConfiguration(
                maximumReferences: 8,
                decodedByteBudget: 1_000_000,
                margin: 2
            )
        )
        _ = await session.start()
        let tail = try await session.currentState().window.tailOrdinal

        // One observation: exactly one request, answered locally.
        await session.send(.viewportChanged(firstVisibleOrdinal: 0, lastVisibleOrdinal: 1, anchor: nil))
        let afterOne = await session.currentStatistics()
        XCTAssertEqual(afterOne.replenishmentsScheduled, 1)

        // A fling sends the same observation repeatedly. Work is bounded by the number of *tails* the
        // window has, never by the number of frames: each request is answered by exactly one local read
        // and the composer is never involved. (The strict "no second request for the same tail" rule is
        // pinned deterministically in FeedSessionReducerTests.)
        for _ in 0..<3 {
            await session.send(.viewportChanged(
                firstVisibleOrdinal: 0,
                lastVisibleOrdinal: 1,
                anchor: nil
            ))
        }
        await session.drainPendingWork()

        XCTAssertEqual(composer.composeCallCount, 0, "a scroll never selects")
        let statistics = await session.currentStatistics()
        XCTAssertLessThanOrEqual(statistics.replenishmentsScheduled, 4, "bounded by the tails, not by frames")
        XCTAssertEqual(statistics.pagesRead, statistics.replenishmentsScheduled, "one read per request")
        let state = await session.currentState()
        XCTAssertGreaterThan(state.window.tailOrdinal ?? -1, tail ?? -1, "the page extended the window")
        XCTAssertNil(state.window.anchor)
        await session.teardown()
    }

    /// Eviction of presentation objects is not a removal of published content: the published rows are
    /// byte-identical after a window churn that evicts and re-materializes.
    func testWindowChurnLeavesPublishedRowsUntouched() async throws {
        let published = try publishEdition(count: 40)
        let composer = SpySessionComposer()
        let session = try makeSession(
            context: published.context,
            composer: composer,
            windowConfiguration: try FeedWindowConfiguration(
                maximumReferences: 6,
                decodedByteBudget: 1_000_000,
                margin: 1
            )
        )
        _ = await session.start()

        let before = try publishedRows()
        XCTAssertFalse(before.isEmpty)

        for ordinal in stride(from: 0, to: 30, by: 3) {
            await session.send(.viewportChanged(
                firstVisibleOrdinal: ordinal,
                lastVisibleOrdinal: ordinal + 2,
                anchor: nil
            ))
            await session.drainPendingWork()
        }
        await session.send(.cardVisibility(
            try ViewportObservation(
                cardID: published.cards[0].payload.cardID,
                visibleFraction: 0.9,
                edge: .entered
            )
        ))
        await session.renderEnvironmentChanged(try SessionFixture.renderEnvironment(dynamicType: "accessibility1"))
        await session.drainPendingWork()

        XCTAssertEqual(try publishedRows(), before, "no published row changed")
        XCTAssertEqual(published.cards.count, 40, "no card was deleted")

        let state = await session.currentState()
        XCTAssertLessThanOrEqual(state.window.referenceCount, 6)
        XCTAssertLessThanOrEqual(state.materialCount, 6)
        await session.teardown()
    }

    /// A successor edition taking over closes the previous edition's intervals. Those closing facts
    /// belong to the edition they happened in and must still be persisted, not rejected as foreign
    /// (ADR-007 D11 rejects another session's edition, not the one this session was showing).
    func testEditionSwapPersistsThePreviousEditionsClosingFacts() async throws {
        let published = try publishEdition(count: 2)
        let composer = SpySessionComposer()
        let clock = TestMonotonicClock()
        let session = try makeSession(context: published.context, composer: composer, clock: clock)
        _ = await session.start()

        // The reader dwells on a card of the first edition.
        await session.send(.cardVisibility(
            try ViewportObservation(
                cardID: published.cards[0].payload.cardID,
                visibleFraction: 0.9,
                edge: .entered
            )
        ))
        clock.advance(1200)
        await session.send(.cardVisibility(
            try ViewportObservation(
                cardID: published.cards[0].payload.cardID,
                visibleFraction: 0.9,
                edge: .sample
            )
        ))
        await session.drainPendingWork()

        // The successor is published and activated, then an explicit refresh swaps it in.
        let successor = try publishSuccessor(count: 3, after: published.edition, context: published.context)
        composer.script(
            FeedSessionComposition(
                edition: successor,
                cards: try repository.cards(in: successor.editionID)
            )
        )
        await session.send(.refresh)
        await session.drainPendingWork()

        let state = await session.currentState()
        XCTAssertEqual(state.visibleEdition, successor.editionID, "the successor is visible")
        XCTAssertEqual(composer.composeCallCount, 1, "an explicit refresh is what swaps the edition")

        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT edition_id, event_type, close_reason FROM exposure_fact ORDER BY fact_id"
            )
        }
        XCTAssertTrue(
            rows.contains { ($0["edition_id"] as Int64?) == published.edition.editionID.rawValue },
            "the first edition's facts are durable"
        )
        XCTAssertTrue(
            rows.contains {
                ($0["event_type"] as String?) == "viewportLeft"
                    && ($0["close_reason"] as String?) == "editionSwap"
            },
            "the swap closed the interval with the reason that says why"
        )
        let statistics = await session.currentStatistics()
        XCTAssertEqual(statistics.exposureFactsDropped, 0, "no confirmed fact was dropped")
        await session.teardown()
    }

    /// A crash between flushes loses only what was never handed over: the confirmed facts survive, and
    /// nothing is invented for the dwell that was still in memory (ADR-007 D9, invariant H-14).
    func testCrashLosesOnlyUnconfirmedDwell() throws {
        let published = try publishEdition(count: 2)
        let edition = published.edition.editionID
        let durableCard = published.cards[0].payload.cardID
        let lostCard = published.cards[1].payload.cardID
        let clock = TestMonotonicClock()
        let store = ExposureFactStore(database: database)
        var tracker = ExposureTracker(
            edition: edition,
            scope: .main,
            clock: clock,
            configuration: .baseline
        )

        // Card A: entered and dwelled past the threshold, then handed over at a milestone.
        tracker.submitViewport(try ViewportObservation(
            cardID: durableCard,
            visibleFraction: 0.9,
            edge: .entered
        ))
        clock.advance(1200)
        tracker.submitViewport(try ViewportObservation(
            cardID: durableCard,
            visibleFraction: 0.9,
            edge: .sample
        ))
        let confirmed = tracker.drain()
        XCTAssertEqual(confirmed.map(\.type), [.viewportEntered, .seen])
        _ = try store.append(confirmed, policy: .baseline)

        // Card B: entered and dwelled, but the process dies before the batch is written.
        clock.advance(100)
        tracker.submitViewport(try ViewportObservation(
            cardID: lostCard,
            visibleFraction: 0.9,
            edge: .entered
        ))
        clock.advance(1200)
        tracker.submitViewport(try ViewportObservation(
            cardID: lostCard,
            visibleFraction: 0.9,
            edge: .sample
        ))
        XCTAssertEqual(tracker.pendingFactCount, 2, "the second card's facts were never confirmed")

        // The crash: the tracker is gone and the database is opened again, as the next launch would.
        tracker = ExposureTracker(edition: edition, scope: .main, clock: TestMonotonicClock(), configuration: .baseline)
        let reopened = try reopenDatabase()
        let rows = try reopened.read { db in
            try Row.fetchAll(db, sql: "SELECT card_id, event_type FROM exposure_fact ORDER BY fact_id")
        }
        XCTAssertEqual(rows.count, 2, "only the confirmed facts are durable")
        XCTAssertTrue(rows.allSatisfy { ($0["card_id"] as Int64?) == durableCard.rawValue })
        XCTAssertFalse(
            rows.contains { ($0["card_id"] as Int64?) == lostCard.rawValue },
            "no row is invented for dwell that was never confirmed"
        )
        let projections = try HistoryProjectionStore(database: reopened)
        XCTAssertNotNil(try projections.projection(scope: .main, cardID: durableCard))
        XCTAssertNil(try projections.projection(scope: .main, cardID: lostCard))
    }

    private func reopenDatabase() throws -> RuntimeDatabase {
        try database.pool.close()
        return try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
    }

    private func publishedRows() throws -> [String] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM published_card ORDER BY publication_card_id"
            ).map { row in
                Array(zip(row.columnNames, row.databaseValues))
                    .map { "\($0.0)=\($0.1)" }
                    .joined(separator: ",")
            }
        }
    }
}
