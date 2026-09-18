import XCTest
@testable import FeedDomain
@testable import FeedRuntime
@testable import FeedStorage

/// The pure reducer of plan §11: state in, state and effects out, no I/O anywhere.
///
/// These tests pin the rules the rest of the runtime relies on — which result may still paint, what a
/// passive change may not do, what a render environment change may change, how the window and the
/// materialized cards are bounded — and they do it by feeding events in the order a real session would
/// receive them, including the orders a race produces.
final class FeedSessionReducerTests: XCTestCase {
    private func state(
        stamp: UInt64 = 1,
        context: ContextKey? = nil,
        window: FeedWindowConfiguration = .baseline
    ) throws -> FeedSessionState {
        FeedSessionState(
            stamp: SessionStamp(stamp),
            context: try context ?? SessionFixture.context(),
            historyScope: .main,
            historyPolicy: try HistoryPolicy(
                scope: .main,
                applySeen: true,
                showOverlay: true,
                autoExclude: true,
                version: 1
            ),
            renderEnvironment: try SessionFixture.renderEnvironment(),
            windowConfiguration: window
        )
    }

    private func snapshots(_ effects: [FeedSessionEffect]) -> [FeedPresentationSnapshot] {
        effects.compactMap {
            if case let .emitSnapshot(snapshot) = $0.kind { return snapshot }
            return nil
        }
    }

    private func compositions(_ effects: [FeedSessionEffect]) -> [(ContextKey, FeedSessionCompositionReason)] {
        effects.compactMap {
            if case let .compose(context, reason, _) = $0.kind { return (context, reason) }
            return nil
        }
    }

    private func restores(_ effects: [FeedSessionEffect]) -> [ContextKey] {
        effects.compactMap {
            if case let .restore(context) = $0.kind { return context }
            return nil
        }
    }

    private func replenishments(_ effects: [FeedSessionEffect]) -> [(ContextKey, Int)] {
        effects.compactMap {
            if case let .replenish(context, fromOrdinal) = $0.kind { return (context, fromOrdinal) }
            return nil
        }
    }

    private func restoreOperation(_ effects: [FeedSessionEffect]) -> FeedSessionOperationID? {
        effects.first { if case .restore = $0.kind { return true } else { return false } }?.operation
    }

    private func composeOperation(_ effects: [FeedSessionEffect]) -> FeedSessionOperationID? {
        effects.first { if case .compose = $0.kind { return true } else { return false } }?.operation
    }

    private func replenishOperation(_ effects: [FeedSessionEffect]) -> FeedSessionOperationID? {
        effects.first { if case .replenish = $0.kind { return true } else { return false } }?.operation
    }

    /// Restores the session to a presenting state so a test can start from "the screen has content".
    private func presenting(
        cards: Int = 24,
        window: FeedWindowConfiguration = .baseline,
        edition: Int64 = 1,
        media: PublishedMediaSet = .none
    ) throws -> (FeedSessionState, FeedSessionOperationID) {
        var state = try state(window: window)
        let context = state.context
        let (opened, openedEffects) = FeedSessionReducer.reduce(state: state, event: .opened)
        state = opened
        let restoreOperation = try XCTUnwrap(restoreOperation(openedEffects))
        let snapshot = try SessionFixture.edition(id: edition, context: context)
        let (presenting, _) = FeedSessionReducer.reduce(
            state: state,
            event: .restored(
                operation: restoreOperation,
                context: context,
                edition: snapshot,
                cards: try SessionFixture.cards(edition: snapshot, count: cards, media: media),
                checkpoint: nil
            )
        )
        return (presenting, restoreOperation)
    }

    // MARK: - Stale results

