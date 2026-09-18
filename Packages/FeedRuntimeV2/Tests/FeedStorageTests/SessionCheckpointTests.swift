import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// The session cursor and the exposure log on a real database: what a checkpoint stores, what a flush
/// is allowed to write, and what the ADR-007 D12 matrix means for the projections policy reads.
///
/// The publication fixtures are the ones PR-06 landed, so a fact is always attached to a card that was
/// really published: `ux_exposure_fact_key`, the composite foreign key and the projection rules are all
/// decided by SQLite, not by a mock.
final class SessionCheckpointTests: RuntimeV2TestCase {
    // MARK: - Fixtures

    /// Publishes `cardCount` cards as the first (activating) segment of a new edition and returns the
    /// frozen records, which is what a checkpoint and a fact need to name a real card.
    @discardableResult
    private func publishEdition(
        cardCount: Int = 3,
        scopeKey: String = "main",
        revisionTag: String = "revision-a"
    ) throws -> (context: ContextKey, edition: EditionSnapshot, cards: [PublishedCardRecord]) {
        let source = try ensureSource("catalog:alpha", displayTitle: "Alpha")
        let rows = try (0..<cardCount).map { index in
            try insertSupplyRow(
                objectKey: "item-\(scopeKey)-\(index)",
                sourceIDs: [source],
                headline: "Headline \(index)",
                summary: "Excerpt \(index)",
                publishedAtClaim: TestInstant.epochMilliseconds,
                observedAt: TestInstant.epochMilliseconds
            )
        }
        let context = try planContext(scopeKey)
        let edition = try openDraft(context: context, revisionTag: revisionTag)
        let cards = try rows.enumerated().map { index, row in
            CardInsertRecord(
                frozen: try frozenCard(
                    edition: edition,
                    segmentOrdinal: 0,
                    absoluteOrdinal: index,
                    record: row,
                    title: "Headline \(index)",
                    primaryText: "Excerpt \(index)",
                    sourceDisplayName: "Alpha",
                    sourceID: source,
                    publishedAt: TestInstant.epoch,
                    publishedAtKind: .authored,
                    revisionTag: revisionTag
                ),
                assetReferences: []
            )
        }
        _ = try publish(
            repositories(),
            token: edition.token,
            cards: cards,
            activation: .activate(successorOf: nil),
            pinned: try rows.map { try OriginRevisionID($0.revisionID) }
        )
        return (context, edition, try repositories().cards(in: edition.editionID))
    }

