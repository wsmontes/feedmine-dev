import Foundation

/// The selection read model, the draft and the editorial sequence (plan §8, ADR-002 D2).
///
/// These are the values the concrete supply repository (`FeedStorage`) returns and the values
/// `SelectionEngine`/`EditorialSequencer` produce. They are `Sendable` and comparable across two
/// independently built databases: every identity that decides an order or a comparison is a durable
/// key, never an autoincrement row id.

// MARK: - Durable keys

/// Durable identity of one selectable content item: the external key of the record's primary identity
/// (ADR-003 D8). Local row ids are deliberately absent, so two databases built from the same fixture
/// produce the same sequence and the same draft export.
public struct SupplyStableKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let namespace: ConnectorNamespace
    public let scopeKey: String
    public let objectKeyBytes: Data

    public init(namespace: ConnectorNamespace, scopeKey: String, objectKeyBytes: Data) {
        self.namespace = namespace
        self.scopeKey = scopeKey
        self.objectKeyBytes = objectKeyBytes
    }

    /// Canonical text form: the namespace and the scope are opaque and are never merged, so the
    /// separator is a display convenience, not an identity rule.
    public var canonical: String {
        "\(namespace.rawValue)|\(scopeKey)|\(objectKeyBytes.base64EncodedString())"
    }

    public var description: String { canonical }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.namespace.rawValue != rhs.namespace.rawValue {
            return lhs.namespace.rawValue < rhs.namespace.rawValue
        }
        if lhs.scopeKey != rhs.scopeKey { return lhs.scopeKey < rhs.scopeKey }
        return bytesPrecede(lhs.objectKeyBytes, rhs.objectKeyBytes)
    }

    /// Byte order over the full key. Any total order would do; byte order is the one that does not
    /// depend on a locale, a hash seed or a dictionary.
    static func bytesPrecede(_ lhs: Data, _ rhs: Data) -> Bool {
        var left = lhs.makeIterator()
        var right = rhs.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil):
                return false
            case (nil, _):
                return true
            case (_, nil):
                return false
            case let (l?, r?):
                if l != r { return l < r }
            }
        }
    }
}

/// Durable identity of an attribution/authorship entity: `(connector namespace, provider key)`
/// (ADR-003 D5). One source legitimately contains several providers.
public struct ProviderStableKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let namespace: ConnectorNamespace
    public let providerKey: String

    public init(namespace: ConnectorNamespace, providerKey: String) {
        self.namespace = namespace
        self.providerKey = providerKey
    }

    public var canonical: String { "\(namespace.rawValue)|\(providerKey)" }
    public var description: String { canonical }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.namespace.rawValue != rhs.namespace.rawValue {
            return lhs.namespace.rawValue < rhs.namespace.rawValue
        }
        return lhs.providerKey < rhs.providerKey
    }
}

/// What a quota counts: the provider when the revision declares a primary attribution, otherwise the
/// source (ADR-003 D5: provider is attribution, source is editorial grouping). Never a row id.
public enum QuotaKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    case provider(ProviderStableKey)
    case source(EditorialSourceKey)

    public var canonical: String {
        switch self {
        case let .provider(key): return "provider:\(key.canonical)"
        case let .source(key): return "source:\(key.catalogIdentity)@\(key.canonicalizationVersion)"
        }
    }

    public var description: String { canonical }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.canonical < rhs.canonical }
}

// MARK: - Ranking

/// The normalized score of one candidate: explicit components, never an opaque number.
public struct SelectionScore: Hashable, Sendable {
    public static let maximum = 1000
    /// Every candidate starts here, so a score of zero means "fully demoted", not "no base".
    public static let base = 500

    public let base: Int
    public let preferenceBonus: Int
    public let explorationBonus: Int
    /// `min(base + preferenceBonus + explorationBonus, maximum)`. The *normalized* value is what the
    /// order compares first (plan §8).
    public let normalized: Int
    /// Preference ids that were satisfied, sorted. A dictionary never decides this order.
    public let matchedPreferences: [String]
    public let isExploration: Bool

    public init(
        base: Int = SelectionScore.base,
        preferenceBonus: Int,
        explorationBonus: Int,
        matchedPreferences: [String],
        isExploration: Bool
    ) {
        self.base = base
        self.preferenceBonus = preferenceBonus
        self.explorationBonus = explorationBonus
        self.normalized = min(base + preferenceBonus + explorationBonus, SelectionScore.maximum)
        self.matchedPreferences = matchedPreferences.sorted()
        self.isExploration = isExploration
    }
}

