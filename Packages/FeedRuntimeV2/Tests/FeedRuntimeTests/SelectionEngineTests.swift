import XCTest
import GRDB
import FeedDomain
import FeedRuntime
import FeedStorage

/// PR-05, selection half: hard eligibility, the bounded pool, the quota, ties and reproducibility
/// (plan §8, ADR-002 D2, ADR-007 D12).
final class SelectionEngineTests: SelectionTestCase {
    private func keys(_ draft: SelectionDraft) -> [String] {
        draft.choices.map(\.stableKey.canonical)
    }

    private func objectKeys(_ draft: SelectionDraft) -> [String] {
        draft.choices.map { String(decoding: $0.stableKey.objectKeyBytes, as: UTF8.self) }
    }

    // MARK: - Hard eligibility

    func testHardEligibilityNeverRelaxes() throws {
        let source = try insertSource("catalog:a")
        let paused = try insertSource("catalog:paused")
        let enabledKey = try sourceKey("catalog:a")
        let pausedKey = try sourceKey("catalog:paused")

        try admit([
            SelectionFeedObject(objectKey: "plain-1", observedAt: SelectionInstant.offset(1)),
            SelectionFeedObject(objectKey: "plain-2", observedAt: SelectionInstant.offset(2)),
            SelectionFeedObject(objectKey: "audio-1", observedAt: SelectionInstant.offset(3), mediaRoles: [.audio]),
            SelectionFeedObject(
                objectKey: "spoiler-1",
                headline: "Spoiler: the ending",
                observedAt: SelectionInstant.offset(4)
            ),
            SelectionFeedObject(objectKey: "video-1", observedAt: SelectionInstant.offset(5), mediaRoles: [.video]),
            SelectionFeedObject(objectKey: "blocked-1", observedAt: SelectionInstant.offset(6)),
        ], source: source)
        try admit([SelectionFeedObject(objectKey: "paused-1")], source: paused)

        let plan = try makePlan(
            sourceSelection: [
                SourceSelection(sourceKey: enabledKey, enabled: true),
                SourceSelection(sourceKey: pausedKey, enabled: false),
            ],
            contentFilters: [
                try ContentFilter(filterID: "no-spoilers", keywords: ["spoiler"], isMandatory: true),
            ],
            restrictions: try ContentRestrictionPolicy(restrictions: [
                try ContentRestriction(restrictionID: "no-video", kind: .forbiddenMediaRole(.video)),
            ]),
            preferences: try ContentPreferencePolicy(preferences: [
                try ContentPreference(
                    preferenceID: "prefer-audio",
                    facet: .mediaRole(.audio),
                    weight: 150,
                    relaxation: .soft
                ),
            ]),
            budget: try makeBudget(cardLimit: 4, poolLimit: 8, providerQuota: 8),
            blocked: [stableKey("blocked-1")]
        )
        let (_, draft) = try select(
            plan,
            projections: projections(catalogKeys: [enabledKey, pausedKey])
        )

        XCTAssertEqual(Set(objectKeys(draft)), ["audio-1", "plain-1", "plain-2"])
        XCTAssertEqual(draft.strictChoiceCount, 1, "only the audio item satisfies the soft preference")
        XCTAssertEqual(draft.relaxedPreferences, ["prefer-audio"])

        let relaxed = draft.choices.filter { !$0.relaxationReasons.isEmpty }
        XCTAssertEqual(relaxed.count, 2)
        for choice in relaxed {
            XCTAssertEqual(
                choice.relaxationReasons,
                [RelaxationReason(kind: .softPreference, policyID: "prefer-audio")]
            )
        }
        let strict = try XCTUnwrap(draft.choices.first { $0.stableKey == stableKey("audio-1") })
        XCTAssertTrue(strict.relaxationReasons.isEmpty)
        XCTAssertEqual(strict.score.preferenceBonus, 150, "a satisfied preference raises the score")
        XCTAssertEqual(strict.score.matchedPreferences, ["prefer-audio"])

        // A short segment is published as a shorter segment, never by letting a hard rule back in.
        let resolved = try resolver.resolve(
            plan,
            projections: projections(catalogKeys: [enabledKey, pausedKey])
        )
        let sequence = sequencer.sequence(draft: draft, plan: resolved)
        XCTAssertEqual(sequence.cards.count, 3)
        XCTAssertEqual(sequence.status, .partial(.supplyExhausted(published: 3, requested: 4)))
        let published = Set(sequence.cards.map { String(decoding: $0.choice.stableKey.objectKeyBytes, as: UTF8.self) })
        XCTAssertEqual(published, ["audio-1", "plain-1", "plain-2"])
    }