    private func checkpoint(
        context: ContextKey,
        edition: EditionID,
        card: PublicationCardID,
        ordinal: Int,
        fraction: Double = 0.25
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
            renderEnvironmentRevision: try RenderEnvironmentRevision(
                layoutWidthClass: "compact",
                dynamicTypeSize: "large",
                localeIdentifier: "pt_BR",
                textDirection: "ltr",
                displayScale: 3
            ),
            policyVersion: "1",
            updatedAtMs: 1_000
        )
    }

    private func seenFact(
        edition: EditionID,
        card: PublicationCardID,
        scope: HistoryScope = .main,
        visit: Int = 0,
        at: Int64 = 100,
        dwell: Int64 = 1200
    ) throws -> ExposureFact {
        try ExposureFact(
            type: .seen,
            editionID: edition,
            cardID: card,
            scope: scope,
            visitOrdinal: visit,
            bootSessionID: "boot-1",
            observedAtMs: at,
            dwellMs: dwell,
            maxVisibleFraction: 0.9,
            policyVersion: ExposurePolicy.baseline.version
        )
    }

    private func enteredFact(
        edition: EditionID,
        card: PublicationCardID,
        scope: HistoryScope = .main,
        visit: Int = 0,
        at: Int64 = 0
    ) throws -> ExposureFact {
        try ExposureFact(
            type: .viewportEntered,
            editionID: edition,
            cardID: card,
            scope: scope,
            visitOrdinal: visit,
            bootSessionID: "boot-1",
            observedAtMs: at,
            maxVisibleFraction: 0.9,
            policyVersion: ExposurePolicy.baseline.version
        )
    }

    private func store() -> ExposureFactStore { ExposureFactStore(database: database) }
    private func history() -> HistoryProjectionStore { HistoryProjectionStore(database: database) }

    private func mainPolicy() throws -> HistoryPolicy {
        try HistoryPolicy(scope: .main, applySeen: true, showOverlay: true, autoExclude: true, version: 1)
    }

    private func bookmarkPolicy() throws -> HistoryPolicy {
        try HistoryPolicy(
            scope: .bookmark(listKey: nil),
            applySeen: false,
            showOverlay: true,
            autoExclude: false,
            version: 1
        )
    }

    private func sourcePolicy(_ sourceID: SourceID) throws -> HistoryPolicy {
        try HistoryPolicy(scope: .source(sourceID), applySeen: false, showOverlay: true, autoExclude: false, version: 1)
    }

    // MARK: - The cursor

    func testCheckpointRoundTripsThroughDiskAndSurvivesReopen() throws {
        let published = try publishEdition(cardCount: 4)
        let store = SessionCheckpointStore(database: database)
        let saved = try checkpoint(
            context: published.context,
            edition: published.edition.editionID,
            card: published.cards[2].payload.cardID,
            ordinal: 2,
            fraction: 0.75
        )
        XCTAssertTrue(try store.save(saved), "the first write stores the cursor")
        XCTAssertFalse(try store.save(saved), "writing the same cursor twice is a no-op")

        let reopened = try reopenDatabase()
        let reopenedStore = SessionCheckpointStore(database: reopened)
        let loaded = try XCTUnwrap(try reopenedStore.load(context: published.context))
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded.anchor.cardID, published.cards[2].payload.cardID)
        XCTAssertEqual(loaded.anchor.absoluteOrdinal, 2)
        XCTAssertEqual(loaded.anchor.offsetFraction, 0.75)
        XCTAssertEqual(loaded.renderEnvironmentRevision, saved.renderEnvironmentRevision)
        XCTAssertEqual(loaded.policyVersion, "1")

        // A different context has its own cursor, and clearing one leaves the other alone.
        let other = try planContext("secondary")
        try reopenedStore.save(try checkpoint(
            context: other,
            edition: published.edition.editionID,
            card: published.cards[0].payload.cardID,
            ordinal: 0
        ))
        XCTAssertEqual(try reopenedStore.storedCount(), 2)
        XCTAssertTrue(try reopenedStore.clear(context: other))
        XCTAssertNil(try reopenedStore.load(context: other))
        XCTAssertNotNil(try reopenedStore.load(context: published.context))
    }

    /// The cursor names a card of its own edition: the composite foreign key refuses anything else, so a
    /// stale ordinal from another edition cannot become a cursor.
    func testCheckpointRefusesACardOfAnotherEdition() throws {
        let first = try publishEdition(cardCount: 2, scopeKey: "main")
        let second = try publishEdition(cardCount: 2, scopeKey: "secondary", revisionTag: "revision-b")
        XCTAssertNotEqual(first.edition.editionID, second.edition.editionID)

        let store = SessionCheckpointStore(database: database)
        XCTAssertThrowsError(
            try store.save(try checkpoint(
                context: first.context,
                edition: first.edition.editionID,
                card: second.cards[0].payload.cardID,
                ordinal: 0
            ))
        ) { error in
            XCTAssertTrue("\(error)".contains("FOREIGN KEY constraint failed"), "got \(error)")
        }
        // The session checkpoint the cursor points at must also exist.
        XCTAssertThrowsError(
            try store.save(try checkpoint(
                context: first.context,
                edition: try EditionID(9_999),
                card: first.cards[0].payload.cardID,
                ordinal: 0
            ))
        )
        XCTAssertEqual(try store.storedCount(), 0)
    }

    // MARK: - The flush contract

    /// A flush is one transaction over the facts and the projections, and a replay changes nothing.
    func testFlushIsIdempotentIncludingTheProjections() throws {
        let published = try publishEdition(cardCount: 2)
        let edition = published.edition.editionID
        let card = published.cards[0].payload.cardID
        let batch = [
            try enteredFact(edition: edition, card: card),
            try seenFact(edition: edition, card: card),
            try ExposureFact(
                type: .opened,
                editionID: edition,
                cardID: card,
                scope: .main,
                bootSessionID: "boot-1",
                observedAtMs: 150,
                policyVersion: ExposurePolicy.baseline.version
            ),
        ]

        let first = try store().append(batch, policy: .baseline, wallClockMs: 1_700_000_000_000)
        XCTAssertEqual(first.insertedCount, 3)
        XCTAssertEqual(first.replayCount, 0)
        XCTAssertFalse(first.isRejected)
        XCTAssertEqual(try rowCount("exposure_fact"), 3)

        let projectionAfterFirst = try history().projection(scope: .main, cardID: card)
        XCTAssertEqual(projectionAfterFirst?.visitCount, 1)
        XCTAssertEqual(projectionAfterFirst?.lastSeenAtMs, 100)
        XCTAssertEqual(projectionAfterFirst?.openedAtMs, 150)
        XCTAssertEqual(projectionAfterFirst?.firstSeenAtMs, 100)

        let replay = try store().append(batch, policy: .baseline, wallClockMs: 1_700_000_000_001)
        XCTAssertEqual(replay.insertedCount, 0)
        XCTAssertEqual(replay.replayCount, 3)
        XCTAssertEqual(try rowCount("exposure_fact"), 3, "a replayed flush writes no row")

        let projectionAfterReplay = try history().projection(scope: .main, cardID: card)
        XCTAssertEqual(projectionAfterReplay, projectionAfterFirst, "and it changes no projection")
        XCTAssertEqual(try store().factCount(), 3)
    }

    /// A revisit is a new visit: the projection counts it, and `seen` stays idempotent per scope/card.
    func testRevisitUpdatesTheProjectionWithoutDuplicatingTheExclusion() throws {
        let published = try publishEdition(cardCount: 2)
        let edition = published.edition.editionID
        let card = published.cards[1].payload.cardID

        _ = try store().append(
            [
                try enteredFact(edition: edition, card: card, visit: 0, at: 0),
                try seenFact(edition: edition, card: card, visit: 0, at: 1200),
            ],
            policy: .baseline
        )
        _ = try store().append(
            [
                try enteredFact(edition: edition, card: card, visit: 1, at: 60_000),
                try seenFact(edition: edition, card: card, visit: 1, at: 61_200),
            ],
            policy: .baseline
        )

        try history().declare(try mainPolicy())
        let projection = try XCTUnwrap(try history().projection(scope: .main, cardID: card))
        XCTAssertEqual(projection.visitCount, 2)
        XCTAssertEqual(projection.lastVisitOrdinal, 1)
        XCTAssertEqual(projection.firstSeenAtMs, 1200)
        XCTAssertEqual(projection.lastSeenAtMs, 61_200)
        XCTAssertEqual(try history().exclusions(scope: .main), [card], "one row, one exclusion")
    }

    /// A stale flush writes nothing at all (ADR-007 D11, invariant H-13).
    func testStaleFlushWritesNothing() throws {
        let published = try publishEdition(cardCount: 2)
        let edition = published.edition.editionID
        let card = published.cards[0].payload.cardID
        let batch = [try seenFact(edition: edition, card: card)]

        let staleSession = try store().append(
            batch,
            policy: .baseline,
            guard: ExposureFlushGuard(
                sessionStamp: SessionStamp(1),
                currentSessionStamp: SessionStamp(2),
                acceptedEditions: [edition]
            )
        )
        XCTAssertTrue(staleSession.isRejected)
        XCTAssertEqual(staleSession.insertedCount, 0)
        XCTAssertEqual(try rowCount("exposure_fact"), 0)

        let staleEdition = try store().append(
            batch,
            policy: .baseline,
            guard: ExposureFlushGuard(
                sessionStamp: SessionStamp(2),
                currentSessionStamp: SessionStamp(2),
                acceptedEditions: [try EditionID(9_999)]
            )
        )
        XCTAssertEqual(staleEdition.rejection, .unknownEdition(edition))
        XCTAssertEqual(try rowCount("exposure_fact"), 0)

        // The projections were not touched either.
        XCTAssertEqual(try history().projection(scope: .main, cardID: card), nil)
        XCTAssertEqual(try rowCount("history_projection"), 0)

        // The same batch under the current session is accepted.
        let accepted = try store().append(
            batch,
            policy: .baseline,
            guard: ExposureFlushGuard(
                sessionStamp: SessionStamp(2),
                currentSessionStamp: SessionStamp(2),
                acceptedEditions: [edition]
            )
        )
        XCTAssertEqual(accepted.insertedCount, 1)
        XCTAssertFalse(accepted.isRejected)
    }

    /// A policy version is immutable, and a fact can only name a version that was declared.
    func testPolicyVersionIsImmutableAndRequired() throws {
        let published = try publishEdition(cardCount: 1)
        let card = published.cards[0].payload.cardID
        let changed = try ExposurePolicy(
            version: ExposurePolicy.baseline.version,
            minVisibleFraction: 0.8,
            minDwellMs: 1000,
            coalesceWindowMs: 75,
            flushFactCount: 20,
            flushIntervalMs: 500
        )
        try store().declare(.baseline, createdAtMs: 0)
        XCTAssertThrowsError(try store().declare(changed, createdAtMs: 0)) { error in
            XCTAssertEqual(error as? ExposureStoreError, .policyVersionChanged(ExposurePolicy.baseline.version))
        }

        let undeclared = try ExposureFact(
            type: .seen,
            editionID: published.edition.editionID,
            cardID: card,
            scope: .main,
            bootSessionID: "boot-1",
            observedAtMs: 10,
            dwellMs: 1200,
            policyVersion: "exposure-v9"
        )
        XCTAssertThrowsError(try store().append([undeclared], policy: .baseline)) { error in
            XCTAssertTrue("\(error)".contains("FOREIGN KEY constraint failed"), "got \(error)")
        }
        XCTAssertEqual(try rowCount("exposure_fact"), 0)
    }

    /// A fact names a card of the edition it claims: nothing can attach exposure to a card that was
    /// never published in that edition (invariant H-02 enforced by the schema).
    func testFactRefusesACardOfAnotherEdition() throws {
        let first = try publishEdition(cardCount: 2, scopeKey: "main")
        let second = try publishEdition(cardCount: 2, scopeKey: "secondary", revisionTag: "revision-b")

        XCTAssertThrowsError(
            try store().append(
                [try seenFact(edition: first.edition.editionID, card: second.cards[0].payload.cardID)],
                policy: .baseline
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("FOREIGN KEY constraint failed"), "got \(error)")
        }
        XCTAssertEqual(try rowCount("exposure_fact"), 0)

        // A `seen` without observed dwell is refused by the schema itself, not only by the type: the
        // CHECK is the last line of defence when any other writer reaches the table (invariant H-01).
        try store().declare(.baseline, createdAtMs: 0)
        XCTAssertThrowsError(
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO exposure_fact (
                        fact_key, edition_id, card_id, event_type, scope, scope_ref, visit_ordinal,
                        boot_session_id, observed_at_ms, dwell_ms, policy_version
                    ) VALUES (?, ?, ?, 'seen', 'main', '', 0, 'boot-1', 10, NULL, ?)
                    """, arguments: [
                    "raw-seen-without-dwell",
                    first.edition.editionID.rawValue,
                    first.cards[0].payload.cardID.rawValue,
                    ExposurePolicy.baseline.version,
                ])
            }
        ) { error in
            XCTAssertTrue("\(error)".contains("CHECK constraint failed"), "got \(error)")
        }
        XCTAssertEqual(try rowCount("exposure_fact"), 0)
    }

    /// The stored fact keeps the monotonic instant and the boot session that produced it, and the wall
    /// clock is diagnostic only (ADR-007 D15).
    func testFactsKeepTheMonotonicInstantAndItsBootSession() throws {
        let published = try publishEdition(cardCount: 1)
        let fact = try seenFact(
            edition: published.edition.editionID,
            card: published.cards[0].payload.cardID,
            at: 42_000
        )
        _ = try store().append([fact], policy: .baseline, wallClockMs: 1_700_000_000_000)

        let stored = try XCTUnwrap(try store().fact(forKey: fact.factKey))
        XCTAssertEqual(stored.observedAtMs, 42_000)
        XCTAssertEqual(stored.bootSessionID, "boot-1")
        XCTAssertEqual(stored.dwellMs, 1200)
        XCTAssertEqual(stored.maxVisibleFraction, 0.9)
        XCTAssertEqual(stored.scopeName, "main")
        XCTAssertEqual(stored.scopeRef, "")
        XCTAssertEqual(
            try scalar("SELECT wall_clock_ms FROM exposure_fact"),
            1_700_000_000_000,
            "the wall clock is recorded for diagnostics"
        )
    }

    // MARK: - HistoryScope (plan §19 #34)

    /// The named contract: a card seen in Main is excluded from Main and from nowhere else, and a
    /// bookmark survives every exposure fact.
    func testMainExposureDoesNotHideBookmarkOrSourceHistory() throws {
        let published = try publishEdition(cardCount: 3)
        let edition = published.edition.editionID
        let seenInMain = published.cards[0].payload.cardID
        let bookmarked = published.cards[1].payload.cardID
        let sourceID = try SourceID(1)

        let bookmarkScope = HistoryScope.bookmark(listKey: nil)
        let sourceScope = HistoryScope.source(sourceID)
        try history().declare(try mainPolicy())
        try history().declare(try bookmarkPolicy())
        try history().declare(try sourcePolicy(sourceID))

        // Main: a card was seen. Bookmark: a card was saved. Source: a card was read.
        _ = try store().append(
            [
                try enteredFact(edition: edition, card: seenInMain),
                try seenFact(edition: edition, card: seenInMain),
            ],
            policy: .baseline
        )
        _ = try store().append(
            [
                try ExposureFact(
                    type: .bookmarked,
                    editionID: edition,
                    cardID: bookmarked,
                    scope: bookmarkScope,
                    bootSessionID: "boot-1",
                    observedAtMs: 200,
                    policyVersion: ExposurePolicy.baseline.version,
                    userStateOperationID: "op-bookmark-1"
                ),
            ],
            policy: .baseline
        )
        _ = try store().append(
            [
                try ExposureFact(
                    type: .read,
                    editionID: edition,
                    cardID: seenInMain,
                    scope: sourceScope,
                    bootSessionID: "boot-1",
                    observedAtMs: 300,
                    policyVersion: ExposurePolicy.baseline.version,
                    userStateOperationID: "op-read-1"
                ),
            ],
            policy: .baseline
        )

        // Main excludes its own `seen` card, and only that.
        XCTAssertEqual(try history().exclusions(scope: .main), [seenInMain])
        // Bookmark and Source exclude nothing, whatever Main saw.
        XCTAssertEqual(try history().exclusions(scope: bookmarkScope), [])
        XCTAssertEqual(try history().exclusions(scope: sourceScope), [])
        // And the saved card is still saved; Main's exposure never touched another surface's row.
        XCTAssertEqual(try history().bookmarkedCardIDs(scope: bookmarkScope), [bookmarked])
        let bookmarkRow = try XCTUnwrap(try history().projection(scope: bookmarkScope, cardID: bookmarked))
        XCTAssertEqual(bookmarkRow.bookmarkedAtMs, 200)
        XCTAssertNil(bookmarkRow.lastSeenAtMs, "Main's seen did not leak into the bookmark projection")
        let mainRow = try XCTUnwrap(try history().projection(scope: .main, cardID: seenInMain))
        XCTAssertNil(mainRow.bookmarkedAtMs)

        // Removing the bookmark is the only thing that changes that list, and it is explicit.
        _ = try store().append(
            [
                try ExposureFact(
                    type: .bookmarkRemoved,
                    editionID: edition,
                    cardID: bookmarked,
                    scope: bookmarkScope,
                    bootSessionID: "boot-1",
                    observedAtMs: 400,
                    policyVersion: ExposurePolicy.baseline.version,
                    userStateOperationID: "op-bookmark-2"
                ),
            ],
            policy: .baseline
        )
        XCTAssertEqual(try history().bookmarkedCardIDs(scope: bookmarkScope), [])
        XCTAssertEqual(
            try history().projection(scope: bookmarkScope, cardID: bookmarked)?.bookmarkedAtMs,
            nil,
            "only an explicit removal changes the saved list (H-10)"
        )
    }

    /// The domain rule behind the matrix: exclusion needs a surface that applies `seen` *and* a fact
    /// recorded in that same scope.
    func testScopeRulesRequireTheDeclaringSurfaceAndTheSameScope() throws {
        let main = HistoryScopeRules(policy: try mainPolicy())
        let bookmark = HistoryScopeRules(policy: try bookmarkPolicy())
        let sourceID = try SourceID(1)
        let source = HistoryScopeRules(policy: try sourcePolicy(sourceID))

        XCTAssertTrue(main.excludes(cardSeenIn: .main))
        XCTAssertFalse(bookmark.excludes(cardSeenIn: .main), "a saved list is never filtered by Main")
        XCTAssertFalse(source.excludes(cardSeenIn: .main), "a source keeps its own navigable history")
        XCTAssertFalse(main.excludes(cardSeenIn: .source(sourceID)), "and Main is not filtered by Source")
        XCTAssertTrue(bookmark.showsOverlay(forCardRecordedIn: .main))
        XCTAssertTrue(source.showsOverlay(forCardRecordedIn: .main))
    }

    /// An undeclared scope is refused instead of assumed (ADR-007 D12).
    func testUndeclaredScopePolicyIsRefused() throws {
        let published = try publishEdition(cardCount: 1)
        _ = try store().append(
            [try seenFact(edition: published.edition.editionID, card: published.cards[0].payload.cardID)],
            policy: .baseline
        )
        XCTAssertNil(try history().declaredPolicy(for: .main))
        XCTAssertThrowsError(try history().exclusions(scope: .main)) { error in
            XCTAssertEqual(error as? HistoryProjectionError, .undeclaredPolicy("main"))
        }
    }

    /// Marking a card unread keeps its history: the row records the explicit clear and is never deleted
    /// (ADR-007's `read_cleared_at_ms`).
    func testClearingReadKeepsTheProjection() throws {
        let published = try publishEdition(cardCount: 1)
        let edition = published.edition.editionID
        let card = published.cards[0].payload.cardID
        try history().declare(try mainPolicy())
        _ = try store().append(
            [
                try ExposureFact(
                    type: .read,
                    editionID: edition,
                    cardID: card,
                    scope: .main,
                    bootSessionID: "boot-1",
                    observedAtMs: 500,
                    policyVersion: ExposurePolicy.baseline.version,
                    userStateOperationID: "op-read-1"
                ),
            ],
            policy: .baseline
        )
        XCTAssertEqual(try history().projection(scope: .main, cardID: card)?.readAtMs, 500)

        XCTAssertTrue(try history().clearRead(scope: .main, cardID: card, atMs: 900))
        let cleared = try XCTUnwrap(try history().projection(scope: .main, cardID: card))
        XCTAssertEqual(cleared.readClearedAtMs, 900)
        XCTAssertEqual(cleared.readAtMs, 500, "the card keeps its history: it is not requeued")
        XCTAssertEqual(try history().projectionCount(scope: .main), 1)
    }

    /// A flush touches the exposure tables only: publication and canonical state are byte-identical.
    func testFlushDoesNotTouchPublishedOrCanonicalRows() throws {
        let published = try publishEdition(cardCount: 2)
        let before = try publicationDump()
        let canonicalBytes = try dump()

        _ = try store().append(
            [
                try enteredFact(edition: published.edition.editionID, card: published.cards[0].payload.cardID),
                try seenFact(edition: published.edition.editionID, card: published.cards[0].payload.cardID),
            ],
            policy: .baseline
        )

        XCTAssertEqual(try publicationDump(), before, "no published row changed")
        XCTAssertEqual(try dump(), canonicalBytes, "no canonical row changed")
        XCTAssertEqual(try rowCount("exposure_fact"), 2)
        XCTAssertEqual(try rowCount("history_projection"), 1)
        try assertPublicationIntegrity(label: "after a flush")
    }
}
