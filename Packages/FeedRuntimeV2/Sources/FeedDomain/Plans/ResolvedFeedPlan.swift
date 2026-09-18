import Foundation

/// The editorial plan and its resolved form (ADR-002 D1–D7, plan §8).
///
/// `FeedPlan` is what the product asks for; `ResolvedFeedPlan` is that plan with its effective
/// inputs in canonical order and its `EditorialRevision` computed, which is what local Selection
/// evaluates. Value types only: nothing here opens a database, reads a clock or decodes a protocol.

// MARK: - Errors

public enum FeedPlanError: Error, Equatable, Sendable {
    case emptyScopeKey(ContextKey.Surface)
    case emptyPlanIdentity
    case unsupportedRevisionSchemeVersion(Int)
    case malformedRevisionDigest(String)
    case nonPositivePolicyVersion(Int)
    case emptyFilterID
    case emptyFilterKeywords(String)
    case emptyRestrictionID
    case emptyPreferenceID
    case preferenceWeightOutOfRange(String, Int)
    case nonPositiveBudgetComponent(String, Int)
    case poolSmallerThanCardLimit(cardLimit: Int, poolLimit: Int)
    case nonPositiveRepetitionWindow(Int)
    case nonPositiveRepetitionLimit(Int)
    case nonPositiveClockResolution(Int)
}

// MARK: - Context identity (ADR-002 D1)

/// The identity of an intent: *which* feed the user asked for.
///
/// It never changes because an editorial input changed (ADR-002 invariant 3), it never contains an
/// autoincrement row id (plan §5.1) and it never contains a digest of its inputs. The editorial
/// inputs live in `EditorialRevision` instead.
public struct ContextKey: Hashable, Sendable, CustomStringConvertible {
    public enum Surface: String, Hashable, Sendable, CaseIterable {
        case main
        case source
        case collection
        case bookmarks
        case search
        case smartFeed
        /// What's New: content first observed after its own baseline.
        case whatsNew
        /// The onboarding composer's showcase. Not a discovery surface: its samples must appear
        /// whatever the reader has already seen anywhere.
        case onboarding
        /// One saved search. A search surface, so it never eliminates a result because the Main Feed
        /// showed it.
        case persistentSearch
        /// The reader's own click history, navigable like a source.
        case lastClicked
    }

    public let surface: Surface
    /// Durable scope key of the surface: never a row id (ADR-003 owns the namespace list).
    public let scopeKey: String
    /// The resolved plan family, not its inputs.
    public let planIdentity: String

    public init(surface: Surface, scopeKey: String, planIdentity: String) throws {
        guard !scopeKey.isEmpty else { throw FeedPlanError.emptyScopeKey(surface) }
        guard !planIdentity.isEmpty else { throw FeedPlanError.emptyPlanIdentity }
        self.surface = surface
        self.scopeKey = scopeKey
        self.planIdentity = planIdentity
    }

    /// Canonical text form. This is also the `context_key` an edition carries.
    public var canonicalSerialization: String {
        "\(surface.rawValue)|\(scopeKey)|\(planIdentity)"
    }

    public var description: String { canonicalSerialization }
}

// MARK: - Revision identity (ADR-002 D2–D5)

/// The versioned fingerprint of the *effective* editorial inputs.
///
/// `(schemeVersion, digest)` where `digest` is the lowercase hex SHA-256 of
/// `EditorialInputs.canonicalSerialization`. It is not a counter, not a row id and not a hash of
/// upstream payloads. Two revisions are comparable only when their scheme versions are equal: a build
/// that reads an unknown scheme records the edition as `revisionNotComparable` instead of comparing
/// digests (D5).
public struct EditorialRevision: Hashable, Sendable, CustomStringConvertible {
    /// ADR-002 D5: a field may not be added, removed or reordered without bumping this. Version 2 added
    /// `subjectSelection` (the reader's own subjects as a card selection), between `sourceSelection` and
    /// `presetIdentity`. Revisions written under version 1 stay valid and keep naming their own scheme.
    public static let currentSchemeVersion = 2

    public let schemeVersion: Int
    public let digest: String

    public init(schemeVersion: Int, digest: String) throws {
        guard schemeVersion == Self.currentSchemeVersion else {
            throw FeedPlanError.unsupportedRevisionSchemeVersion(schemeVersion)
        }
        guard digest.count == 64 else { throw FeedPlanError.malformedRevisionDigest(digest) }
        self.schemeVersion = schemeVersion
        self.digest = digest
    }

    public init(inputs: EditorialInputs) throws {
        try self.init(
            schemeVersion: inputs.revisionSchemeVersion,
            digest: EditorialSHA256.hex(of: inputs.canonicalSerialization)
        )
    }

    public var description: String { "editorial-revision:v\(schemeVersion):\(digest)" }
}

/// The canonical field set of ADR-002 D4, in declaration order.
///
/// Declaration order *is* serialization order: a field may not be added, removed or reordered
/// without bumping `EditorialRevisionSchemeVersion` (D5). Explicitly absent, and therefore impossible
/// to fold into the digest: edition seed, `CatalogGeneration`/`UserStateRevision` counters, connector
/// identity/version/checkpoint, binding and endpoint, connector evidence, asset and media state,
/// viewport/exposure facts, the whole render environment, and any per-process hash (D4).
public struct EditorialInputs: Hashable, Sendable {
    public let revisionSchemeVersion: Int
    public let planIdentity: String
    public let planSchemaVersion: Int
    /// The effective policies, ordered by `policyID`, each with its declared version and the digest of
    /// its value (D4 field `policies[]`).
    public let policies: [PolicyFingerprint]
    public let algorithmVersion: Int
    public let sourceSelection: [SourceSelection]
    public let subjectSelection: SubjectSelection?
    public let presetIdentity: String
    public let region: String
    public let contentType: String
    public let languages: [String]
    public let mood: String
    public let contentFilters: [ContentFilter]
    public let taxonomyURLs: [String]
    public let relevantCatalogDigest: String
    public let relevantUserStateDigest: String
    public let exclusionPolicyVersion: Int
    public let editorialClockBucket: Int64
    public let selectionSchemaVersion: Int