/// The total order plan §8 defines: normalized score, then timestamp, then stable key.
///
/// It is a value, computed once per candidate and reused by the engine's ranking and the sequencer's
/// walk, so there is exactly one ordering rule in the runtime.
public struct SelectionOrderKey: Hashable, Sendable, Comparable {
    public let score: Int
    public let sortDateMilliseconds: Int64
    public let stableKey: SupplyStableKey

    public init(score: Int, sortDate: Date, stableKey: SupplyStableKey) {
        self.score = score
        self.sortDateMilliseconds = Int64((sortDate.timeIntervalSince1970 * 1000).rounded())
        self.stableKey = stableKey
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.sortDateMilliseconds != rhs.sortDateMilliseconds {
            return lhs.sortDateMilliseconds > rhs.sortDateMilliseconds
        }
        return lhs.stableKey < rhs.stableKey
    }
}

// MARK: - Supply read model

/// One eligible row of `selection_supply`: the canonical projection Selection is allowed to read.
///
/// It carries no connector evidence, no protocol JSON and no raw payload: the columns behind it are
/// `selection_supply`, `origin_record`, `origin_revision` and `external_identity` (plan §7, I-03).
public struct SupplyCandidate: Hashable, Sendable {
    public let stableKey: SupplyStableKey
    public let originRecordID: OriginRecordID
    public let originRevisionID: OriginRevisionID
    /// Lowercase hex of the canonical payload digest (ADR-003 D11), used by tests and audits to compare
    /// two databases without comparing row ids.
    public let payloadDigestHex: String
    public let sourceKey: EditorialSourceKey
    public let providerKey: ProviderStableKey?
    /// Distinct media roles the revision declares, sorted (plan §6 canonical group).
    public let mediaRoles: [MediaRole]
    /// Headline plus summary, the text a keyword filter or preference matches (never the body).
    public let filterText: String
    public let observedAt: Date
    /// The declared authored date when there is one, otherwise the observation time (ADR-003 D17).
    public let sortDate: Date
    public let sortDateIsFallback: Bool
    public let sortDatePolicyVersion: Int

    public init(
        stableKey: SupplyStableKey,
        originRecordID: OriginRecordID,
        originRevisionID: OriginRevisionID,
        payloadDigestHex: String,
        sourceKey: EditorialSourceKey,
        providerKey: ProviderStableKey?,
        mediaRoles: [MediaRole],
        filterText: String,
        observedAt: Date,
        sortDate: Date,
        sortDateIsFallback: Bool,
        sortDatePolicyVersion: Int
    ) {
        self.stableKey = stableKey
        self.originRecordID = originRecordID
        self.originRevisionID = originRevisionID
        self.payloadDigestHex = payloadDigestHex
        self.sourceKey = sourceKey
        self.providerKey = providerKey
        self.mediaRoles = mediaRoles.sorted { $0.rawValue < $1.rawValue }
        self.filterText = filterText
        self.observedAt = observedAt
        self.sortDate = sortDate
        self.sortDateIsFallback = sortDateIsFallback
        self.sortDatePolicyVersion = sortDatePolicyVersion
    }

    public var quotaKey: QuotaKey {
        if let providerKey { return .provider(providerKey) }
        return .source(sourceKey)
    }

    /// Lowercased text for keyword matching. The plan's keywords are resolved values; matching is
    /// case-insensitive on a stable, locale-independent transformation.
    public var searchableText: String { filterText.lowercased() }
}

/// One declared duplicate/syndication edge (`content_relation` with a syndication verb), expressed in
/// durable keys so a cluster grouping is comparable across databases.
public struct SupplyClusterEdge: Hashable, Sendable {
    public enum Verb: String, Hashable, Sendable, CaseIterable {
        case repostOf
        case quoteOf
    }

    public let subject: SupplyStableKey
    public let object: SupplyStableKey
    public let verb: Verb

    public init(subject: SupplyStableKey, object: SupplyStableKey, verb: Verb) {
        self.subject = subject
        self.object = object
        self.verb = verb
    }
}

/// One pool-local cluster: the set of records the declared edges connect.
///
/// Clustering never merges identity: it is a relation over records that keep their own ids and
/// revisions, and dropping the edges splits it back (ADR-003 D13, invariant 15).
public struct SupplyCluster: Hashable, Sendable {
    public let members: [SupplyStableKey]

    public init(members: [SupplyStableKey]) {
        self.members = members.sorted()
    }

    /// The deterministic representative of the cluster: its smallest durable key. Never the first
    /// element of a `Set` or the lowest row id.
    public var representative: SupplyStableKey? { members.first }

