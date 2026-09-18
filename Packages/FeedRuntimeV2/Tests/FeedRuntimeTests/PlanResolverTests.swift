import XCTest
import FeedDomain
import FeedRuntime

/// PR-05, plan half: `ContextKey`, `EditorialRevision` and the resolver (ADR-002 D1–D6, plan §8).
///
/// The tests pin the fingerprint contract: the canonical field order, a digest that a different process
/// can recompute, the rule that a policy change changes the revision while a context change does not,
/// the clock bucket, and the ADR-007 D12 history matrix.
final class PlanResolverTests: SelectionTestCase {
    /// Every field of an ADR-002 D4 fingerprint, in the order D4 fixes.
    static let d4FieldOrder = [
        "revisionSchemeVersion",
        "planIdentity",
        "planSchemaVersion",
        "policies",
        "algorithmVersion",
        "sourceSelection",
        "subjectSelection",
        "presetIdentity",
        "region",
        "contentType",
        "languages",
        "mood",
        "contentFilters",
        "taxonomyURLs",
        "relevantCatalogDigest",
        "relevantUserStateDigest",
        "exclusionPolicyVersion",
        "editorialClockBucket",
        "selectionSchemaVersion",
    ]

    /// Reads the top-level field names out of a canonical serialization by walking its own framing:
    /// `name=tag:len:bytes` plus one `\n`, where a nested payload is length-prefixed rather than
    /// line-delimited. A parser that assumes one field per line would be fooled by a nested element.
    static func fieldNames(of data: Data) -> [String] {
        var names: [String] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let equals = data[index...].firstIndex(of: 0x3D),
                  let colon = data[equals...].firstIndex(of: 0x3A),
                  let secondColon = data[data.index(after: colon)...].firstIndex(of: 0x3A)
            else { break }
            names.append(String(decoding: data[index..<equals], as: UTF8.self))
            let lengthText = String(decoding: data[data.index(after: colon)..<secondColon], as: UTF8.self)
            guard let length = Int(lengthText) else { break }
            let payloadStart = data.index(after: secondColon)
            guard let payloadEnd = data.index(payloadStart, offsetBy: length, limitedBy: data.endIndex),
                  payloadEnd < data.endIndex
            else { break }
            index = data.index(after: payloadEnd)
        }
        return names
    }

    private func fixturePlan() throws -> FeedPlan {
        try makePlan(
            sourceSelection: [
                SourceSelection(sourceKey: try sourceKey("catalog:b"), enabled: false),
                SourceSelection(sourceKey: try sourceKey("catalog:a"), enabled: true),
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
                    weight: 200,
                    relaxation: .soft
                ),
            ]),
            languages: ["pt-BR", "en"],
            taxonomyURLs: ["https://example.test/taxonomy"],
            presetIdentity: "preset-1",
            region: "BR",
            contentType: "news",
            mood: "calm"
        )
    }

    private func fixtureProjections() throws -> PlanProjections {
        projections(
            catalogKeys: [try sourceKey("catalog:a"), try sourceKey("catalog:b")],
            exclusions: [stableKey("excluded-1")]
        )
    }

    // MARK: - The canonical form

    func testCanonicalSerializationFollowsADR002D4FieldOrder() throws {
        let plan = try fixturePlan()
        let inputs = EditorialInputs(
            plan: plan,
            relevantCatalogDigest: String(repeating: "a", count: 64),
            relevantUserStateDigest: String(repeating: "b", count: 64),
            editorialClockBucket: 5_666_666
        )
        XCTAssertEqual(
            Self.fieldNames(of: inputs.canonicalSerialization),
            Self.d4FieldOrder,
            "D4 order and completeness are the fingerprint contract"
        )
        XCTAssertFalse(
            String(decoding: inputs.canonicalSerialization, as: UTF8.self).contains("seed"),
            "the per-edition seed is excluded from the digest (D4)"
        )
    }

    /// The digest is pinned, not recomputed: a build that changes a field, an encoding or the algorithm
    /// fails here, and a different process reading the same inputs reproduces this exact string.
    ///
    /// Re-pinned 2026-09-18 for revision scheme **2**: `subjectSelection` joined the field set between
    /// `sourceSelection` and `presetIdentity` (ADR-002 D5's procedure, `baseline.md` §8.56). Revision 1's
    /// digest — `8a98012f7172316fc07b8740a0b4623f98ffd57b8e34ff0d409a3b9776019e4f` — stays valid for the
    /// rows that recorded it; it is kept here so the change is dated rather than silently overwritten.
    func testEditorialRevisionIsPinned() throws {
        let resolved = try resolver.resolve(try fixturePlan(), projections: try fixtureProjections())
        XCTAssertEqual(resolved.editorialRevision.schemeVersion, EditorialRevision.currentSchemeVersion)
        XCTAssertEqual(resolved.editorialClockBucket, 5_666_666)
        XCTAssertEqual(
            resolved.editorialRevision.digest,
            "a566db4db233a575d69d6ed6c9d963959a2a45828c7e7bb3af37a3ef4eb23b20"
        )
    }

    func testInputOrderDoesNotChangeTheRevision() throws {
        let canonical = try resolver.resolve(try fixturePlan(), projections: try fixtureProjections())
        let shuffled = try makePlan(
            sourceSelection: [
                SourceSelection(sourceKey: try sourceKey("catalog:a"), enabled: true),
                SourceSelection(sourceKey: try sourceKey("catalog:b"), enabled: false),
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
                    weight: 200,
                    relaxation: .soft
                ),
            ]),
            languages: ["en", "pt-BR"],
            taxonomyURLs: ["https://example.test/taxonomy"],
            presetIdentity: "preset-1",
            region: "BR",
            contentType: "news",
            mood: "calm"
        )
        let reorderedProjections = projections(
            catalogKeys: [try sourceKey("catalog:b"), try sourceKey("catalog:a")],
            exclusions: [stableKey("excluded-1")]
        )
        let second = try resolver.resolve(shuffled, projections: reorderedProjections)
        XCTAssertEqual(canonical.editorialRevision, second.editorialRevision)
        XCTAssertEqual(
            canonical.plan.languages,
            ["en", "pt-BR"],
            "the resolver canonicalizes the effective inputs"
        )
    }

    // MARK: - What changes a revision (row 15)

    func testEditorialPolicyChangeChangesRevision() throws {
        let base = try resolver.resolve(try fixturePlan(), projections: try fixtureProjections())

        func revision(_ plan: FeedPlan) throws -> EditorialRevision {
            try resolver.resolve(plan, projections: try fixtureProjections()).editorialRevision
        }

        let budgetChanged = try makePlan(
            sourceSelection: try fixturePlan().sourceSelection,
            contentFilters: [try ContentFilter(filterID: "no-spoilers", keywords: ["spoiler"], isMandatory: true)],
            restrictions: try ContentRestrictionPolicy(restrictions: [
                try ContentRestriction(restrictionID: "no-video", kind: .forbiddenMediaRole(.video)),
            ]),
            preferences: try ContentPreferencePolicy(preferences: [
                try ContentPreference(
                    preferenceID: "prefer-audio",
                    facet: .mediaRole(.audio),
                    weight: 200,
                    relaxation: .soft
                ),
            ]),
            budget: try SelectionBudget(
                cardLimit: 12,
                oversampleFactor: 4,
                poolLimit: 48,
                scanRowsPerStep: 768,
                maxScanSteps: 3,
                providerQuota: 4,
                diversityTarget: 2
            ),
            languages: ["en", "pt-BR"],
            taxonomyURLs: ["https://example.test/taxonomy"],
            presetIdentity: "preset-1",
            region: "BR",
            contentType: "news",
            mood: "calm"
        )
        XCTAssertNotEqual(base.editorialRevision, try revision(budgetChanged))

        let policyVersionBumped = try makePlan(
            sourceSelection: try fixturePlan().sourceSelection,
            contentFilters: [try ContentFilter(filterID: "no-spoilers", keywords: ["spoiler"], isMandatory: true)],
            restrictions: try ContentRestrictionPolicy(restrictions: [
                try ContentRestriction(restrictionID: "no-video", kind: .forbiddenMediaRole(.video)),
            ]),
            preferences: try ContentPreferencePolicy(preferences: [
                try ContentPreference(
                    preferenceID: "prefer-audio",
                    facet: .mediaRole(.audio),
                    weight: 200,
                    relaxation: .soft
                ),
            ]),
            historyPolicyVersion: 2,
            languages: ["en", "pt-BR"],
            taxonomyURLs: ["https://example.test/taxonomy"],
            presetIdentity: "preset-1",
            region: "BR",
            contentType: "news",
            mood: "calm"
        )
        XCTAssertNotEqual(base.editorialRevision, try revision(policyVersionBumped))

        let filterChanged = try makePlan(
            sourceSelection: try fixturePlan().sourceSelection,
            contentFilters: [try ContentFilter(filterID: "no-spoilers", keywords: ["spoiler", "leak"], isMandatory: true)],
            restrictions: try ContentRestrictionPolicy(restrictions: [
                try ContentRestriction(restrictionID: "no-video", kind: .forbiddenMediaRole(.video)),
            ]),
            preferences: try ContentPreferencePolicy(preferences: [
                try ContentPreference(
                    preferenceID: "prefer-audio",
                    facet: .mediaRole(.audio),
                    weight: 200,
                    relaxation: .soft
                ),
            ]),
            languages: ["en", "pt-BR"],
            taxonomyURLs: ["https://example.test/taxonomy"],
            presetIdentity: "preset-1",
            region: "BR",
            contentType: "news",
            mood: "calm"
        )
        XCTAssertNotEqual(base.editorialRevision, try revision(filterChanged))

        let softerFilter = try makePlan(
            sourceSelection: try fixturePlan().sourceSelection,
            contentFilters: [try ContentFilter(filterID: "no-spoilers", keywords: ["spoiler"], isMandatory: false)],
            restrictions: try ContentRestrictionPolicy(restrictions: [
                try ContentRestriction(restrictionID: "no-video", kind: .forbiddenMediaRole(.video)),
            ]),
            preferences: ContentPreferencePolicy.none,
            languages: ["en", "pt-BR"],
            taxonomyURLs: ["https://example.test/taxonomy"],
            presetIdentity: "preset-1",
            region: "BR",
            contentType: "news",
            mood: "calm"
        )
        XCTAssertNotEqual(
            base.editorialRevision,
            try revision(softerFilter),
            "a filter moving from mandatory to optional is an eligibility change"
        )

        let sourceSelectionChanged = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: try sourceKey("catalog:a"), enabled: true)],
            contentFilters: [try ContentFilter(filterID: "no-spoilers", keywords: ["spoiler"], isMandatory: true)],
            restrictions: try ContentRestrictionPolicy(restrictions: [
                try ContentRestriction(restrictionID: "no-video", kind: .forbiddenMediaRole(.video)),
            ]),
            preferences: try ContentPreferencePolicy(preferences: [
                try ContentPreference(
                    preferenceID: "prefer-audio",
                    facet: .mediaRole(.audio),
                    weight: 200,
                    relaxation: .soft
                ),
            ]),
            languages: ["en", "pt-BR"],
            taxonomyURLs: ["https://example.test/taxonomy"],
            presetIdentity: "preset-1",
            region: "BR",
            contentType: "news",
            mood: "calm"
        )
        XCTAssertNotEqual(base.editorialRevision, try revision(sourceSelectionChanged))

        let moodChanged = try makePlan(
            sourceSelection: try fixturePlan().sourceSelection,
            contentFilters: [try ContentFilter(filterID: "no-spoilers", keywords: ["spoiler"], isMandatory: true)],
            restrictions: try ContentRestrictionPolicy(restrictions: [
                try ContentRestriction(restrictionID: "no-video", kind: .forbiddenMediaRole(.video)),
            ]),
            preferences: try ContentPreferencePolicy(preferences: [
                try ContentPreference(
                    preferenceID: "prefer-audio",
                    facet: .mediaRole(.audio),
                    weight: 200,
                    relaxation: .soft
                ),
            ]),
            languages: ["en", "pt-BR"],
            taxonomyURLs: ["https://example.test/taxonomy"],
            presetIdentity: "preset-1",
            region: "BR",
            contentType: "news",
            mood: "energetic"
        )
        XCTAssertNotEqual(base.editorialRevision, try revision(moodChanged))

        // Repeating the same resolution is the deterministic case: no change, no new revision.
        XCTAssertEqual(base.editorialRevision, try resolver.resolve(try fixturePlan(), projections: try fixtureProjections()).editorialRevision)
    }

    func testContextKeyIsIndependentOfEditorialInputs() throws {
        let first = try resolver.resolve(try fixturePlan(), projections: try fixtureProjections())
        var changed = try fixturePlan()
        changed = FeedPlan(
            context: changed.context,
            policies: changed.policies,
            sourceSelection: [],
            presetIdentity: "preset-2",
            region: "US",
            contentFilters: [],
            budget: changed.budget,
            historyPolicy: changed.historyPolicy
        )
        let second = try resolver.resolve(changed, projections: .empty)
        XCTAssertEqual(first.context, second.context, "the intent is the same feed")
        XCTAssertNotEqual(first.editorialRevision.digest, second.editorialRevision.digest)

        let otherSurface = try ContextKey(surface: .search, scopeKey: "main", planIdentity: "MainFeedPlan")
        XCTAssertNotEqual(first.context, otherSurface)
    }

    // MARK: - Clock

    func testFixedClockKeepsTheRevisionStableInsideItsBucket() throws {
        clockDate = SelectionInstant.offset(0)
        let plan = try fixturePlan()
        let projections = try fixtureProjections()
        let first = try resolver.resolve(plan, projections: projections)

        clockDate = SelectionInstant.offset(50)
        let sameBucket = try resolver.resolve(plan, projections: projections)
        XCTAssertEqual(first.editorialClockBucket, sameBucket.editorialClockBucket)
        XCTAssertEqual(first.editorialRevision, sameBucket.editorialRevision)

        clockDate = SelectionInstant.offset(150)
        let nextBucket = try resolver.resolve(plan, projections: projections)
        XCTAssertEqual(nextBucket.editorialClockBucket, first.editorialClockBucket + 1)
        XCTAssertNotEqual(first.editorialRevision, nextBucket.editorialRevision)
    }

    // MARK: - Policy versioning

    func testDeclaredPolicyVersionMustMatchTheEmbeddedPolicy() throws {
        let plan = try fixturePlan()
        let tampered = FeedPlan(
            context: plan.context,
            policies: try [
                PolicyVersion(policyID: .budget, version: 2),
                PolicyVersion(policyID: .contentRestrictions, version: plan.contentRestrictions.version),
                PolicyVersion(policyID: .preferences, version: plan.preferences.version),
                PolicyVersion(policyID: .history, version: plan.historyPolicy.version),
                PolicyVersion(policyID: .repetition, version: plan.repetitionPolicy.version),
                PolicyVersion(policyID: .editorialClock, version: plan.clockPolicy.version),
            ],
            sourceSelection: plan.sourceSelection,
            budget: plan.budget,
            historyPolicy: plan.historyPolicy
        )
        XCTAssertThrowsError(try resolver.resolve(tampered)) { error in
            XCTAssertEqual(
                error as? PlanResolutionError,
                .policyVersionMismatch(.budget, declared: 2, embedded: 1)
            )
        }

        let missing = FeedPlan(
            context: plan.context,
            policies: try [
                PolicyVersion(policyID: .contentRestrictions, version: plan.contentRestrictions.version),
                PolicyVersion(policyID: .preferences, version: plan.preferences.version),
                PolicyVersion(policyID: .history, version: plan.historyPolicy.version),
                PolicyVersion(policyID: .repetition, version: plan.repetitionPolicy.version),
                PolicyVersion(policyID: .editorialClock, version: plan.clockPolicy.version),
            ],
            sourceSelection: plan.sourceSelection,
            budget: plan.budget,
            historyPolicy: plan.historyPolicy
        )
        XCTAssertThrowsError(try resolver.resolve(missing)) { error in
            XCTAssertEqual(error as? PlanResolutionError, .missingPolicy(.budget))
        }
    }

    func testUnsupportedContractVersionsAreRefused() throws {
        let plan = try fixturePlan()
        let future = FeedPlan(
            context: plan.context,
            planSchemaVersion: 2,
            policies: plan.policies,
            sourceSelection: plan.sourceSelection,
            budget: plan.budget,
            historyPolicy: plan.historyPolicy
        )
        XCTAssertThrowsError(try resolver.resolve(future)) { error in
            XCTAssertEqual(error as? PlanResolutionError, .unsupportedPlanSchemaVersion(2))
        }

        XCTAssertThrowsError(try EditorialRevision(schemeVersion: 3, digest: String(repeating: "a", count: 64))) {
            XCTAssertEqual($0 as? FeedPlanError, .unsupportedRevisionSchemeVersion(3))
        }
    }

    // MARK: - History scope (ADR-007 D12, row 34)

    func testHistoryScopeMatrixIsEnforced() throws {
        let sourceID = try insertSource("catalog:a")
        let bookmarkPlan = try makePlan(
            surface: .bookmarks,
            planIdentity: "BookmarkPlan",
            historyScope: .bookmark(listKey: "saved"),
            applySeen: true
        )
        XCTAssertThrowsError(try resolver.resolve(bookmarkPlan)) { error in
            XCTAssertEqual(
                error as? PlanResolutionError,
                .historyScopeNotAllowedToApplySeen(.bookmark(listKey: "saved"))
            )
        }

        let sourcePlan = try makePlan(
            surface: .source,
            scopeKey: "source-1",
            planIdentity: "SourceFeedPlan",
            historyScope: .source(sourceID),
            applySeen: true
        )
        XCTAssertThrowsError(try resolver.resolve(sourcePlan)) { error in
            XCTAssertEqual(error as? PlanResolutionError, .historyScopeNotAllowedToApplySeen(.source(sourceID)))
        }

        let searchPlan = try makePlan(
            surface: .search,
            planIdentity: "SearchPlan",
            historyScope: .search,
            applySeen: true
        )
        XCTAssertThrowsError(try resolver.resolve(searchPlan)) { error in
            XCTAssertEqual(error as? PlanResolutionError, .historyScopeNotAllowedToApplySeen(.search))
        }

        // A scope that does not belong to the plan's surface is a plan bug, not a policy choice.
        let mismatched = try makePlan(surface: .main, historyScope: .search, applySeen: false)
        XCTAssertThrowsError(try resolver.resolve(mismatched)) { error in
            XCTAssertEqual(
                error as? PlanResolutionError,
                .historyScopeSurfaceMismatch(.search, .main)
            )
        }

        // A collection may exclude, and the resolution records its policy version as the exclusion input.
        let collectionPlan = try makePlan(
            surface: .collection,
            scopeKey: "collection-1",
            planIdentity: "CollectionPlan",
            historyScope: .collection(key: "collection-1"),
            applySeen: true,
            historyPolicyVersion: 7
        )
        let resolved = try resolver.resolve(collectionPlan)
        XCTAssertEqual(resolved.plan.historyPolicy.applySeen, true)
        XCTAssertEqual(resolved.editorialInputs().exclusionPolicyVersion, 7)
    }

    // MARK: - Relevant projections (ADR-002 D6)

    func testRelevantUserStateProjectionEntersTheRevisionOnlyWhenThePlanReadsIt() throws {
        let plan = try fixturePlan()
        let catalogKeys = [try sourceKey("catalog:a"), try sourceKey("catalog:b")]
        let withOne = try resolver.resolve(
            plan,
            projections: projections(catalogKeys: catalogKeys, exclusions: [stableKey("seen-1")])
        )
        let withTwo = try resolver.resolve(
            plan,
            projections: projections(catalogKeys: catalogKeys, exclusions: [stableKey("seen-2")])
        )
        XCTAssertNotEqual(withOne.editorialRevision, withTwo.editorialRevision, "Main reads the seen projection")

        let bookmarkPlan = try makePlan(
            surface: .bookmarks,
            planIdentity: "BookmarkPlan",
            historyScope: .bookmark(listKey: "saved"),
            applySeen: false
        )
        let bookmarkOne = try resolver.resolve(
            bookmarkPlan,
            projections: projections(catalogKeys: [], exclusions: [stableKey("seen-1")])
        )
        let bookmarkTwo = try resolver.resolve(
            bookmarkPlan,
            projections: projections(catalogKeys: [], exclusions: [stableKey("seen-2"), stableKey("seen-3")])
        )
        XCTAssertEqual(
            bookmarkOne.editorialRevision,
            bookmarkTwo.editorialRevision,
            "a bookmark toggled on a card no bookmark plan reads for eligibility cannot change its revision"
        )

        // The catalogue projection is always part of the relevant inputs.
        let catalogChanged = try resolver.resolve(
            plan,
            projections: projections(
                catalogKeys: [try sourceKey("catalog:a"), try sourceKey("catalog:b"), try sourceKey("catalog:c")],
                exclusions: [stableKey("seen-1")]
            )
        )
        XCTAssertNotEqual(withOne.editorialRevision, catalogChanged.editorialRevision)
    }

    func testUnresolvedSourceKeyIsRefused() throws {
        let plan = try fixturePlan()
        let unresolved = try sourceKey("catalog:b")
        XCTAssertThrowsError(
            try resolver.resolve(plan, projections: projections(catalogKeys: [try sourceKey("catalog:a")]))
        ) { error in
            XCTAssertEqual(error as? PlanResolutionError, .unresolvedSourceKey(unresolved))
        }
    }

    // MARK: - Budget

    func testInitialBudgetMatchesThePlanHypothesis() {
        let budget = SelectionBudget.initial
        XCTAssertEqual(budget.version, SelectionBudget.currentVersion)
        XCTAssertEqual(budget.cardLimit, 24)
        XCTAssertEqual(budget.oversampleFactor, 4)
        XCTAssertEqual(budget.poolLimit, 96)
        XCTAssertEqual(budget.poolLimit, budget.cardLimit * budget.oversampleFactor)
        XCTAssertEqual(budget.scanRowsPerStep, budget.poolLimit * 16)
        XCTAssertEqual(budget.maxScanSteps, 3)
        XCTAssertEqual(budget.providerQuota, 8)
        XCTAssertEqual(budget.diversityTarget, 4)
        XCTAssertEqual(RepetitionPolicy.initial.window, 48)
        XCTAssertEqual(RepetitionPolicy.initial.limit, 2)
        XCTAssertEqual(ClockPolicy.fiveMinutes.bucketResolutionSeconds, 300)
        XCTAssertEqual(ExplorationPolicy.disabled.weight, 0)
    }
}