    init(
        revisionSchemeVersion: Int,
        planIdentity: String,
        planSchemaVersion: Int,
        policies: [PolicyFingerprint],
        algorithmVersion: Int,
        sourceSelection: [SourceSelection],
        subjectSelection: SubjectSelection?,
        presetIdentity: String,
        region: String,
        contentType: String,
        languages: [String],
        mood: String,
        contentFilters: [ContentFilter],
        taxonomyURLs: [String],
        relevantCatalogDigest: String,
        relevantUserStateDigest: String,
        exclusionPolicyVersion: Int,
        editorialClockBucket: Int64,
        selectionSchemaVersion: Int
    ) {
        self.revisionSchemeVersion = revisionSchemeVersion
        self.planIdentity = planIdentity
        self.planSchemaVersion = planSchemaVersion
        self.policies = policies
        self.algorithmVersion = algorithmVersion
        self.sourceSelection = sourceSelection
        self.subjectSelection = subjectSelection
        self.presetIdentity = presetIdentity
        self.region = region
        self.contentType = contentType
        self.languages = languages
        self.mood = mood
        self.contentFilters = contentFilters
        self.taxonomyURLs = taxonomyURLs
        self.relevantCatalogDigest = relevantCatalogDigest
        self.relevantUserStateDigest = relevantUserStateDigest
        self.exclusionPolicyVersion = exclusionPolicyVersion
        self.editorialClockBucket = editorialClockBucket
        self.selectionSchemaVersion = selectionSchemaVersion
    }

    /// Builds the effective inputs of a plan. The plan must already be canonical (the resolver's
    /// output): sources, filters, languages and taxonomy URLs are sorted, so serialization order never
    /// depends on the order the caller listed things in.
    public init(
        plan: FeedPlan,
        relevantCatalogDigest: String,
        relevantUserStateDigest: String,
        editorialClockBucket: Int64
    ) {
        self.init(
            revisionSchemeVersion: EditorialRevision.currentSchemeVersion,
            planIdentity: plan.context.planIdentity,
            planSchemaVersion: plan.planSchemaVersion,
            policies: Self.policyFingerprints(of: plan),
            algorithmVersion: plan.algorithmVersion,
            sourceSelection: plan.sourceSelection,
            subjectSelection: plan.subjectSelection,
            presetIdentity: plan.presetIdentity,
            region: plan.region,
            contentType: plan.contentType,
            languages: plan.languages,
            mood: plan.mood,
            contentFilters: plan.contentFilters,
            taxonomyURLs: plan.taxonomyURLs,
            relevantCatalogDigest: relevantCatalogDigest,
            relevantUserStateDigest: relevantUserStateDigest,
            exclusionPolicyVersion: plan.historyPolicy.version,
            editorialClockBucket: editorialClockBucket,
            selectionSchemaVersion: plan.selectionSchemaVersion
        )
    }

    /// ADR-002 D3 canonical form. `name=tag:len:bytes\n` per field, in D4 order.
    public var canonicalSerialization: Data {
        var writer = CanonicalSerialization()
        writer.integer("revisionSchemeVersion", Int64(revisionSchemeVersion))
        writer.string("planIdentity", planIdentity)
        writer.integer("planSchemaVersion", Int64(planSchemaVersion))
        writer.list("policies", policies.map { policy in
            CanonicalSerialization.element { element in
                element.string("policyID", policy.policyID.rawValue)
                element.integer("policyVersion", Int64(policy.version))
                element.string("policyValueDigest", policy.valueDigest)
            }
        })
        writer.integer("algorithmVersion", Int64(algorithmVersion))
        writer.list("sourceSelection", sourceSelection.map { selection in
            CanonicalSerialization.element { element in
                element.string("sourceKey", selection.sourceKey.catalogIdentity)
                element.integer("canonicalizationVersion", Int64(selection.sourceKey.canonicalizationVersion))
                element.boolean("enabled", selection.enabled)
            }
        })
        writer.string("subjectSelection", subjectSelection?.canonicalTag ?? "-")
        writer.string("presetIdentity", presetIdentity)
        writer.string("region", region)
        writer.string("contentType", contentType)
        writer.list("languages", languages.map { Data($0.utf8) })
        writer.string("mood", mood)
        writer.list("contentFilters", contentFilters.map { filter in
            CanonicalSerialization.element { element in
                element.string("filterID", filter.filterID)
                element.boolean("mandatory", filter.isMandatory)
                element.list("keywords", filter.keywords.map { Data($0.utf8) })
            }
        })
        writer.list("taxonomyURLs", taxonomyURLs.map { Data($0.utf8) })
        writer.string("relevantCatalogDigest", relevantCatalogDigest)
        writer.string("relevantUserStateDigest", relevantUserStateDigest)
        writer.integer("exclusionPolicyVersion", Int64(exclusionPolicyVersion))
        writer.integer("editorialClockBucket", editorialClockBucket)
        writer.integer("selectionSchemaVersion", Int64(selectionSchemaVersion))
        return writer.data
    }

    /// The effective policies of a plan, ordered by `policyID`. The order is the closed `PolicyID`
    /// vocabulary, never a `Dictionary` or a `Set`.
    static func policyFingerprints(of plan: FeedPlan) -> [PolicyFingerprint] {
        let values: [any VersionedPolicyValue] = [
            plan.budget,
            plan.contentRestrictions,
            plan.preferences,
            plan.historyPolicy,
            plan.repetitionPolicy,
            plan.clockPolicy,
        ]
        return values
            .map(PolicyFingerprint.init)
            .sorted { $0.policyID.rawValue < $1.policyID.rawValue }
    }
}

// MARK: - Policy values as fingerprint inputs

extension SelectionBudget: VersionedPolicyValue {
    public var policyID: PolicyID { .budget }