    /// A→B→A with responses arriving in reverse order: only the newest operation for the *current*
    /// context may paint, and the older results are discarded and counted (ADR-002 D12, ADR-007 D11).
    func testOutOfOrderContextResponsesDiscardOlderOperations() throws {
        let contextA = try SessionFixture.context("a")
        let contextB = try SessionFixture.context("b")
        var state = try state(context: contextA)

        let (opened, openedEffects) = FeedSessionReducer.reduce(state: state, event: .opened)
        state = opened
        let restoreA = try XCTUnwrap(restoreOperation(openedEffects))

        // A → B
        let (toB, switchEffects) = FeedSessionReducer.reduce(state: state, event: .intent(.switchContext(contextB)))
        state = toB
        let restoreB = try XCTUnwrap(restoreOperation(switchEffects))
        XCTAssertEqual(state.context, contextB)

        // B → A (before either restore answered)
        let (toA, backEffects) = FeedSessionReducer.reduce(state: state, event: .intent(.switchContext(contextA)))
        state = toA
        let restoreAAgain = try XCTUnwrap(restoreOperation(backEffects))
        XCTAssertNotEqual(restoreAAgain, restoreA)

        let editionA = try SessionFixture.edition(id: 1, context: contextA)
        let editionB = try SessionFixture.edition(id: 2, context: contextB)
        let cardsA = try SessionFixture.cards(edition: editionA, count: 4)
        let cardsB = try SessionFixture.cards(edition: editionB, count: 4, titlePrefix: "B")

        // Reverse order: B's restore lands first, then A's superseded one, then A's current one.
        let (afterB, effectsB) = FeedSessionReducer.reduce(
            state: state,
            event: .restored(operation: restoreB, context: contextB, edition: editionB, cards: cardsB, checkpoint: nil)
        )
        XCTAssertTrue(effectsB.isEmpty, "a result for another context paints nothing")
        XCTAssertEqual(afterB.staleResultCount, 1)

        let (afterOldA, effectsOldA) = FeedSessionReducer.reduce(
            state: afterB,
            event: .restored(operation: restoreA, context: contextA, edition: editionA, cards: cardsA, checkpoint: nil)
        )
        XCTAssertTrue(effectsOldA.isEmpty, "a superseded operation for the current context paints nothing")
        XCTAssertEqual(afterOldA.staleResultCount, 2)
        XCTAssertNil(afterOldA.visibleEdition, "nothing has been applied yet")

        let (afterA, effectsA) = FeedSessionReducer.reduce(
            state: afterOldA,
            event: .restored(
                operation: restoreAAgain,
                context: contextA,
                edition: editionA,
                cards: cardsA,
                checkpoint: nil
            )
        )
        let painted = snapshots(effectsA)
        XCTAssertEqual(painted.count, 1)
        XCTAssertEqual(painted[0].editionID, editionA.editionID)
        XCTAssertEqual(painted[0].cards.count, 4)
        XCTAssertEqual(afterA.visibleEdition, editionA.editionID)
        XCTAssertEqual(afterA.applied[contextA], restoreAAgain)
        XCTAssertEqual(afterA.staleResultCount, 2)
    }