    public func key(for member: SupplyStableKey) -> SupplyStableKey {
        members.first ?? member
    }
}

// MARK: - Draft

/// Why a candidate was admitted although a policy would have preferred otherwise (plan §8).
public struct RelaxationReason: Hashable, Sendable, Comparable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        /// A preference marked `soft` was not satisfied.
        case softPreference
        /// A content filter that is not mandatory matched: it excludes while supply is plentiful and
        /// relaxes only when the pool cannot otherwise be filled.
        case softFilter
        /// The candidate exceeded the provider/cluster quota in the segment prefix and was published
        /// in the deferred pass instead.
        case providerQuota
    }

    public let kind: Kind
    /// The preference id, or the quota key that was exceeded.
    public let policyID: String

    public init(kind: Kind, policyID: String) {
        self.kind = kind
        self.policyID = policyID
    }

    public var canonical: String { "\(kind.rawValue):\(policyID)" }
    public var description: String { canonical }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.canonical < rhs.canonical }
}

/// One candidate the draft decided to keep, with the exact revisions and the score that justify it.
public struct SelectionChoice: Hashable, Sendable {
    public let candidate: SupplyCandidate
    public let score: SelectionScore
    public let orderKey: SelectionOrderKey
    /// Cluster representative (durable). Equal to the candidate's own key when it has no declared edge.
    public let clusterKey: SupplyStableKey
    /// Sorted, canonical relaxation reasons. Empty for a strict choice.
    public let relaxationReasons: [RelaxationReason]

    public init(
        candidate: SupplyCandidate,
        score: SelectionScore,
        orderKey: SelectionOrderKey,
        clusterKey: SupplyStableKey,
        relaxationReasons: [RelaxationReason]
    ) {
        self.candidate = candidate
        self.score = score
        self.orderKey = orderKey
        self.clusterKey = clusterKey
        self.relaxationReasons = relaxationReasons.sorted()
    }

    public var stableKey: SupplyStableKey { candidate.stableKey }
    public var originRevisionID: OriginRevisionID { candidate.originRevisionID }
    public var originRecordID: OriginRecordID { candidate.originRecordID }
}

/// What the supply read cost, measured by SQLite rather than estimated (plan §8: `LIMIT` limits the
/// result, not the cost).
public struct SelectionReadReport: Hashable, Sendable {
    public let poolLimit: Int
    public let pages: Int
    public let steps: Int
    /// Rows of `selection_supply` inside the primary-key windows the walk consumed. Measured with a
    /// range count over the same window the page query evaluated.
    public let examinedRows: Int
    public let stepWindowRows: [Int]
    public let supplyExhausted: Bool
    public let scanBudgetReached: Bool
    /// `EXPLAIN QUERY PLAN` lines of the page query, verbatim.
    public let queryPlan: [String]

    public init(
        poolLimit: Int,
        pages: Int,
        steps: Int,
        examinedRows: Int,
        stepWindowRows: [Int],
        supplyExhausted: Bool,
        scanBudgetReached: Bool,
        queryPlan: [String]
    ) {
        self.poolLimit = poolLimit
        self.pages = pages
        self.steps = steps
        self.examinedRows = examinedRows
        self.stepWindowRows = stepWindowRows
        self.supplyExhausted = supplyExhausted
        self.scanBudgetReached = scanBudgetReached
        self.queryPlan = queryPlan
    }
}

/// The exportable record of one selection decision (plan §8): chosen candidates with their exact
/// revisions, scores, relaxation reasons, seed, versions and the supply generation they were read
/// against.
///
/// `canonicalSerialization` is the semantic export: durable keys, normalized payload digests, scores,
/// dates and versions — never a local row id, so two databases compare byte for byte.
public struct SelectionDraft: Hashable, Sendable {
    public let context: ContextKey
    public let editorialRevision: EditorialRevision
    public let algorithmVersion: Int
    public let selectionSchemaVersion: Int
    public let supplyGeneration: UInt64
    public let seed: Data
    /// Ordered by `SelectionOrderKey`, never longer than the plan's pool limit.
    public let choices: [SelectionChoice]
    public let clusters: [SupplyCluster]
    public let readReport: SelectionReadReport
    /// Candidates that satisfied every hard rule and every preference, before any soft relaxation.
    public let strictChoiceCount: Int
    public let supplyExhausted: Bool