    public var canonicalPolicyValue: Data {
        var writer = CanonicalSerialization()
        writer.integer("version", Int64(version))
        writer.integer("cardLimit", Int64(cardLimit))
        writer.integer("oversampleFactor", Int64(oversampleFactor))
        writer.integer("poolLimit", Int64(poolLimit))
        writer.integer("scanRowsPerStep", Int64(scanRowsPerStep))
        writer.integer("maxScanSteps", Int64(maxScanSteps))
        writer.integer("providerQuota", Int64(providerQuota))
        writer.integer("diversityTarget", Int64(diversityTarget))
        return writer.data
    }
}

extension ContentRestrictionPolicy: VersionedPolicyValue {
    public var policyID: PolicyID { .contentRestrictions }

    public var canonicalPolicyValue: Data {
        var writer = CanonicalSerialization()
        writer.integer("version", Int64(version))
        writer.list("restrictions", restrictions.map { restriction in
            CanonicalSerialization.element { element in
                element.string("restrictionID", restriction.restrictionID)
                element.string("kind", restriction.canonicalKind)
            }
        })
        return writer.data
    }
}

extension ContentPreferencePolicy: VersionedPolicyValue {
    public var policyID: PolicyID { .preferences }

    public var canonicalPolicyValue: Data {
        var writer = CanonicalSerialization()
        writer.integer("version", Int64(version))
        writer.list("preferences", preferences.map { preference in
            CanonicalSerialization.element { element in
                element.string("preferenceID", preference.preferenceID)
                element.string("facet", preference.canonicalFacet)
                element.integer("weight", Int64(preference.weight))
                element.string("relaxation", preference.relaxation.rawValue)
            }
        })
        return writer.data
    }
}

extension HistoryPolicy: VersionedPolicyValue {
    public var policyID: PolicyID { .history }

    /// The surface, never the scope's associated value: a local `SourceID` or a row id must never enter a
    /// persisted fingerprint (ADR-002 D1); the durable scope key lives in the `ContextKey`.
    public var canonicalPolicyValue: Data {
        var writer = CanonicalSerialization()
        writer.integer("version", Int64(version))
        writer.string("surface", scope.surface.rawValue)
        writer.boolean("applySeen", applySeen)
        writer.boolean("showOverlay", showOverlay)
        writer.boolean("autoExclude", autoExclude)
        return writer.data
    }
}

extension RepetitionPolicy: VersionedPolicyValue {
    public var policyID: PolicyID { .repetition }

    public var canonicalPolicyValue: Data {
        var writer = CanonicalSerialization()
        writer.integer("version", Int64(version))
        writer.integer("window", Int64(window))
        writer.integer("limit", Int64(limit))
        writer.boolean("allowsDistinctOccurrence", allowsDistinctOccurrence)
        return writer.data
    }
}

extension ClockPolicy: VersionedPolicyValue {
    public var policyID: PolicyID { .editorialClock }

    public var canonicalPolicyValue: Data {
        var writer = CanonicalSerialization()
        writer.integer("version", Int64(version))
        writer.integer("bucketResolutionSeconds", Int64(bucketResolutionSeconds))
        return writer.data
    }
}

// MARK: - Policy inputs

/// The closed vocabulary of versioned policy bundles.
///
/// Exactly the policy values that ADR-002 D4 does *not* serialize field by field: their content enters
/// the digest through the declared version, so a value change without a version bump is a plan the
/// resolver refuses. Values D4 serializes explicitly (the source selection, the resolved content
/// filters, the languages, the taxonomy URLs, the algorithm and schema versions) are deliberately
/// absent here: they are their own fingerprint.
///
/// A closed enum rather than a free string: a mistyped policy id must not quietly produce a revision
/// that no consumer can attribute to a policy.
public enum PolicyID: String, Hashable, Sendable, CaseIterable {
    case budget
    case contentRestrictions
    case preferences
    case history
    case repetition
    case editorialClock
}

/// A policy value that must be visible in the fingerprint through its own content, not only through the
/// version declared for it.
public protocol VersionedPolicyValue: Sendable {
    var policyID: PolicyID { get }
    var version: Int { get }
    /// Canonical serialization of the value, including its version.
    var canonicalPolicyValue: Data { get }
}

/// One effective versioned policy as the fingerprint sees it.
///
/// ADR-002 D4 sketches `policies[]` as ordered `(policyID, policyVersion)` pairs. A pair alone cannot
/// describe an *effective* input: changing a quota or a pool size inside `SelectionBudget` while its
/// policy version stays the same would leave the revision unchanged, and the runtime would then claim
/// that two histories were produced under the same rules when they were not — the exact false
/// determinism claim D2 exists to prevent. The element therefore also carries the SHA-256 of the policy
/// value, and any value change changes the revision even before a version bump.
public struct PolicyFingerprint: Hashable, Sendable {
    public let policyID: PolicyID
    public let version: Int
    public let valueDigest: String

    public init(policyID: PolicyID, version: Int, valueDigest: String) {
        self.policyID = policyID
        self.version = version
        self.valueDigest = valueDigest
    }

    public init(_ value: any VersionedPolicyValue) {
        self.init(
            policyID: value.policyID,
            version: value.version,
            valueDigest: EditorialSHA256.hex(of: value.canonicalPolicyValue)
        )
    }
}

/// A declared `(policyID, version)` pair. The resolver refuses a plan that declares a version the
/// embedded policy value does not carry, so the digest cannot claim a policy version that the
/// effective inputs do not implement (D2, D5).
public struct PolicyVersion: Hashable, Sendable {
    public let policyID: PolicyID
    public let version: Int

    public init(policyID: PolicyID, version: Int) throws {
        guard version > 0 else { throw FeedPlanError.nonPositivePolicyVersion(version) }
        self.policyID = policyID
        self.version = version
    }
}