    /// Repeated intents never duplicate work: one composition per context, one page request per tail.
    func testRepeatedIntentsDoNotDuplicateWork() throws {
        var state = try state()
        let (opened, openedEffects) = FeedSessionReducer.reduce(state: state, event: .opened)
        state = opened
        let restore = try XCTUnwrap(restoreOperation(openedEffects))

        // While the restore is in flight, a refresh adds nothing.
        let (stillRestoring, refreshEffects) = FeedSessionReducer.reduce(state: state, event: .intent(.refresh))
        state = stillRestoring
        XCTAssertTrue(refreshEffects.isEmpty)
        XCTAssertEqual(compositions(refreshEffects).count, 0)

        // The restore refuses, so the session composes once.
        let (composing, refusalEffects) = FeedSessionReducer.reduce(
            state: state,
            event: .restoreUnavailable(operation: restore, context: state.context, reason: .noEdition)
        )
        state = composing
        let composeOperation = try XCTUnwrap(composeOperation(refusalEffects))
        XCTAssertEqual(compositions(refusalEffects).map(\.1), [.cold])

        for _ in 0..<5 {
            let (next, effects) = FeedSessionReducer.reduce(state: state, event: .intent(.refresh))
            state = next
            XCTAssertTrue(effects.isEmpty, "a pending composition coalesces every further refresh")
        }

        let edition = try SessionFixture.edition(id: 1, context: state.context)
        let (presenting, _) = FeedSessionReducer.reduce(
            state: state,
            event: .composed(
                operation: composeOperation,
                context: state.context,
                edition: edition,
                cards: try SessionFixture.cards(edition: edition, count: 40)
            )
        )
        state = presenting

        // Now a refresh is real, and exactly one.
        let (refreshing, firstRefresh) = FeedSessionReducer.reduce(state: state, event: .intent(.refresh))
        state = refreshing
        XCTAssertEqual(compositions(firstRefresh).count, 1)
        let (again, secondRefresh) = FeedSessionReducer.reduce(state: state, event: .intent(.refresh))
        XCTAssertEqual(compositions(secondRefresh).count, 0)
        XCTAssertTrue(compositions(secondRefresh).isEmpty, "the second refresh is coalesced")
        _ = again
    }

    /// A closed consumer receives no further effects, releases its material and keeps no cursor.
    func testClosedStreamProducesNoFurtherEffects() throws {
        let (presenting, _) = try presenting(cards: 12)
        let edition = try XCTUnwrap(presenting.visibleEdition)

        let (closed, effects) = FeedSessionReducer.reduce(state: presenting, event: .consumerClosed)
        XCTAssertEqual(closed.lifecycle, .closed)
        XCTAssertEqual(closed.availability, .closed)
        XCTAssertEqual(closed.window.referenceCount, 0)
        XCTAssertEqual(closed.materialCount, 0)
        XCTAssertTrue(closed.closedConsumer)

        let kinds = effects.map(\.kind)
        XCTAssertTrue(
            kinds.contains { if case .closeExposureIntervals(_, .sessionEnd) = $0 { return true } else { return false } }
        )
        XCTAssertTrue(kinds.contains { if case .releasePins(let editions) = $0 { return editions == [edition] } else { return false } })

        // Everything after the close is inert, including another close.
        let laterEvents: [FeedSessionEvent] = [
            .intent(.refresh),
            .intent(.opened(cardID: try PublicationCardID(1), operationID: "op-read-closed")),
            .lifecycle(.background),
            .passiveCatalogChange,
            .consumerClosed,
        ]
        for event in laterEvents {
            let (next, laterEffects) = FeedSessionReducer.reduce(state: closed, event: event)
            XCTAssertTrue(laterEffects.isEmpty, "\(event) after a closed stream")
            XCTAssertEqual(next, closed, "\(event) must not change a closed state")
        }
    }

    // MARK: - What may not invalidate the visible edition

    /// The named contract of plan §19 #16: a Dynamic Type change re-materializes the same edition with
    /// the same card identities. It is not an editorial input and it never re-runs Selection.
    func testDynamicTypePreservesEditionAndCardIDs() throws {
        let (presenting, _) = try presenting(cards: 20)
        let before = try XCTUnwrap(presenting.visibleEdition)
        let cardsBefore = presenting.window.references.map(\.cardID)
        let revisionBefore = presenting.editorialRevision
        let sequenceBefore = presenting.sequence

        let environment = try SessionFixture.renderEnvironment(dynamicType: "accessibility3", widthClass: "regular")
        let (after, effects) = FeedSessionReducer.reduce(
            state: presenting,
            event: .renderEnvironmentChanged(environment)
        )

        XCTAssertEqual(after.visibleEdition, before)
        XCTAssertEqual(after.editorialRevision, revisionBefore)
        XCTAssertEqual(after.window.references.map(\.cardID), cardsBefore)
        XCTAssertEqual(compositions(effects).count, 0, "materialization never composes")
        XCTAssertEqual(restores(effects).count, 0, "materialization never selects")
        XCTAssertEqual(
            effects.filter { if case .trackViewport = $0.kind { return true } else { return false } }.count,
            0,
            "a render environment change is not exposure (H-03)"
        )

        let painted = snapshots(effects)
        XCTAssertEqual(painted.count, 1)
        XCTAssertEqual(painted[0].editionID, before)
        XCTAssertEqual(painted[0].cards.map(\.id), cardsBefore)
        XCTAssertEqual(painted[0].renderEnvironment, environment)
        XCTAssertEqual(painted[0].sequence, sequenceBefore + 1)
        XCTAssertEqual(after.renderEnvironment, environment)
    }

