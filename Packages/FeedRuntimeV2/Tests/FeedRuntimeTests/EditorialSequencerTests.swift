import XCTest
import FeedDomain
import FeedRuntime

/// PR-05, sequencing half: the stable editorial order, the limit, the quota, bounded repetition and the
/// honest short segment (plan §8, ADR-007 D13).
///
/// Most cases build the draft and the plan as values: the sequencer's contract is pure composition, and a
/// value-level fixture states the case without a database. The short-offer and empty-supply cases go
/// through the real engine, because "publishes a smaller segment instead of looping" must hold on the
/// production path.
final class EditorialSequencerTests: SelectionTestCase {
    // MARK: - Value fixtures

    private func choice(
        _ objectKey: String,
        provider: String? = "provider-a",
        source: String = "catalog:a",
        authoredAt: Date? = nil,
        observedAt: Date = SelectionInstant.epoch,
        clusterKey: String? = nil
    ) throws -> SelectionChoice {
        let stableKey = stableKey(objectKey)
        let candidate = SupplyCandidate(
            stableKey: stableKey,
            originRecordID: try OriginRecordID(1),
            originRevisionID: try OriginRevisionID(1),
            payloadDigestHex: String(repeating: "0", count: 32),
            sourceKey: try sourceKey(source),
            providerKey: provider.map { ProviderStableKey(namespace: ConnectorNamespace("connector.test"), providerKey: $0) },
            mediaRoles: [],
            filterText: objectKey,
            observedAt: observedAt,
            sortDate: authoredAt ?? observedAt,
            sortDateIsFallback: authoredAt == nil,
            sortDatePolicyVersion: SortDatePolicy.currentVersion
        )
        let score = SelectionScore(preferenceBonus: 0, explorationBonus: 0, matchedPreferences: [], isExploration: false)
        return SelectionChoice(
            candidate: candidate,
            score: score,
            orderKey: SelectionOrderKey(score: score.normalized, sortDate: candidate.sortDate, stableKey: stableKey),
            clusterKey: clusterKey.map { self.stableKey($0) } ?? stableKey,
            relaxationReasons: []
        )
    }

    private func draft(_ choices: [SelectionChoice], seed: Data = Data("seed".utf8)) throws -> SelectionDraft {
        SelectionDraft(
            context: try ContextKey(surface: .main, scopeKey: "main", planIdentity: "MainFeedPlan"),
            editorialRevision: try EditorialRevision(
                schemeVersion: EditorialRevision.currentSchemeVersion,
                digest: String(repeating: "a", count: 64)
            ),
            algorithmVersion: SelectionContract.algorithmVersion,
            selectionSchemaVersion: SelectionContract.schemaVersion,
            supplyGeneration: 1,
            seed: seed,
            choices: choices.sorted { $0.orderKey < $1.orderKey },
            clusters: [],
            readReport: SelectionReadReport(
                poolLimit: 96,
                pages: 1,
                steps: 1,
                examinedRows: choices.count,
                stepWindowRows: [96 * 16],
                supplyExhausted: false,
                scanBudgetReached: false,
                queryPlan: []
            ),
            strictChoiceCount: choices.count,
            supplyExhausted: false
        )
    }

    private func valuePlan(
        budget: SelectionBudget = .initial,
        repetition: RepetitionPolicy = .initial,
        freshness: FreshnessDemand = .any
    ) throws -> ResolvedFeedPlan {
        let context = try ContextKey(surface: .main, scopeKey: "main", planIdentity: "MainFeedPlan")
        let historyPolicy = try HistoryPolicy(
            scope: .main,
            applySeen: true,
            showOverlay: true,
            autoExclude: true,
            version: 1
        )
        let plan = FeedPlan(
            context: context,
            policies: try [
                PolicyVersion(policyID: .budget, version: budget.version),
                PolicyVersion(policyID: .contentRestrictions, version: ContentRestrictionPolicy.none.version),
                PolicyVersion(policyID: .preferences, version: ContentPreferencePolicy.none.version),
                PolicyVersion(policyID: .history, version: historyPolicy.version),
                PolicyVersion(policyID: .repetition, version: repetition.version),
                PolicyVersion(policyID: .editorialClock, version: ClockPolicy.fiveMinutes.version),
            ],
            budget: budget,
            historyPolicy: historyPolicy,
            repetitionPolicy: repetition,
            freshnessDemand: freshness
        )
        let digest = String(repeating: "b", count: 64)
        let inputs = EditorialInputs(
            plan: plan,
            relevantCatalogDigest: digest,
            relevantUserStateDigest: digest,
            editorialClockBucket: 0
        )
        return ResolvedFeedPlan(
            plan: plan,
            editorialRevision: try EditorialRevision(inputs: inputs),
            editorialClockBucket: 0,
            relevantCatalogDigest: digest,
            relevantUserStateDigest: digest
        )
    }