/// One editorial source as the plan selects it: a durable editorial key plus enablement.
///
/// Enablement is eligibility, never identity: disabling a source removes its cards from this plan and
/// does not touch the source, its bindings or its rows (ADR-003 D6).
public struct SourceSelection: Hashable, Sendable {
    public let sourceKey: EditorialSourceKey
    public let enabled: Bool

    public init(sourceKey: EditorialSourceKey, enabled: Bool) {
        self.sourceKey = sourceKey
        self.enabled = enabled
    }

    /// Canonical order: durable key, then enablement. Sorting is what makes the fingerprint
    /// independent of the order the caller listed sources in (D3).
    public static func canonicalOrder(_ values: [SourceSelection]) -> [SourceSelection] {
        values.sorted { lhs, rhs in
            if lhs.sourceKey.catalogIdentity != rhs.sourceKey.catalogIdentity {
                return lhs.sourceKey.catalogIdentity < rhs.sourceKey.catalogIdentity
            }
            if lhs.sourceKey.canonicalizationVersion != rhs.sourceKey.canonicalizationVersion {
                return lhs.sourceKey.canonicalizationVersion < rhs.sourceKey.canonicalizationVersion
            }
            return !lhs.enabled && rhs.enabled
        }
    }
}

/// One resolved content filter (ADR-002 D4). The keywords are already locale-resolved values: the
/// digest must never read `Locale.current` at evaluation time (D7).
public struct ContentFilter: Hashable, Sendable {
    public let filterID: String
    public let keywords: [String]
    /// A mandatory filter is hard eligibility: it never relaxes (plan §8).
    public let isMandatory: Bool

    public init(filterID: String, keywords: [String], isMandatory: Bool) throws {
        guard !filterID.isEmpty else { throw FeedPlanError.emptyFilterID }
        guard !keywords.isEmpty else { throw FeedPlanError.emptyFilterKeywords(filterID) }
        self.filterID = filterID
        self.keywords = keywords
        self.isMandatory = isMandatory
    }

    public static func canonicalOrder(_ values: [ContentFilter]) -> [ContentFilter] {
        values.sorted { $0.filterID < $1.filterID }
    }
}

/// A content restriction. Restrictions are always hard: the plan's "relax" path only ever exists for
/// preferences marked `soft` (plan §8).
public struct ContentRestriction: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case forbiddenKeyword(String)
        case requiredMediaRole(MediaRole)
        case forbiddenMediaRole(MediaRole)
        /// Excludes revisions whose sort date is the observation-time fallback (ADR-003 D17).
        case requiresDeclaredAuthoredDate
    }

    public let restrictionID: String
    public let kind: Kind

    public init(restrictionID: String, kind: Kind) throws {
        guard !restrictionID.isEmpty else { throw FeedPlanError.emptyRestrictionID }
        self.restrictionID = restrictionID
        self.kind = kind
    }

    public static func canonicalOrder(_ values: [ContentRestriction]) -> [ContentRestriction] {
        values.sorted { $0.restrictionID < $1.restrictionID }
    }

    /// Canonical text of the restriction, for the policy value digest.
    var canonicalKind: String {
        switch kind {
        case let .forbiddenKeyword(keyword): return "forbiddenKeyword:\(keyword)"
        case let .requiredMediaRole(role): return "requiredMediaRole:\(role.rawValue)"
        case let .forbiddenMediaRole(role): return "forbiddenMediaRole:\(role.rawValue)"
        case .requiresDeclaredAuthoredDate: return "requiresDeclaredAuthoredDate"
        }
    }
}

/// A facet a preference can select on. Only facets the canonical schema actually projects: the
/// source, the provider attribution, the revision's media roles and its text.
public enum PreferenceFacet: Hashable, Sendable {
    case mediaRole(MediaRole)
    case source(EditorialSourceKey)
    case provider(ProviderStableKey)
    case keyword(String)
}

/// Whether a preference that cannot be satisfied may be relaxed when supply is short.
public enum PreferenceRelaxation: String, Hashable, Sendable, CaseIterable {
    /// Hard: the preference behaves like a restriction and is never relaxed.
    case hard
    /// Soft: the preference may be relaxed, and the relaxation is recorded on the draft (plan §8).
    case soft
}

/// One versioned soft-or-hard editorial preference. It carries a score weight, so a preference that
/// is satisfied also orders the candidate (plan §8).
public struct ContentPreference: Hashable, Sendable {
    public let preferenceID: String
    public let facet: PreferenceFacet
    /// Score contribution in `0...SelectionScore.maximum`, applied only when satisfied.
    public let weight: Int
    public let relaxation: PreferenceRelaxation

    public init(
        preferenceID: String,
        facet: PreferenceFacet,
        weight: Int,
        relaxation: PreferenceRelaxation
    ) throws {
        guard !preferenceID.isEmpty else { throw FeedPlanError.emptyPreferenceID }
        guard weight >= 0 && weight <= SelectionScore.maximum else {
            throw FeedPlanError.preferenceWeightOutOfRange(preferenceID, weight)
        }
        self.preferenceID = preferenceID
        self.facet = facet
        self.weight = weight
        self.relaxation = relaxation
    }

    public static func canonicalOrder(_ values: [ContentPreference]) -> [ContentPreference] {
        values.sorted { $0.preferenceID < $1.preferenceID }
    }

    /// Canonical text of the facet, for the policy value digest.
    var canonicalFacet: String {
        switch facet {
        case let .mediaRole(role): return "mediaRole:\(role.rawValue)"
        case let .source(key): return "source:\(key.catalogIdentity)@\(key.canonicalizationVersion)"
        case let .provider(key): return "provider:\(key.canonical)"
        case let .keyword(text): return "keyword:\(text)"
        }
    }
}