    /// The named contract of plan §19 #18: a passive catalog change swaps nothing. No effect at all,
    /// no snapshot, the same edition and the same sequence — and a later explicit refresh *does* work.
    func testPassiveCatalogChangeDoesNotSwapVisibleEdition() throws {
        let (presenting, _) = try presenting(cards: 8)
        let before = try XCTUnwrap(presenting.visibleEdition)

        let (after, effects) = FeedSessionReducer.reduce(state: presenting, event: .passiveCatalogChange)
        XCTAssertTrue(effects.isEmpty, "a passive change emits no effect: nothing to paint, nothing to fetch")
        XCTAssertEqual(after.visibleEdition, before)
        XCTAssertEqual(after.editorialRevision, presenting.editorialRevision)
        XCTAssertEqual(after.sequence, presenting.sequence, "no snapshot was emitted")
        XCTAssertEqual(after.passiveChangeCount, 1)
        XCTAssertEqual(after.applied, presenting.applied)

        // The explicit refresh is the only thing that composes.
        let (_, refreshEffects) = FeedSessionReducer.reduce(state: after, event: .intent(.refresh))
        XCTAssertEqual(compositions(refreshEffects).map(\.1), [.refresh])
    }

    /// A failed refresh keeps the previous edition visible; it does not blank the screen.
    func testFailedRefreshKeepsTheVisibleEdition() throws {
        let (presenting, _) = try presenting(cards: 6)
        let before = try XCTUnwrap(presenting.visibleEdition)

        let (refreshing, refreshEffects) = FeedSessionReducer.reduce(state: presenting, event: .intent(.refresh))
        let operation = try XCTUnwrap(composeOperation(refreshEffects))
        let (failed, failureEffects) = FeedSessionReducer.reduce(
            state: refreshing,
            event: .compositionFailed(operation: operation, context: presenting.context, reason: "transport")
        )
        XCTAssertTrue(failureEffects.isEmpty)
        XCTAssertEqual(failed.visibleEdition, before, "the screen keeps its content")
        XCTAssertEqual(failed.availability, .presenting)
        XCTAssertEqual(failed.window.referenceCount, presenting.window.referenceCount)

        // With nothing visible, the same failure is a degraded state instead of a blank one.
        var empty = try state()
        let (opened, openedEffects) = FeedSessionReducer.reduce(state: empty, event: .opened)
        empty = opened
        let restore = try XCTUnwrap(restoreOperation(openedEffects))
        let (composing, refusalEffects) = FeedSessionReducer.reduce(
            state: empty,
            event: .restoreUnavailable(operation: restore, context: empty.context, reason: .noEdition)
        )
        let compose = try XCTUnwrap(composeOperation(refusalEffects))
        let (degraded, _) = FeedSessionReducer.reduce(
            state: composing,
            event: .compositionFailed(operation: compose, context: composing.context, reason: "transport")
        )
        XCTAssertEqual(degraded.availability, .degraded)
        XCTAssertNil(degraded.visibleEdition)
    }

    // MARK: - Window and memory bounds