    private func occurrence(_ objectKey: String, edition: Int64, ordinal: Int = 0) throws -> PublishedOccurrence {
        PublishedOccurrence(
            stableKey: stableKey(objectKey),
            editionID: try EditionID(edition),
            ordinal: ordinal,
            publishedAt: SelectionInstant.offset(Double(edition))
        )
    }

    private func objectKeys(_ sequence: EditorialSequence) -> [String] {
        sequence.cards.map { String(decoding: $0.choice.stableKey.objectKeyBytes, as: UTF8.self) }
    }

    // MARK: - No supply (row 37)

    func testNoSupplyDoesNotLoopOrEraseHistory() throws {
        let key = try sourceKey("catalog:empty")
        _ = try insertSource("catalog:empty")
        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: true
        )
        let projections = projections(catalogKeys: [key], exclusions: [stableKey("seen-1")])
        let (resolved, draft) = try select(plan, projections: projections)
        XCTAssertTrue(draft.choices.isEmpty)
        XCTAssertTrue(draft.supplyExhausted)

        let history = PublishedHistory(occurrences: [try occurrence("seen-1", edition: 3)])
        let countsBefore = try tableCounts()
        let sequence = sequencer.sequence(draft: draft, plan: resolved, history: history)

        XCTAssertTrue(sequence.cards.isEmpty)
        XCTAssertEqual(sequence.status, .exhausted)
        XCTAssertEqual(sequence.counts.repetitionsSuppressed, 0)
        XCTAssertEqual(sequence.counts.clustersCollapsed, 0)
        XCTAssertEqual(sequence.relaxations, [])
        XCTAssertEqual(try tableCounts(), countsBefore, "exhaustion writes nothing and erases nothing")
        XCTAssertEqual(history.occurrences.count, 1, "the retained history stays navigable")
    }

    func testShortOfferPublishesASmallerSegment() throws {
        let source = try insertSource("catalog:short")
        let key = try sourceKey("catalog:short")
        try admitItems(5, prefix: "short", source: source)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false
        )
        let (resolved, draft) = try select(plan, projections: projections(catalogKeys: [key]))
        let sequence = sequencer.sequence(draft: draft, plan: resolved)

        XCTAssertEqual(sequence.cards.count, 5)
        XCTAssertEqual(sequence.status, .partial(.supplyExhausted(published: 5, requested: 24)))
        XCTAssertEqual(Set(objectKeys(sequence)).count, 5, "a short offer never loops a card to fill the count")
        XCTAssertEqual(sequence.cards.map(\.ordinal), [0, 1, 2, 3, 4])
        XCTAssertFalse(sequence.cards.contains { $0.isRepeatOccurrence })
    }

    // MARK: - Limited repetition

    func testLimitedRepetitionNeedsAWindowCounterAndADistinctOccurrence() throws {
        let plan = try valuePlan()
        let choices = [try choice("repeat-1"), try choice("other-1")]

        // One occurrence inside the window, the counter below the limit, and a distinct occurrence: the
        // card may be published again, as a new occurrence that names the previous edition.
        let single = PublishedHistory(occurrences: [try occurrence("repeat-1", edition: 1)])
        let allowed = sequencer.sequence(draft: try draft(choices), plan: plan, history: single)
        let repeatCard = try XCTUnwrap(allowed.cards.first { $0.choice.stableKey == stableKey("repeat-1") })
        XCTAssertTrue(repeatCard.isRepeatOccurrence)
        XCTAssertEqual(repeatCard.previousOccurrenceEdition, try EditionID(1))

        // Two occurrences in the window reach the limit of 2: the counter suppresses the item.
        let atLimit = PublishedHistory(occurrences: [
            try occurrence("repeat-1", edition: 1),
            try occurrence("repeat-1", edition: 2),
        ])
        let suppressed = sequencer.sequence(draft: try draft(choices), plan: plan, history: atLimit)
        XCTAssertEqual(objectKeys(suppressed), ["other-1"])
        XCTAssertEqual(suppressed.counts.repetitionsSuppressed, 1)
        XCTAssertEqual(
            suppressed.status,
            .partial(.repetitionSuppressed(published: 1, requested: 24))
        )

        // Without a distinct occurrence allowed, the window suppresses on the first hit.
        let noDistinct = try valuePlan(
            repetition: try RepetitionPolicy(window: 48, limit: 2, allowsDistinctOccurrence: false)
        )
        let strict = sequencer.sequence(draft: try draft(choices), plan: noDistinct, history: single)
        XCTAssertEqual(objectKeys(strict), ["other-1"])

        // The window is a bound, not the whole history: an occurrence outside the last `window` entries
        // no longer counts.
        let narrow = try valuePlan(
            repetition: try RepetitionPolicy(window: 1, limit: 1, allowsDistinctOccurrence: true)
        )
        let scrolled = PublishedHistory(occurrences: [
            try occurrence("repeat-1", edition: 1),
            try occurrence("other-1", edition: 2),
        ])
        let reused = sequencer.sequence(draft: try draft(choices), plan: narrow, history: scrolled)
        XCTAssertEqual(
            objectKeys(reused),
            ["repeat-1"],
            "only the last `window` entries count, so the older occurrence no longer suppresses its item"
        )
    }

    func testRepetitionIsForbiddenWhenThePlanAsksForUnseen() throws {
        let plan = try valuePlan(freshness: .unseen)
        let choices = [try choice("repeat-1"), try choice("other-1")]
        let history = PublishedHistory(occurrences: [try occurrence("repeat-1", edition: 1)])

        let sequence = sequencer.sequence(draft: try draft(choices), plan: plan, history: history)
        XCTAssertEqual(objectKeys(sequence), ["other-1"])
        XCTAssertEqual(sequence.counts.unseenSuppressed, 1)
        XCTAssertEqual(sequence.counts.repetitionsSuppressed, 0)
    }

    // MARK: - Limit and order

    func testTheSegmentNeverExceedsTheLimitAndKeepsTheDraftOrder() throws {
        let source = try insertSource("catalog:long")
        let key = try sourceKey("catalog:long")
        try admitItems(40, prefix: "long", source: source)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            budget: try makeBudget(cardLimit: 24, poolLimit: 64, providerQuota: 64),
            applySeen: false
        )
        let (resolved, draft) = try select(plan, projections: projections(catalogKeys: [key]))
        let sequence = sequencer.sequence(draft: draft, plan: resolved)

        XCTAssertEqual(sequence.cards.count, 24)
        XCTAssertEqual(sequence.status, .complete)
        XCTAssertEqual(
            sequence.cards.map(\.choice.stableKey),
            draft.choices.prefix(24).map(\.stableKey),
            "publication freezes the editorial order and nothing re-orders it"
        )
        XCTAssertEqual(sequence.cards.map(\.ordinal), Array(0..<24))
    }

    func testQuotaDefersTheDominantProviderBeforeTheSegmentIsShort() throws {
        let plan = try valuePlan(budget: try makeBudget(cardLimit: 12, poolLimit: 24, providerQuota: 4))
        let dominant = (0..<20).map { index in
            try? choice("dominant-\(index)", provider: "dominant", observedAt: SelectionInstant.offset(Double(index)))
        }.compactMap { $0 }
        let tail = (0..<8).map { index in
            try? choice("tail-\(index)", provider: "tail", observedAt: SelectionInstant.offset(Double(index)))
        }.compactMap { $0 }

        let sequence = sequencer.sequence(draft: try draft(dominant + tail), plan: plan)
        XCTAssertEqual(sequence.cards.count, 12, "the quota shapes the prefix; it does not shorten the segment")
        XCTAssertEqual(sequence.status, .complete)
        XCTAssertGreaterThan(sequence.counts.quotaDeferred, 0)
        XCTAssertGreaterThan(sequence.counts.quotaAdmitted, 0)
        let prefix = Set(sequence.cards.prefix(8).compactMap { $0.choice.candidate.providerKey?.providerKey })
        XCTAssertEqual(prefix, ["dominant", "tail"])
    }

    func testClusterDuplicatesPublishOnceUnlessRepetitionAllowsADistinctOccurrence() throws {
        let clustered = [
            try choice("story", clusterKey: "story"),
            try choice("repost-1", clusterKey: "story"),
            try choice("repost-2", clusterKey: "story"),
            try choice("other", clusterKey: "other"),
        ]
        let plan = try valuePlan(
            repetition: try RepetitionPolicy(window: 48, limit: 1, allowsDistinctOccurrence: true)
        )
        let sequence = sequencer.sequence(draft: try draft(clustered), plan: plan)
        XCTAssertEqual(
            Set(objectKeys(sequence)),
            ["repost-1", "other"],
            "the cluster publishes the member the editorial order reaches first, not the representative id"
        )
        XCTAssertEqual(sequence.counts.clustersCollapsed, 2)

        // A repetition policy that allows a distinct occurrence allows the cluster's second card.
        let permissive = try valuePlan(
            repetition: try RepetitionPolicy(window: 48, limit: 2, allowsDistinctOccurrence: true)
        )
        let two = sequencer.sequence(draft: try draft(clustered), plan: permissive)
        let storyCards = two.cards.filter { $0.choice.clusterKey == stableKey("story") }
        XCTAssertEqual(storyCards.count, 2)

        // Asking for unseen content collapses the cluster back to one card.
        let unseen = try valuePlan(
            repetition: try RepetitionPolicy(window: 48, limit: 2, allowsDistinctOccurrence: true),
            freshness: .unseen
        )
        let one = sequencer.sequence(draft: try draft(clustered), plan: unseen)
        XCTAssertEqual(one.cards.filter { $0.choice.clusterKey == stableKey("story") }.count, 1)
    }

    func testTheSequenceExportIsStable() throws {
        let plan = try valuePlan()
        let choices = [try choice("stable-1"), try choice("stable-2")]
        let draft = try draft(choices)
        let first = sequencer.sequence(draft: draft, plan: plan)
        let again = sequencer.sequence(draft: draft, plan: plan)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.canonicalSerialization, again.canonicalSerialization)
    }
}