/// The versioned restriction bundle. Restrictions are hard eligibility; only their version enters the
/// digest (ADR-002 D4 serializes policies as `(policyID, policyVersion)`), so a changed restriction set
/// must carry a new version and the resolver refuses a plan where it does not.
public struct ContentRestrictionPolicy: Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let restrictions: [ContentRestriction]

    public init(
        version: Int = ContentRestrictionPolicy.currentVersion,
        restrictions: [ContentRestriction]
    ) throws {
        guard version > 0 else { throw FeedPlanError.nonPositivePolicyVersion(version) }
        self.version = version
        self.restrictions = ContentRestriction.canonicalOrder(restrictions)
    }

    public static let none = ContentRestrictionPolicy(uncheckedVersion: currentVersion, restrictions: [])

    private init(uncheckedVersion version: Int, restrictions: [ContentRestriction]) {
        self.version = version
        self.restrictions = restrictions
    }
}

/// The versioned preference bundle, hard and soft together: "relax category/media" exists only for the
/// preferences marked `soft` (plan §8).
public struct ContentPreferencePolicy: Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let preferences: [ContentPreference]

    public init(
        version: Int = ContentPreferencePolicy.currentVersion,
        preferences: [ContentPreference]
    ) throws {
        guard version > 0 else { throw FeedPlanError.nonPositivePolicyVersion(version) }
        self.version = version
        self.preferences = ContentPreference.canonicalOrder(preferences)
    }

    public static let none = ContentPreferencePolicy(uncheckedVersion: currentVersion, preferences: [])

    private init(uncheckedVersion version: Int, preferences: [ContentPreference]) {
        self.version = version
        self.preferences = preferences
    }
}

/// The selection budget: 24 cards, oversampling 4×, pool target 96 (plan §8, an initial tuning
/// hypothesis in the plan and therefore a versioned policy value here).
///
/// `scanRowsPerStep`/`maxScanSteps` are the bounded sampling steps: a step examines at most
/// `scanRowsPerStep` supply rows, the next step doubles it, and the walk never runs more steps than
/// `maxScanSteps`. When the steps run out the plan publishes a smaller segment instead of looping
/// (plan §8, ADR-007 D13).
public struct SelectionBudget: Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let cardLimit: Int
    public let oversampleFactor: Int
    public let poolLimit: Int
    public let scanRowsPerStep: Int
    public let maxScanSteps: Int
    /// Maximum cards one provider/cluster may take in the segment prefix before the others get their
    /// turn (plan §8: "quotas por provider/cluster quando uma fonte dominante ocupar todo o prefixo").
    public let providerQuota: Int
    /// How many distinct provider/cluster keys the pool tries to hold before the walk stops early. A
    /// supply that cannot reach it is read to the scan budget and then publishes what it has, without
    /// looping (plan §8, ADR-007 D13).
    public let diversityTarget: Int

    public init(
        version: Int = SelectionBudget.currentVersion,
        cardLimit: Int,
        oversampleFactor: Int,
        poolLimit: Int,
        scanRowsPerStep: Int,
        maxScanSteps: Int,
        providerQuota: Int,
        diversityTarget: Int
    ) throws {
        guard version > 0 else { throw FeedPlanError.nonPositivePolicyVersion(version) }
        guard cardLimit > 0 else { throw FeedPlanError.nonPositiveBudgetComponent("cardLimit", cardLimit) }
        guard oversampleFactor > 0 else {
            throw FeedPlanError.nonPositiveBudgetComponent("oversampleFactor", oversampleFactor)
        }
        guard poolLimit > 0 else { throw FeedPlanError.nonPositiveBudgetComponent("poolLimit", poolLimit) }
        guard scanRowsPerStep > 0 else {
            throw FeedPlanError.nonPositiveBudgetComponent("scanRowsPerStep", scanRowsPerStep)
        }
        guard maxScanSteps > 0 else {
            throw FeedPlanError.nonPositiveBudgetComponent("maxScanSteps", maxScanSteps)
        }
        guard providerQuota > 0 else {
            throw FeedPlanError.nonPositiveBudgetComponent("providerQuota", providerQuota)
        }
        guard diversityTarget > 0 else {
            throw FeedPlanError.nonPositiveBudgetComponent("diversityTarget", diversityTarget)
        }
        guard poolLimit >= cardLimit else {
            throw FeedPlanError.poolSmallerThanCardLimit(cardLimit: cardLimit, poolLimit: poolLimit)
        }
        self.version = version
        self.cardLimit = cardLimit
        self.oversampleFactor = oversampleFactor
        self.poolLimit = poolLimit
        self.scanRowsPerStep = scanRowsPerStep
        self.maxScanSteps = maxScanSteps
        self.providerQuota = providerQuota
        self.diversityTarget = diversityTarget
    }

    /// 24 cards, oversampling 4×, pool 96, scan step `poolLimit * 16` and three bounded steps.
    public static let initial = SelectionBudget(
        uncheckedVersion: currentVersion,
        cardLimit: 24,
        oversampleFactor: 4,
        poolLimit: 96,
        scanRowsPerStep: 96 * 16,
        maxScanSteps: 3,
        providerQuota: 8,
        diversityTarget: 4
    )

    /// Only for compile-time constants in this file: every component is asserted by
    /// `PlanResolverTests.testInitialBudgetMatchesThePlanHypothesis`.
    private init(
        uncheckedVersion version: Int,
        cardLimit: Int,
        oversampleFactor: Int,
        poolLimit: Int,
        scanRowsPerStep: Int,
        maxScanSteps: Int,
        providerQuota: Int,
        diversityTarget: Int
    ) {
        self.version = version
        self.cardLimit = cardLimit
        self.oversampleFactor = oversampleFactor
        self.poolLimit = poolLimit
        self.scanRowsPerStep = scanRowsPerStep
        self.maxScanSteps = maxScanSteps
        self.providerQuota = providerQuota
        self.diversityTarget = diversityTarget
    }
}