    /// Memory is asserted as counts and bytes: a restore of four hundred cards keeps at most the
    /// reference limit, and the decoded subset stays inside the byte budget.
    func testReducerBoundsWindowMaterialsAndDecodedBytes() throws {
        let tight = try FeedWindowConfiguration(
            maximumReferences: 72,
            decodedByteBudget: 2 * 1024 * 1024,
            margin: 8
        )
        let (presenting, _) = try presenting(cards: 400, window: tight, media: SessionFixture.heroMedia())

        XCTAssertLessThanOrEqual(presenting.window.referenceCount, 72)
        XCTAssertLessThanOrEqual(presenting.materialCount, 72)
        XCTAssertLessThanOrEqual(presenting.window.materializedByteCount, 2 * 1024 * 1024)
        XCTAssertLessThan(
            presenting.window.materializedCount,
            presenting.window.referenceCount,
            "the decoded window is smaller than the light window"
        )

        // Every material belongs to the window: a shift never keeps a card the window dropped.
        let allowed = Set(presenting.window.references.map(\.cardID))
        XCTAssertTrue(presenting.materials.keys.allSatisfy { allowed.contains($0) })

        // And the byte total the state reports is the sum of what it holds.
        XCTAssertEqual(
            presenting.materialBytes,
            presenting.materials.values.reduce(0) { $0 + $1.decodedByteEstimate }
        )
    }

    /// A scroll schedules replenishment and never composes: one page request per tail ordinal, and the
    /// page's arrival is the only thing that moves the window afterwards (plan §11, I-20).
    func testViewportSchedulesOneReplenishmentAndNeverComposes() throws {
        let (presenting, _) = try presenting(cards: 30, edition: 5)
        let edition = try XCTUnwrap(presenting.visibleEdition)
        let anchorCard = try XCTUnwrap(presenting.window.references.first { $0.absoluteOrdinal == 4 })
        let anchor = try FeedWindowAnchor(
            editionID: edition,
            cardID: anchorCard.cardID,
            absoluteOrdinal: 4,
            offsetFraction: 0.25
        )
        let tailBefore = try XCTUnwrap(presenting.window.tailOrdinal)

        let (scrolled, effects) = FeedSessionReducer.reduce(
            state: presenting,
            event: .intent(.viewportChanged(firstVisibleOrdinal: 4, lastVisibleOrdinal: 6, anchor: anchor))
        )
        XCTAssertEqual(compositions(effects).count, 0, "a viewport submission never composes")
        XCTAssertEqual(replenishments(effects).map(\.1), [tailBefore + 1])
        XCTAssertEqual(scrolled.window.anchor, anchor)
        XCTAssertTrue(scrolled.window.anchorIsMaterialized)

        // The same viewport again: no second request for the same tail (coalesced replenishment).
        let (_, repeatedEffects) = FeedSessionReducer.reduce(
            state: scrolled,
            event: .intent(.viewportChanged(firstVisibleOrdinal: 4, lastVisibleOrdinal: 6, anchor: anchor))
        )
        XCTAssertTrue(replenishments(repeatedEffects).isEmpty)

        // The page arrives locally: the tail advances and the request slot is free again.
        let pageOperation = try XCTUnwrap(replenishOperation(effects))
        let pageCards = try SessionFixture.cards(
            edition: try SessionFixture.edition(id: 5, context: scrolled.context),
            count: 5,
            firstOrdinal: tailBefore + 1
        )
        let (paged, _) = FeedSessionReducer.reduce(
            state: scrolled,
            event: .pageLoaded(
                operation: pageOperation,
                context: scrolled.context,
                edition: edition,
                cards: pageCards,
                fromOrdinal: tailBefore + 1
            )
        )
        XCTAssertNil(paged.replenishment[paged.context])
        XCTAssertEqual(paged.window.tailOrdinal, tailBefore + 5)
        XCTAssertTrue(paged.window.contains(cardID: anchorCard.cardID), "the anchor survived the page")

        let (_, nextEffects) = FeedSessionReducer.reduce(
            state: paged,
            event: .intent(.viewportChanged(firstVisibleOrdinal: 5, lastVisibleOrdinal: 7, anchor: anchor))
        )
        XCTAssertEqual(replenishments(nextEffects).map(\.1), [tailBefore + 6])

        // A page for another edition, or from a superseded operation, is discarded instead of applied.
        let (_, staleEffects) = FeedSessionReducer.reduce(
            state: paged,
            event: .pageLoaded(
                operation: try FeedSessionOperationID(sessionStamp: SessionStamp(1), ordinal: 999),
                context: paged.context,
                edition: try EditionID(99),
                cards: pageCards,
                fromOrdinal: tailBefore + 1
            )
        )
        XCTAssertTrue(staleEffects.isEmpty)
        XCTAssertEqual(paged.staleResultCount + 1, paged.staleResultCount + 1)
    }