    public init(
        context: ContextKey,
        editorialRevision: EditorialRevision,
        algorithmVersion: Int,
        selectionSchemaVersion: Int,
        supplyGeneration: UInt64,
        seed: Data,
        choices: [SelectionChoice],
        clusters: [SupplyCluster],
        readReport: SelectionReadReport,
        strictChoiceCount: Int,
        supplyExhausted: Bool
    ) {
        self.context = context
        self.editorialRevision = editorialRevision
        self.algorithmVersion = algorithmVersion
        self.selectionSchemaVersion = selectionSchemaVersion
        self.supplyGeneration = supplyGeneration
        self.seed = seed
        self.choices = choices
        self.clusters = clusters
        self.readReport = readReport
        self.strictChoiceCount = strictChoiceCount
        self.supplyExhausted = supplyExhausted
    }

    /// The relaxed preferences, sorted and deduplicated. A dictionary never decides this order.
    public var relaxedPreferences: [String] {
        relaxedIdentifiers(ofKind: .softPreference)
    }

    /// The relaxed non-mandatory content filters, sorted and deduplicated.
    public var relaxedFilters: [String] {
        relaxedIdentifiers(ofKind: .softFilter)
    }

    private func relaxedIdentifiers(ofKind kind: RelaxationReason.Kind) -> [String] {
        choices.flatMap { $0.relaxationReasons }
            .filter { $0.kind == kind }
            .map(\.policyID)
            .reduce(into: Set<String>()) { $0.insert($1) }
            .sorted()
    }

    /// Semantic export, stable across databases. Local row ids and the query plan are deliberately
    /// absent: they are diagnostics, not part of the decision.
    public var canonicalSerialization: Data {
        var writer = CanonicalSerialization()
        writer.string("context", context.canonicalSerialization)
        writer.integer("revisionSchemeVersion", Int64(editorialRevision.schemeVersion))
        writer.string("editorialRevision", editorialRevision.digest)
        writer.integer("algorithmVersion", Int64(algorithmVersion))
        writer.integer("selectionSchemaVersion", Int64(selectionSchemaVersion))
        writer.integer("supplyGeneration", Int64(supplyGeneration))
        writer.string("seed", seed.base64EncodedString())
        writer.integer("strictChoiceCount", Int64(strictChoiceCount))
        writer.boolean("supplyExhausted", supplyExhausted)
        writer.list("choices", choices.map { choice in
            CanonicalSerialization.element { element in
                element.string("stableKey", choice.stableKey.canonical)
                element.string("payloadDigest", choice.candidate.payloadDigestHex)
                element.string("sourceKey", choice.candidate.sourceKey.catalogIdentity)
                element.integer(
                    "sourceCanonicalizationVersion",
                    Int64(choice.candidate.sourceKey.canonicalizationVersion)
                )
                element.string("providerKey", choice.candidate.providerKey?.canonical ?? "")
                element.string("clusterKey", choice.clusterKey.canonical)
                element.list("mediaRoles", choice.candidate.mediaRoles.map { Data($0.rawValue.utf8) })
                element.integer("score", Int64(choice.orderKey.score))
                element.integer("sortDateMilliseconds", choice.orderKey.sortDateMilliseconds)
                element.string("quotaKey", choice.candidate.quotaKey.canonical)
                element.list("relaxations", choice.relaxationReasons.map { Data($0.canonical.utf8) })
            }
        })
        writer.list("clusters", clusters.map { cluster in
            CanonicalSerialization.element { element in
                element.list("members", cluster.members.map { Data($0.canonical.utf8) })
            }
        })
        return writer.data
    }
}

// MARK: - Published history (repetition window)

/// One already published occurrence. It is what the repetition window counts; the edition id makes the
/// occurrence distinct even when the content key repeats (plan §8).
public struct PublishedOccurrence: Hashable, Sendable {
    public let stableKey: SupplyStableKey
    public let editionID: EditionID
    public let ordinal: Int
    public let publishedAt: Date

    public init(stableKey: SupplyStableKey, editionID: EditionID, ordinal: Int, publishedAt: Date) {
        self.stableKey = stableKey
        self.editionID = editionID
        self.ordinal = ordinal
        self.publishedAt = publishedAt
    }
}

/// The published occurrences a plan may look back at, in publication order (oldest first). The caller
/// owns that order; the window is the last `size` entries of it.
public struct PublishedHistory: Hashable, Sendable {
    public let occurrences: [PublishedOccurrence]

    public init(occurrences: [PublishedOccurrence]) {
        self.occurrences = occurrences
    }

    public static let empty = PublishedHistory(occurrences: [])
}

// MARK: - Editorial sequence