/// The editorial clock policy. The clock itself is an injected port (`EditorialClock`); this policy
/// owns the bucket resolution that turns a reading into the `editorialClockBucket` input (D10). A
/// bucket rollover makes a new revision *eligible*; it never aborts an in-flight draft.
public struct ClockPolicy: Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let bucketResolutionSeconds: Int

    public init(version: Int = ClockPolicy.currentVersion, bucketResolutionSeconds: Int) throws {
        guard version > 0 else { throw FeedPlanError.nonPositivePolicyVersion(version) }
        guard bucketResolutionSeconds > 0 else {
            throw FeedPlanError.nonPositiveClockResolution(bucketResolutionSeconds)
        }
        self.version = version
        self.bucketResolutionSeconds = bucketResolutionSeconds
    }

    public static let fiveMinutes = ClockPolicy(uncheckedVersion: currentVersion, bucketResolutionSeconds: 300)

    /// For the compile-time constant above; the public initializer validates every caller's value.
    private init(uncheckedVersion version: Int, bucketResolutionSeconds: Int) {
        self.version = version
        self.bucketResolutionSeconds = bucketResolutionSeconds
    }

    /// Epoch-relative and timezone-independent: the bucket depends on the instant, never on the
    /// device's timezone or locale.
    public func bucket(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / Double(bucketResolutionSeconds)).rounded(.down))
    }
}

/// The bounded-repetition rule of plan §8: a defined window, a defined counter and a distinct
/// published occurrence.
public struct RepetitionPolicy: Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    /// How many of the most recently published occurrences the counter looks at.
    public let window: Int
    /// How many occurrences of the same content item the window may hold.
    public let limit: Int
    /// Whether a *new* published occurrence of content already inside the window is allowed. When
    /// false, content seen inside the window is suppressed outright.
    public let allowsDistinctOccurrence: Bool

    public init(
        version: Int = RepetitionPolicy.currentVersion,
        window: Int,
        limit: Int,
        allowsDistinctOccurrence: Bool
    ) throws {
        guard version > 0 else { throw FeedPlanError.nonPositivePolicyVersion(version) }
        guard window > 0 else { throw FeedPlanError.nonPositiveRepetitionWindow(window) }
        guard limit > 0 else { throw FeedPlanError.nonPositiveRepetitionLimit(limit) }
        self.version = version
        self.window = window
        self.limit = limit
        self.allowsDistinctOccurrence = allowsDistinctOccurrence
    }

    public static let initial = RepetitionPolicy(
        uncheckedWindow: 48,
        limit: 2,
        allowsDistinctOccurrence: true
    )

    /// For the compile-time constant above; the public initializer validates every caller's value.
    private init(uncheckedWindow window: Int, limit: Int, allowsDistinctOccurrence: Bool) {
        self.version = Self.currentVersion
        self.window = window
        self.limit = limit
        self.allowsDistinctOccurrence = allowsDistinctOccurrence
    }
}

/// What the user asked for: anything the plan can find, or content that was not seen yet. Limited
/// repetition is forbidden in the second case (plan §8).
public enum FreshnessDemand: String, Hashable, Sendable, CaseIterable {
    case any
    case unseen
}

/// Exploration is per-edition randomness with a versioned weight, never a per-process value.
/// `weight == 0` (the default) makes the bias exactly zero, so ordering is seed-independent.
public struct ExplorationPolicy: Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let weight: Int

    public init(version: Int = ExplorationPolicy.currentVersion, weight: Int) throws {
        guard version > 0 else { throw FeedPlanError.nonPositivePolicyVersion(version) }
        guard weight >= 0 && weight <= SelectionScore.maximum else {
            throw FeedPlanError.preferenceWeightOutOfRange("exploration", weight)
        }
        self.version = version
        self.weight = weight
    }

    public static let disabled = ExplorationPolicy(uncheckedWeight: 0)

    /// For the compile-time constant above; the public initializer validates every caller's value.
    private init(uncheckedWeight weight: Int) {
        self.version = Self.currentVersion
        self.weight = weight
    }
}

// MARK: - History scope (ADR-007 D12)

/// Which surface's history a plan reads. The surfaces that must *not* apply `seen` are refused by the
/// resolver, so the ADR-007 matrix cannot be violated by a plan declaration.
public enum HistoryScope: Hashable, Sendable {
    case main
    case source(SourceID)
    case bookmark(listKey: String?)
    case search
    case collection(key: String)
    case smartFeed(key: String)
    /// What's New selects on its own baseline, never on another surface's `seen`.
    case whatsNew
    /// The onboarding showcase: samples appear whatever was seen elsewhere.
    case onboarding
    /// One saved search's own results.
    case persistentSearch(key: String)
    /// The reader's click history: navigable, so `seen` never removes an entry.
    case lastClicked

    /// The surface the scope belongs to. Used to enforce the ADR-007 D12 matrix.
    public var surface: ContextKey.Surface {
        switch self {
        case .main: return .main
        case .source: return .source
        case .bookmark: return .bookmarks
        case .search: return .search
        case .collection: return .collection
        case .smartFeed: return .smartFeed
        case .whatsNew: return .whatsNew
        case .onboarding: return .onboarding
        case .persistentSearch: return .persistentSearch
        case .lastClicked: return .lastClicked
        }
    }

    /// ADR-007 D12: `seen` may be applied only where the matrix says so. Main and the declared
    /// per-collection/per-smart-feed scopes may exclude; source, bookmark, search, the saved
    /// searches, What's New, the onboarding showcase and the click history may not.
    public var allowsSeenExclusion: Bool {
        switch self {
        case .main, .collection, .smartFeed: return true
        case .source, .bookmark, .search, .whatsNew, .onboarding, .persistentSearch, .lastClicked:
            return false
        }
    }
}

/// The kinds of durable subject the reader's own actions produce.
///
/// It lives in the domain because a plan states which of them selects its cards, and because the
/// storage's projection and the runtime's query must not each name the concept: before this, the kind
/// was a nested type of the projection store, and a plan could not name one at all.
public enum SubjectKind: String, Sendable, CaseIterable, Hashable {
    case bookmark
    /// One subject the reader read, as the durable user-state port wrote it (ADR-007 D5/D7).
    ///
    /// It is the runtime's own projection of the read intent, not the read state itself: the history
    /// projection's `read_at_ms` is the card's state per `HistoryScope`, and the exposure fact keyed by
    /// the same operation id is its record. Retention reads only `kind = 'bookmark'` rows, so a read row
    /// is neither a root nor a blocker.
    case read
}