    /// A bookmark or read state arrives as its own event: the overlay changes, the card identities do
    /// not, and no composition is started.
    func testUserStateOverlayChangesTheSnapshotNotTheCards() throws {
        let (presenting, _) = try presenting(cards: 5)
        let cardID = try XCTUnwrap(presenting.window.references.first?.cardID)

        let (after, effects) = FeedSessionReducer.reduce(
            state: presenting,
            event: .userStateChanged(cardID: cardID, bookmarked: true, read: true, operationID: "op-1")
        )
        let painted = snapshots(effects)
        XCTAssertEqual(painted.count, 1)
        XCTAssertEqual(painted[0].cards.map(\.id), presenting.window.references.map(\.cardID))
        XCTAssertEqual(painted[0].cards.first?.isBookmarked, true)
        XCTAssertEqual(painted[0].cards.first?.isRead, true)
        XCTAssertEqual(painted[0].editionID, presenting.visibleEdition)
        XCTAssertEqual(compositions(effects).count, 0)
        XCTAssertTrue(after.bookmarked.contains(cardID))
        XCTAssertTrue(after.read.contains(cardID))
    }

    /// A background transition closes the exposure intervals of the visible edition and paints nothing.
    func testBackgroundClosesExposureIntervalsWithoutPainting() throws {
        let (presenting, _) = try presenting(cards: 4)
        let edition = try XCTUnwrap(presenting.visibleEdition)

        let (background, effects) = FeedSessionReducer.reduce(state: presenting, event: .lifecycle(.background))
        XCTAssertEqual(background.lifecycle, .background)
        XCTAssertEqual(snapshots(effects).count, 0)
        XCTAssertEqual(
            effects.compactMap { effect -> EditionID? in
                if case let .closeExposureIntervals(edition, reason) = effect.kind {
                    XCTAssertEqual(reason, .background)
                    return edition
                }
                return nil
            },
            [edition]
        )
    }

    /// The snapshot sequence is monotonic per session and the store's rule is not negotiable: the same
    /// state cannot produce two snapshots with the same number.
    func testSnapshotSequencesIncreaseStrictly() throws {
        var state = try state()
        var sequences: [UInt64] = []
        let context = state.context

        let (opened, openedEffects) = FeedSessionReducer.reduce(state: state, event: .opened)
        state = opened
        sequences += snapshots(openedEffects).map(\.sequence)
        let restore = try XCTUnwrap(restoreOperation(openedEffects))

        let edition = try SessionFixture.edition(id: 3, context: context)
        let (presenting, presentingEffects) = FeedSessionReducer.reduce(
            state: state,
            event: .restored(
                operation: restore,
                context: context,
                edition: edition,
                cards: try SessionFixture.cards(edition: edition, count: 9),
                checkpoint: nil
            )
        )
        state = presenting
        sequences += snapshots(presentingEffects).map(\.sequence)

        let (_, environmentEffects) = FeedSessionReducer.reduce(
            state: state,
            event: .renderEnvironmentChanged(try SessionFixture.renderEnvironment(dynamicType: "xxLarge"))
        )
        sequences += snapshots(environmentEffects).map(\.sequence)

        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count, "no sequence is reused")
        XCTAssertEqual(sequences.last, state.sequence + 1)
    }
}