/// One card of the editorial order, with the occurrence identity a repeat would need.
public struct PlannedCard: Hashable, Sendable {
    public let ordinal: Int
    public let choice: SelectionChoice
    /// True when this card is a new occurrence of content already inside the repetition window.
    public let isRepeatOccurrence: Bool
    public let previousOccurrenceEdition: EditionID?

    public init(
        ordinal: Int,
        choice: SelectionChoice,
        isRepeatOccurrence: Bool,
        previousOccurrenceEdition: EditionID?
    ) {
        self.ordinal = ordinal
        self.choice = choice
        self.isRepeatOccurrence = isRepeatOccurrence
        self.previousOccurrenceEdition = previousOccurrenceEdition
    }
}

/// Why a sequence published fewer cards than the plan asked for.
public enum SegmentShortfall: Hashable, Sendable {
    case supplyExhausted(published: Int, requested: Int)
    case scanBudgetReached(published: Int, requested: Int)
    case eligibilityFiltered(published: Int, requested: Int)
    case repetitionSuppressed(published: Int, requested: Int)

    public var published: Int {
        switch self {
        case let .supplyExhausted(published, _),
             let .scanBudgetReached(published, _),
             let .eligibilityFiltered(published, _),
             let .repetitionSuppressed(published, _):
            return published
        }
    }

    public var requested: Int {
        switch self {
        case let .supplyExhausted(_, requested),
             let .scanBudgetReached(_, requested),
             let .eligibilityFiltered(_, requested),
             let .repetitionSuppressed(_, requested):
            return requested
        }
    }
}

/// ADR-007 D13: exhaustion and degradation are *states*, never a history mutation and never a loop.
public enum SegmentStatus: Hashable, Sendable {
    case complete
    case partial(SegmentShortfall)
    case exhausted
}

/// Diagnostics of one composition. Every count is explicit so a plan can report why it published a
/// smaller segment instead of looping.
public struct EditorialSequenceCounts: Hashable, Sendable {
    public let clustersCollapsed: Int
    public let repetitionsSuppressed: Int
    public let unseenSuppressed: Int
    public let quotaDeferred: Int
    public let quotaAdmitted: Int

    public init(
        clustersCollapsed: Int,
        repetitionsSuppressed: Int,
        unseenSuppressed: Int,
        quotaDeferred: Int,
        quotaAdmitted: Int
    ) {
        self.clustersCollapsed = clustersCollapsed
        self.repetitionsSuppressed = repetitionsSuppressed
        self.unseenSuppressed = unseenSuppressed
        self.quotaDeferred = quotaDeferred
        self.quotaAdmitted = quotaAdmitted
    }
}

/// The ordered segment plan one draft produces. Publication (PR-06) freezes exactly this order.
public struct EditorialSequence: Hashable, Sendable {
    public let context: ContextKey
    public let editorialRevision: EditorialRevision
    public let seed: Data
    public let status: SegmentStatus
    public let cards: [PlannedCard]
    public let counts: EditorialSequenceCounts
    public let relaxations: [RelaxationReason]

    public init(
        context: ContextKey,
        editorialRevision: EditorialRevision,
        seed: Data,
        status: SegmentStatus,
        cards: [PlannedCard],
        counts: EditorialSequenceCounts,
        relaxations: [RelaxationReason]
    ) {
        self.context = context
        self.editorialRevision = editorialRevision
        self.seed = seed
        self.status = status
        self.cards = cards
        self.counts = counts
        self.relaxations = relaxations.sorted()
    }

    /// Semantic export: durable keys and ordinals only, so two databases compare byte for byte.
    public var canonicalSerialization: Data {
        var writer = CanonicalSerialization()
        writer.string("context", context.canonicalSerialization)
        writer.string("editorialRevision", editorialRevision.digest)
        writer.string("seed", seed.base64EncodedString())
        switch status {
        case .complete:
            writer.string("status", "complete")
        case .exhausted:
            writer.string("status", "exhausted")
        case let .partial(shortfall):
            writer.string("status", "partial:\(shortfall.published)/\(shortfall.requested)")
        }
        writer.list("cards", cards.map { card in
            CanonicalSerialization.element { element in
                element.integer("ordinal", Int64(card.ordinal))
                element.string("stableKey", card.choice.stableKey.canonical)
                element.string("clusterKey", card.choice.clusterKey.canonical)
                element.string("payloadDigest", card.choice.candidate.payloadDigestHex)
                element.boolean("isRepeatOccurrence", card.isRepeatOccurrence)
                element.string("previousOccurrenceEdition", card.previousOccurrenceEdition?.description ?? "")
            }
        })
        writer.list("relaxations", relaxations.map { Data($0.canonical.utf8) })
        return writer.data
    }
}