/// The reader's own subjects as a card selection (ADR-002 D4: a plan input, so it is serialized).
///
/// A surface whose cards are the reader's saved rows — a bookmark box — selects on no source at all:
/// its set is the durable projection of what the reader did, resolved through the alias that names the
/// canonical record each subject is. A *box* is one list's membership, and that is what the list key
/// states; the projection carries it because `user_state_projection` is one row per subject and has no
/// room for a per-list fact (`baseline.md` §8.58).
public enum SubjectSelection: Hashable, Sendable {
    /// The reader's own saved subjects of this kind — the whole saved set when `listKey` is `nil`, and
    /// one box's membership when it is not.
    ///
    /// A box's content is *that list's* membership (`bookmark_item(list_id, item_id)`), not every saved
    /// card: `selectedBookmarkListID`'s setter loads the box, and a named box holds what was filed into
    /// it (baseline §8.58). A list key the projection has no rows for matches nothing, which is the
    /// honest answer for a box nobody has saved into.
    case savedSubjects(kind: SubjectKind, listKey: String?)

    /// The canonical serialization of the selection, in the plan's field vocabulary.
    var canonicalTag: String {
        switch self {
        case .savedSubjects(let kind, let listKey):
            return "savedSubjects:\(kind.rawValue):\(listKey ?? "-")"
        }
    }
}

/// The declared history policy of one plan (`history_policy` in ADR-007, versioned, and the
/// `exclusionPolicyVersion` input of ADR-002 D4).
public struct HistoryPolicy: Hashable, Sendable {
    public let scope: HistoryScope
    /// D12: Main excludes cards seen in Main; Source/Bookmark/Search do not.
    public let applySeen: Bool
    /// A surface that does not exclude must still be able to show the overlay.
    public let showOverlay: Bool
    public let autoExclude: Bool
    public let version: Int

    public init(
        scope: HistoryScope,
        applySeen: Bool,
        showOverlay: Bool,
        autoExclude: Bool,
        version: Int
    ) throws {
        guard version > 0 else { throw FeedPlanError.nonPositivePolicyVersion(version) }
        self.scope = scope
        self.applySeen = applySeen
        self.showOverlay = showOverlay
        self.autoExclude = autoExclude
        self.version = version
    }
}

// MARK: - Plan projections (ADR-002 D6)

/// The plan-relevant catalogue projection: the durable source keys the catalogue currently resolves,
/// sorted and unique.
public struct PlanCatalogProjection: Hashable, Sendable {
    public let resolvedSources: [EditorialSourceKey]

    public init(resolvedSources: [EditorialSourceKey]) {
        self.resolvedSources = Self.canonicalOrder(resolvedSources)
    }

    public static func canonicalOrder(_ values: [EditorialSourceKey]) -> [EditorialSourceKey] {
        var seen = Set<String>()
        return values
            .sorted {
                ($0.catalogIdentity, $0.canonicalizationVersion)
                    < ($1.catalogIdentity, $1.canonicalizationVersion)
            }
            .filter { seen.insert($0.catalogIdentity).inserted }
    }
}

/// The plan-relevant user-state projection: exactly the exclusion keys the plan's history scope
/// reads, sorted and unique. This is the *projection*, never the `UserStateRevision` counter (D6).
public struct PlanUserStateProjection: Hashable, Sendable {
    public let exclusionKeys: [SupplyStableKey]

    public init(exclusionKeys: [SupplyStableKey]) {
        self.exclusionKeys = exclusionKeys.sorted()
    }
}

public struct PlanProjections: Hashable, Sendable {
    public let catalog: PlanCatalogProjection
    public let userState: PlanUserStateProjection

    public init(catalog: PlanCatalogProjection, userState: PlanUserStateProjection) {
        self.catalog = catalog
        self.userState = userState
    }

    public static let empty = PlanProjections(
        catalog: PlanCatalogProjection(resolvedSources: []),
        userState: PlanUserStateProjection(exclusionKeys: [])
    )

    /// D6: the digest of exactly the projection the resolved plan reads, and of nothing else. A plan
    /// whose history policy does not apply `seen` reads no user-state key for eligibility, so a
    /// bookmark toggled on an unrelated card cannot change its revision — and a plan that *does* apply
    /// `seen` changes its revision when the exclusion projection changes.
    public func digests(readsUserState: Bool) -> PlanProjectionDigests {
        var catalogWriter = CanonicalSerialization()
        catalogWriter.list("resolvedSources", catalog.resolvedSources.map { key in
            CanonicalSerialization.element { element in
                element.string("sourceKey", key.catalogIdentity)
                element.integer("canonicalizationVersion", Int64(key.canonicalizationVersion))
            }
        })
        var userWriter = CanonicalSerialization()
        userWriter.list(
            "exclusionKeys",
            (readsUserState ? userState.exclusionKeys : []).map { Data($0.canonical.utf8) }
        )
        return PlanProjectionDigests(
            catalog: EditorialSHA256.hex(of: catalogWriter.data),
            userState: EditorialSHA256.hex(of: userWriter.data)
        )
    }
}

public struct PlanProjectionDigests: Hashable, Sendable {
    public let catalog: String
    public let userState: String
}

// MARK: - The plan

/// The immutable contract of one selection run: what the caller declares as the plan schema and the
/// algorithm it wants. A plan that declares an unsupported version is refused, never interpreted.
public enum SelectionContract {
    public static let planSchemaVersion = 1
    public static let algorithmVersion = 1
    public static let schemaVersion = 1
}