    func testARevokedRecordIsNotSupply() throws {
        // A revoked record is not supply at all: the hard rule is decided before any candidate exists.
        let source = try insertSource("catalog:revoked")
        try admitItems(2, prefix: "live", source: source)
        try admitItems(1, prefix: "gone", source: source)
        try setAvailability("revoked", objectKey: "gone-0")

        let key = try sourceKey("catalog:revoked")
        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false
        )
        let (_, draft) = try select(plan, projections: projections(catalogKeys: [key]))
        XCTAssertEqual(Set(objectKeys(draft)), ["live-0", "live-1"])
    }

    func testANonMandatoryFilterRelaxesButAMandatoryOneNeverDoes() throws {
        let source = try insertSource("catalog:filters")
        let key = try sourceKey("catalog:filters")
        try admit([
            SelectionFeedObject(objectKey: "clean", observedAt: SelectionInstant.offset(3)),
            SelectionFeedObject(objectKey: "clean-2", observedAt: SelectionInstant.offset(2)),
            SelectionFeedObject(
                objectKey: "clickbait",
                headline: "Clickbait: you will not believe this",
                observedAt: SelectionInstant.offset(1)
            ),
            SelectionFeedObject(
                objectKey: "spoiler",
                headline: "Spoiler: the ending",
                observedAt: SelectionInstant.offset(0)
            ),
        ], source: source)

        let filters = [
            try ContentFilter(filterID: "no-spoilers", keywords: ["spoiler"], isMandatory: true),
            try ContentFilter(filterID: "no-clickbait", keywords: ["clickbait"], isMandatory: false),
        ]
        let projections = projections(catalogKeys: [key])

        // The strict pass alone fills the pool: the soft filter excludes too, and nothing is relaxed.
        let roomy = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            contentFilters: filters,
            budget: try makeBudget(cardLimit: 2, poolLimit: 2, providerQuota: 2),
            applySeen: false
        )
        let (_, strictDraft) = try select(roomy, projections: projections)
        XCTAssertEqual(Set(objectKeys(strictDraft)), ["clean", "clean-2"])
        XCTAssertTrue(strictDraft.relaxedFilters.isEmpty)

        // The pool cannot be filled strictly: the mandatory filter still excludes, the soft one relaxes
        // and the choice records why.
        let scarce = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            contentFilters: filters,
            budget: try makeBudget(cardLimit: 2, poolLimit: 4, providerQuota: 2),
            applySeen: false
        )
        let (_, shortDraft) = try select(scarce, projections: projections)
        XCTAssertEqual(Set(objectKeys(shortDraft)), ["clean", "clean-2", "clickbait"])
        XCTAssertEqual(shortDraft.relaxedFilters, ["no-clickbait"])
        XCTAssertTrue(shortDraft.relaxedPreferences.isEmpty)
        let relaxed = try XCTUnwrap(shortDraft.choices.first { $0.stableKey == stableKey("clickbait") })
        XCTAssertEqual(
            relaxed.relaxationReasons,
            [RelaxationReason(kind: .softFilter, policyID: "no-clickbait")]
        )
        XCTAssertFalse(
            objectKeys(shortDraft).contains("spoiler"),
            "a mandatory filter is hard eligibility and never relaxes"
        )
    }

    // MARK: - One source, several providers (row 3)

    func testOneSourceContainsMultipleProviders() throws {
        let source = try insertSource("catalog:multi-provider")
        let key = try sourceKey("catalog:multi-provider")
        let objects = (0..<20).map { index in
            SelectionFeedObject(
                objectKey: "alpha-\(index)",
                observedAt: SelectionInstant.offset(Double(index)),
                provider: (namespace: "connector.test", key: "provider-alpha")
            )
        } + (0..<20).map { index in
            SelectionFeedObject(
                objectKey: "beta-\(index)",
                observedAt: SelectionInstant.offset(Double(100 + index)),
                provider: (namespace: "connector.test", key: "provider-beta")
            )
        }
        try admit(objects, source: source)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            budget: try makeBudget(cardLimit: 16, poolLimit: 64, providerQuota: 8),
            applySeen: false
        )
        let resolved = try resolver.resolve(plan, projections: projections(catalogKeys: [key]))
        let draft = try engine.draft(
            plan: resolved,
            projections: projections(catalogKeys: [key]),
            seed: Data("seed".utf8),
            in: database
        )

        XCTAssertEqual(Set(draft.choices.map(\.candidate.sourceKey)), [key], "one source")
        let providers = Set(draft.choices.compactMap(\.candidate.providerKey?.providerKey))
        XCTAssertEqual(providers, ["provider-alpha", "provider-beta"], "one source holds several providers")
        XCTAssertEqual(draft.choices.count, 40, "the pool is not truncated below its limit")

        // The quota is per provider, not per source: a per-source quota of 8 could only publish 8 cards.
        let sequence = sequencer.sequence(draft: draft, plan: resolved)
        XCTAssertEqual(sequence.cards.count, 16)
        XCTAssertEqual(sequence.status, .complete)
        let counts = sequence.cards.reduce(into: [String: Int]()) { totals, card in
            totals[card.choice.candidate.providerKey?.providerKey ?? "", default: 0] += 1
        }
        XCTAssertEqual(counts["provider-alpha"], 8)
        XCTAssertEqual(counts["provider-beta"], 8)
    }

    // MARK: - Dominant provider and the quota

    func testDominantProviderQuotaKeepsTheSegmentPrefixDiverse() throws {
        let source = try insertSource("catalog:dominant")
        let key = try sourceKey("catalog:dominant")
        let dominant = (0..<100).map { index in
            SelectionFeedObject(
                objectKey: "dominant-\(index)",
                observedAt: SelectionInstant.offset(Double(1000 + index)),
                provider: (namespace: "connector.test", key: "dominant")
            )
        }
        let tail = (0..<20).map { index in
            SelectionFeedObject(
                objectKey: "tail-\(index)",
                observedAt: SelectionInstant.offset(Double(index)),
                provider: (namespace: "connector.test", key: "tail")
            )
        }
        try admit(dominant + tail, source: source)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false
        )
        let resolved = try resolver.resolve(plan, projections: projections(catalogKeys: [key]))
        let draft = try engine.draft(
            plan: resolved,
            projections: projections(catalogKeys: [key]),
            seed: Data("seed".utf8),
            in: database
        )
        XCTAssertEqual(draft.choices.count, SelectionBudget.initial.poolLimit)
        XCTAssertEqual(draft.readReport.steps, 1)
        XCTAssertEqual(draft.readReport.examinedRows, 120, "one bounded window covers the whole supply")

        let sequence = sequencer.sequence(draft: draft, plan: resolved)
        XCTAssertEqual(sequence.cards.count, 24)
        XCTAssertEqual(sequence.status, .complete)
        let prefix = Set(sequence.cards.prefix(16).compactMap { $0.choice.candidate.providerKey?.providerKey })
        XCTAssertEqual(prefix, ["dominant", "tail"], "the dominant provider cannot own the whole prefix")
        XCTAssertGreaterThan(sequence.counts.quotaAdmitted, 0)
        let totals = sequence.cards.reduce(into: [String: Int]()) { totals, card in
            totals[card.choice.candidate.providerKey?.providerKey ?? "", default: 0] += 1
        }
        XCTAssertEqual(totals["tail"], 8, "the quota gives the tail its turn in the prefix")
        XCTAssertEqual(totals["dominant"], 16)
    }

    // MARK: - History scope (row 34, ADR-007 D12)

    func testMainExposureDoesNotHideBookmarkOrSourceHistory() throws {
        let source = try insertSource("catalog:exposed")
        let key = try sourceKey("catalog:exposed")
        try admitItems(3, prefix: "seen", source: source)
        try admitItems(2, prefix: "fresh", source: source)
        let exclusions = ["seen-0", "seen-1", "seen-2"].map { stableKey($0) }
        let before = try tableCounts()

        let mainPlan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            historyScope: .main,
            applySeen: true
        )
        let (_, mainDraft) = try select(
            mainPlan,
            projections: projections(catalogKeys: [key], exclusions: exclusions)
        )
        XCTAssertEqual(Set(objectKeys(mainDraft)), ["fresh-0", "fresh-1"])

        let bookmarkPlan = try makePlan(
            surface: .bookmarks,
            scopeKey: "saved",
            planIdentity: "BookmarkPlan",
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            historyScope: .bookmark(listKey: "saved"),
            applySeen: false
        )
        let (_, bookmarkDraft) = try select(
            bookmarkPlan,
            projections: projections(catalogKeys: [key], exclusions: exclusions)
        )
        XCTAssertEqual(
            Set(objectKeys(bookmarkDraft)),
            ["fresh-0", "fresh-1", "seen-0", "seen-1", "seen-2"],
            "the saved list survives seen, opened and read unconditionally"
        )

        let sourcePlan = try makePlan(
            surface: .source,
            scopeKey: "source-1",
            planIdentity: "SourceFeedPlan",
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            historyScope: .source(source),
            applySeen: false
        )
        let (_, sourceDraft) = try select(
            sourcePlan,
            projections: projections(catalogKeys: [key], exclusions: exclusions)
        )
        XCTAssertEqual(
            Set(objectKeys(sourceDraft)),
            ["fresh-0", "fresh-1", "seen-0", "seen-1", "seen-2"],
            "a source keeps a navigable history of its own cards regardless of Main's discovery seen"
        )

        XCTAssertEqual(
            try tableCounts(),
            before,
            "selection reads the exposure projection; it never erases or rewrites it"
        )
        XCTAssertEqual(
            exclusions.count,
            3,
            "the caller's exclusion projection is an input, not a thing selection consumes"
        )
    }

    /// A plan that selects the reader's own saved subjects composes only those records.
    ///
    /// This is the first step of the content path `rollout.md` §2.5 names: the selection is a *plan input*
    /// — the caller states it, because a surface's identity does not imply it — and it travels from the
    /// plan, through the revision, into the storage query, which resolves the saved subjects to canonical
    /// records through the durable alias. Before it existed, a surface whose cards are the reader's saved
    /// rows had no way to say so, and the only read available was a source selection over the whole
    /// supply.
    func testAPlanSelectsTheReadersOwnSavedSubjects() throws {
        let source = try insertSource("catalog:saved")
        let key = try sourceKey("catalog:saved")
        try admitItems(3, prefix: "item", source: source)
        let projections = projections(catalogKeys: [key])

        let plain = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false
        )
        let (_, all) = try select(plain, projections: projections)
        XCTAssertEqual(Set(objectKeys(all)), ["item-0", "item-1", "item-2"])
        let chosen = try XCTUnwrap(all.choices.first { $0.stableKey == stableKey("item-1") })

        // The reader saved one of them: the projection the app's own bookmark slice writes, and the
        // durable alias that names the canonical record behind the subject.
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO user_state_projection (
                    kind, subject_id, wanted, last_operation_id, revision, updated_at
                ) VALUES (?, 'legacy-1', 1, 'op-save', 1, 0)
                """, arguments: [SubjectKind.bookmark.rawValue])
            try database.execute(sql: """
                INSERT INTO legacy_item_map (
                    legacy_item_id, legacy_source_url, origin_record_id, origin_revision_id,
                    confidence, mapped_at
                ) VALUES ('legacy-1', 'https://example.test/feed.xml', ?, ?, 'high', 0)
                """, arguments: [
                chosen.candidate.originRecordID.rawValue,
                chosen.candidate.originRevisionID.rawValue,
            ])
        }

        let saved = try makePlan(
            surface: .bookmarks,
            scopeKey: "saved",
            planIdentity: "BookmarkPlan",
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            historyScope: .bookmark(listKey: "saved"),
            applySeen: false,
            subjectSelection: .savedSubjects(kind: .bookmark, listKey: nil)
        )
        let (resolved, scoped) = try select(saved, projections: projections)

        XCTAssertEqual(objectKeys(scoped), ["item-1"], "the saved subject selects its own record")
        XCTAssertNotEqual(
            resolved.editorialRevision,
            try resolver.resolve(plain, projections: projections).editorialRevision,
            "the selection is an input of the revision: two plans that select differently are not one plan"
        )
    }

    // MARK: - Sort dates (row 14)

    func testMissingAuthoredAtDoesNotBecomeClaimedPublicationDate() throws {
        let source = try insertSource("catalog:dates")
        let key = try sourceKey("catalog:dates")
        let declared = SelectionInstant.offset(500)
        try admit([
            SelectionFeedObject(
                objectKey: "declared",
                authoredAt: declared,
                observedAt: SelectionInstant.offset(10)
            ),
            SelectionFeedObject(objectKey: "fallback", observedAt: SelectionInstant.offset(20)),
        ], source: source)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false
        )
        let (resolved, draft) = try select(plan, projections: projections(catalogKeys: [key]))
        let declaredChoice = try XCTUnwrap(draft.choices.first { $0.stableKey == stableKey("declared") })
        let fallbackChoice = try XCTUnwrap(draft.choices.first { $0.stableKey == stableKey("fallback") })

        XCTAssertFalse(declaredChoice.candidate.sortDateIsFallback)
        XCTAssertEqual(declaredChoice.candidate.sortDate, declared)
        XCTAssertTrue(fallbackChoice.candidate.sortDateIsFallback)
        XCTAssertEqual(fallbackChoice.candidate.sortDate, SelectionInstant.offset(20))
        XCTAssertEqual(fallbackChoice.candidate.sortDatePolicyVersion, SortDatePolicy.currentVersion)

        // The flag survives into the published order, so a fallback can never be presented as authored.
        let sequence = sequencer.sequence(draft: draft, plan: resolved)
        let publishedFallback = try XCTUnwrap(
            sequence.cards.first { $0.choice.stableKey == stableKey("fallback") }
        )
        XCTAssertTrue(publishedFallback.choice.candidate.sortDateIsFallback)

        // A plan may refuse fallback dates outright; the restriction is hard, not a preference.
        let strictPlan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            restrictions: try ContentRestrictionPolicy(restrictions: [
                try ContentRestriction(
                    restrictionID: "declared-date-only",
                    kind: .requiresDeclaredAuthoredDate
                ),
            ]),
            applySeen: false
        )
        let (_, strictDraft) = try select(strictPlan, projections: projections(catalogKeys: [key]))
        XCTAssertEqual(Set(objectKeys(strictDraft)), ["declared"])
    }

    // MARK: - Clusters (row 12, ADR-003 D13)

    func testClusterSplitPreservesOriginalRecords() throws {
        let source = try insertSource("catalog:cluster")
        let key = try sourceKey("catalog:cluster")
        try admit([
            SelectionFeedObject(objectKey: "story", observedAt: SelectionInstant.offset(0)),
            SelectionFeedObject(
                objectKey: "repost-1",
                observedAt: SelectionInstant.offset(1),
                relations: [(verb: "repostOf", target: "story")]
            ),
            SelectionFeedObject(
                objectKey: "repost-2",
                observedAt: SelectionInstant.offset(2),
                relations: [(verb: "repostOf", target: "story")]
            ),
        ], source: source)
        let before = try tableCounts()

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false,
            repetition: try RepetitionPolicy(window: 48, limit: 1, allowsDistinctOccurrence: true)
        )
        let projections = projections(catalogKeys: [key])
        let (resolved, grouped) = try select(plan, projections: projections)

        XCTAssertEqual(grouped.clusters.count, 1)
        let cluster = try XCTUnwrap(grouped.clusters.first)
        XCTAssertEqual(cluster.members.count, 3)
        XCTAssertEqual(cluster.representative, stableKey("repost-1"), "the smallest durable key represents")
        XCTAssertEqual(grouped.choices.count, 3, "clustering is a relation: the pool keeps every record")

        let groupedSequence = sequencer.sequence(draft: grouped, plan: resolved)
        XCTAssertEqual(groupedSequence.cards.count, 1)
        XCTAssertEqual(groupedSequence.counts.clustersCollapsed, 2)
        let idsBefore = Dictionary(uniqueKeysWithValues: grouped.choices.map { ($0.stableKey, $0.originRecordID) })

        // Splitting the relation removes the grouping and nothing else (ADR-003 D13, invariant 15).
        try dropAllRelations()
        let (splitResolved, split) = try select(plan, projections: projections)

        XCTAssertTrue(split.clusters.isEmpty)
        XCTAssertEqual(split.choices.count, 3)
        let splitSequence = sequencer.sequence(draft: split, plan: splitResolved)
        XCTAssertEqual(splitSequence.cards.count, 3, "every record is selectable again after the split")
        let idsAfter = Dictionary(uniqueKeysWithValues: split.choices.map { ($0.stableKey, $0.originRecordID) })
        XCTAssertEqual(idsBefore, idsAfter, "a relation never owned a record: identity is untouched")
        let after = try tableCounts()
        for table in ["origin_record", "origin_revision", "external_identity", "selection_supply", "source_membership"] {
            XCTAssertEqual(after[table], before[table], "\(table) survives the split unchanged")
        }
        XCTAssertEqual(after["content_relation"], 0)
    }

    // MARK: - Ties and order

    func testTiesBreakOnScoreThenTimestampThenStableKey() throws {
        let source = try insertSource("catalog:ties")
        let key = try sourceKey("catalog:ties")
        try admit([
            SelectionFeedObject(
                objectKey: "tie-a",
                authoredAt: SelectionInstant.offset(10),
                observedAt: SelectionInstant.offset(10)
            ),
            SelectionFeedObject(
                objectKey: "tie-b",
                authoredAt: SelectionInstant.offset(20),
                observedAt: SelectionInstant.offset(10)
            ),
            SelectionFeedObject(
                objectKey: "tie-c",
                authoredAt: SelectionInstant.offset(20),
                observedAt: SelectionInstant.offset(10)
            ),
        ], source: source)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false
        )
        let projections = projections(catalogKeys: [key])
        let (resolved, draft) = try select(plan, projections: projections, seed: Data("first".utf8))

        // Equal scores (no preference matched), so the timestamp decides, and the stable key breaks the
        // remaining tie: never `Set`/`Dictionary` order.
        XCTAssertEqual(
            draft.choices.map(\.candidate.sortDate),
            [SelectionInstant.offset(20), SelectionInstant.offset(20), SelectionInstant.offset(10)]
        )
        XCTAssertEqual(objectKeys(draft), ["tie-b", "tie-c", "tie-a"])
        assertSequence(order: sequencer.sequence(draft: draft, plan: resolved), matches: ["tie-b", "tie-c", "tie-a"])

        // The default exploration policy has weight 0, so the seed cannot reorder anything: the draft
        // records which seed it ran under, but the order and the normalized payloads do not move.
        let (_, otherSeed) = try select(plan, projections: projections, seed: Data("second".utf8))
        XCTAssertEqual(objectKeys(otherSeed), objectKeys(draft))
        XCTAssertEqual(
            otherSeed.choices.map(\.candidate.payloadDigestHex),
            draft.choices.map(\.candidate.payloadDigestHex)
        )
    }

    func testExplorationBiasIsReproducibleWhenThePolicyDeclaresAWeight() throws {
        let source = try insertSource("catalog:explore")
        let key = try sourceKey("catalog:explore")
        try admitItems(12, prefix: "explore", source: source)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false,
            exploration: try ExplorationPolicy(weight: 300)
        )
        let projections = projections(catalogKeys: [key])
        let first = try select(plan, projections: projections, seed: Data("seed-one".utf8))
        let again = try select(plan, projections: projections, seed: Data("seed-one".utf8))
        XCTAssertEqual(first.draft.canonicalSerialization, again.draft.canonicalSerialization)
        XCTAssertTrue(first.draft.choices.contains { $0.score.isExploration })

        let other = try select(plan, projections: projections, seed: Data("seed-two".utf8))
        XCTAssertEqual(other.draft.choices.count, first.draft.choices.count)
        XCTAssertNotEqual(
            other.draft.choices.map(\.stableKey),
            first.draft.choices.map(\.stableKey),
            "a weighted exploration policy makes the seed an input"
        )
    }

    // MARK: - Reproducibility

    func testTheSameInputsProduceTheSameSemanticSequenceAcrossDatabases() throws {
        let primarySource = try insertSource("catalog:repeatable")
        let key = try sourceKey("catalog:repeatable")
        let objects = ["b", "a", "c"].map { name in
            SelectionFeedObject(
                objectKey: "item-\(name)",
                authoredAt: SelectionInstant.offset(Double(name.utf8.first ?? 0)),
                observedAt: SelectionInstant.offset(Double(name.utf8.first ?? 0))
            )
        }
        try admit(objects, source: primarySource)

        let secondary = try makeSecondary(named: "secondary")
        let secondarySource = try insertSource("catalog:repeatable", into: secondary)
        try admit(Array(objects.reversed()), source: secondarySource, into: secondary)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false
        )
        let projections = projections(catalogKeys: [key])
        let first = try select(plan, projections: projections, seed: Data("seed".utf8))
        let second = try select(
            plan,
            projections: projections,
            seed: Data("seed".utf8),
            in: secondary
        )

        XCTAssertEqual(first.draft.canonicalSerialization, second.draft.canonicalSerialization)
        XCTAssertEqual(
            sequencer.sequence(draft: first.draft, plan: first.plan).canonicalSerialization,
            sequencer.sequence(draft: second.draft, plan: second.plan).canonicalSerialization
        )
        XCTAssertNotEqual(
            first.draft.choices.map(\.originRecordID),
            second.draft.choices.map(\.originRecordID),
            "the two databases allocate different row ids; the sequence must not depend on them"
        )
        XCTAssertEqual(
            first.draft.choices.map(\.stableKey),
            second.draft.choices.map(\.stableKey)
        )
    }

    func testTheRevisionGuardRefusesInputsThePlanDoesNotName() throws {
        let source = try insertSource("catalog:guard")
        let key = try sourceKey("catalog:guard")
        try admitItems(2, prefix: "guard", source: source)
        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            historyScope: .main,
            applySeen: true
        )
        let resolved = try resolver.resolve(
            plan,
            projections: projections(catalogKeys: [key], exclusions: [stableKey("seen-1")])
        )
        XCTAssertThrowsError(
            try engine.draft(
                plan: resolved,
                projections: projections(catalogKeys: [key], exclusions: [stableKey("seen-2")]),
                seed: Data("seed".utf8),
                in: database
            )
        ) { error in
            guard case .revisionNotReproducible? = error as? SelectionError else {
                XCTFail("expected a revision mismatch, got \(error)")
                return
            }
        }
    }

    // MARK: - Pool bound and cost

    func testPoolIsBoundedAndReportsTheMeasuredReadCost() throws {
        let source = try insertSource("catalog:bulk")
        let key = try sourceKey("catalog:bulk")
        try admitItems(120, prefix: "bulk", source: source)

        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            applySeen: false
        )
        let (_, draft) = try select(plan, projections: projections(catalogKeys: [key]))

        print("""
            engine pool: candidates=\(draft.choices.count) poolLimit=\(plan.budget.poolLimit) \
            examinedRows=\(draft.readReport.examinedRows) steps=\(draft.readReport.steps) \
            windows=\(draft.readReport.stepWindowRows)
            """)
        XCTAssertEqual(draft.choices.count, plan.budget.poolLimit)
        XCTAssertEqual(draft.readReport.examinedRows, 120)
        XCTAssertEqual(draft.readReport.steps, 1)
        XCTAssertEqual(draft.readReport.pages, 1)
        XCTAssertFalse(draft.readReport.scanBudgetReached)
        XCTAssertTrue(draft.readReport.queryPlan.contains { $0.contains("SEARCH s USING INTEGER PRIMARY KEY") })
        XCTAssertEqual(
            draft.supplyGeneration,
            try AdmissionLedger().supplyGeneration(in: database),
            "the draft records the generation it read beside the pool"
        )
    }
}

private extension XCTestCase {
    /// Asserts a sequence keeps the draft's editorial order.
    func assertSequence(
        order sequence: EditorialSequence,
        matches expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            sequence.cards.map { String(decoding: $0.choice.stableKey.objectKeyBytes, as: UTF8.self) },
            expected,
            file: file,
            line: line
        )
    }
}