/// What the product asks for, before resolution (plan §8).
public struct FeedPlan: Hashable, Sendable {
    public let context: ContextKey
    public let planSchemaVersion: Int
    /// Declared `(policyID, version)` pairs covering every value-carrying policy below.
    public let policies: [PolicyVersion]
    public let algorithmVersion: Int
    public let selectionSchemaVersion: Int
    public let sourceSelection: [SourceSelection]
    /// The reader's own subjects as this plan's card selection, when its cards are not a source's
    /// supply. `nil` is a plan over every record the source selection admits — the shape every plan had
    /// before this field existed. A selection the runtime cannot resolve (`none`) composes an empty
    /// page rather than the whole supply.
    public let subjectSelection: SubjectSelection?
    public let presetIdentity: String
    public let region: String
    public let contentType: String
    public let languages: [String]
    public let mood: String
    public let contentFilters: [ContentFilter]
    public let taxonomyURLs: [String]
    /// Explicit blocks: durable content keys the user refuses. Hard eligibility, never relaxed.
    public let blockedStableKeys: [SupplyStableKey]
    public let contentRestrictions: ContentRestrictionPolicy
    public let preferences: ContentPreferencePolicy
    public let budget: SelectionBudget
    public let historyPolicy: HistoryPolicy
    public let repetitionPolicy: RepetitionPolicy
    public let clockPolicy: ClockPolicy
    public let freshnessDemand: FreshnessDemand
    public let exploration: ExplorationPolicy

    public init(
        context: ContextKey,
        planSchemaVersion: Int = SelectionContract.planSchemaVersion,
        policies: [PolicyVersion],
        algorithmVersion: Int = SelectionContract.algorithmVersion,
        selectionSchemaVersion: Int = SelectionContract.schemaVersion,
        sourceSelection: [SourceSelection] = [],
        subjectSelection: SubjectSelection? = nil,
        presetIdentity: String = "",
        region: String = "",
        contentType: String = "",
        languages: [String] = [],
        mood: String = "",
        contentFilters: [ContentFilter] = [],
        taxonomyURLs: [String] = [],
        blockedStableKeys: [SupplyStableKey] = [],
        contentRestrictions: ContentRestrictionPolicy = ContentRestrictionPolicy.none,
        preferences: ContentPreferencePolicy = ContentPreferencePolicy.none,
        budget: SelectionBudget = SelectionBudget.initial,
        historyPolicy: HistoryPolicy,
        repetitionPolicy: RepetitionPolicy = RepetitionPolicy.initial,
        clockPolicy: ClockPolicy = ClockPolicy.fiveMinutes,
        freshnessDemand: FreshnessDemand = .any,
        exploration: ExplorationPolicy = ExplorationPolicy.disabled
    ) {
        self.context = context
        self.planSchemaVersion = planSchemaVersion
        self.policies = policies
        self.algorithmVersion = algorithmVersion
        self.selectionSchemaVersion = selectionSchemaVersion
        self.sourceSelection = sourceSelection
        self.subjectSelection = subjectSelection
        self.presetIdentity = presetIdentity
        self.region = region
        self.contentType = contentType
        self.languages = languages
        self.mood = mood
        self.contentFilters = contentFilters
        self.taxonomyURLs = taxonomyURLs
        self.blockedStableKeys = blockedStableKeys
        self.contentRestrictions = contentRestrictions
        self.preferences = preferences
        self.budget = budget
        self.historyPolicy = historyPolicy
        self.repetitionPolicy = repetitionPolicy
        self.clockPolicy = clockPolicy
        self.freshnessDemand = freshnessDemand
        self.exploration = exploration
    }
}

/// The resolved plan: the effective inputs in canonical order plus the revision they fingerprint.
///
/// The engine evaluates *this*, and only this: eligibility, scores and order come from the same values
/// the revision was computed from (ADR-002 D2).
public struct ResolvedFeedPlan: Hashable, Sendable {
    /// Canonical plan: sources, filters, preferences, restrictions and blocks are sorted, and every
    /// declared policy version matches its embedded value.
    public let plan: FeedPlan
    public let editorialRevision: EditorialRevision
    public let editorialClockBucket: Int64
    public let relevantCatalogDigest: String
    public let relevantUserStateDigest: String

    public init(
        plan: FeedPlan,
        editorialRevision: EditorialRevision,
        editorialClockBucket: Int64,
        relevantCatalogDigest: String,
        relevantUserStateDigest: String
    ) {
        self.plan = plan
        self.editorialRevision = editorialRevision
        self.editorialClockBucket = editorialClockBucket
        self.relevantCatalogDigest = relevantCatalogDigest
        self.relevantUserStateDigest = relevantUserStateDigest
    }

    public var context: ContextKey { plan.context }
    public var budget: SelectionBudget { plan.budget }
    public var historyPolicy: HistoryPolicy { plan.historyPolicy }
    public var repetitionPolicy: RepetitionPolicy { plan.repetitionPolicy }
    /// The reader's own subjects as this plan's card selection, when its cards are not a source's supply.
    ///
    /// Forwarded because the *composer* reads it: a plan that selects the reader's own saved set is exempt
    /// from the repetition window, which would otherwise suppress the whole page the context had just
    /// published (measured on a bookmark box, baseline §8.62).
    public var subjectSelection: SubjectSelection? { plan.subjectSelection }
    public var freshnessDemand: FreshnessDemand { plan.freshnessDemand }

    /// The effective inputs of this plan, ready for `EditorialRevision.canonicalSerialization` — the value
    /// ADR-002's `editorial_revision.canonical_inputs` column persists for audit and replay. Selection
    /// recomputes it from the projections it is about to evaluate (see `FeedPlanResolver.recomputedRevision`)
    /// and refuses to run when it does not reproduce `editorialRevision`.
    public func editorialInputs() -> EditorialInputs {
        EditorialInputs(
            plan: plan,
            relevantCatalogDigest: relevantCatalogDigest,
            relevantUserStateDigest: relevantUserStateDigest,
            editorialClockBucket: editorialClockBucket
        )
    }
}
