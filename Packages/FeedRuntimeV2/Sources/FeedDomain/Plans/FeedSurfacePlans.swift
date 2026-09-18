import Foundation

/// The per-surface feed plans and the support matrix (plan §14 PR-14, `docs/runtime-v2/rollout.md` §2).
///
/// Every surface that renders feed content declares three things here and nowhere else: the plan
/// family it resolves, the `HistoryScope` it reads and writes, and which acquisition it is allowed to
/// use. The catalogue is the single statement the app's adapters, the tests and the rollout document
/// read, so a surface cannot acquire by one rule and be documented under another.
///
/// The rule the matrix exists to enforce is plan §14's gate: **no secondary surface has its own feed
/// engine.** A surface either uses the process's one feed engine (`FeedStore` → `RSSFetcher`), or it
/// is a local query that never reaches the network, or its one online demand is named as such and is
/// separate. Source search is a catalogue query; content search is the canonical FTS; the online
/// content sweep is an explicit, separate demand and never an implicit effect of the local search.

/// One app surface, as the support matrix enumerates it.
public enum FeedSurface: String, Hashable, Sendable, CaseIterable {
    case main
    case source
    case sourceCollection
    case bookmarks
    case search
    case smartFeed
    case persistentSearch
    case lastClicked
    case whatsNew
    case onboarding
    /// Source search and catalogue browsing (`CatalogExploreView`): a local read-only query over the
    /// managed catalogue file, with no editorial plan and no card history of its own.
    case catalogueBrowse
}

/// How a surface's cards are editorialized. Two surfaces share a family when they answer the same
/// editorial question, which is what lets the plan a surface resolves stay small.
public enum FeedSurfaceFamily: String, Hashable, Sendable, CaseIterable {
    /// Fresh, unseen supply across the enabled catalogue.
    case discovery
    /// An explicit source or the reader's own click history: the *complete* local record, never
    /// thinned by another surface's exposure.
    case navigableHistory
    /// One bookmark list, independent of whether its cards were seen anywhere.
    case bookmarkList
    /// Local search results, over the canonical content FTS.
    case searchResults
    /// A collection or a smart feed: a named preset over sources the user chose.
    case preset
    /// A finite showcase for the onboarding composer.
    case curatedPreview
    /// Content first observed after this surface's own baseline.
    case newContent
    /// A catalogue query: no cards are composed, so there is no plan and no history scope.
    case catalogueQuery
}

/// What a surface is allowed to acquire with.
public enum FeedSurfaceAcquisition: String, Hashable, Sendable, CaseIterable {
    /// The process's one feed engine acquires for this surface. The surface issues no request of its
    /// own; its demand is a claim in the shared ledger, so a URL another surface is already
    /// refilling is shared instead of fetched twice.
    case sharedFeedEngine
    /// A local, read-only catalogue query. Never a network request.
    case localCatalogueQuery
    /// A local, non-network content search. Never a network request.
    ///
    /// *Which* index a search reads is a migration-state fact, and PR-14 states it rather than assuming
    /// it. The canonical content index is `origin_search`, an FTS5 table over the current revision's
    /// `search_projection` (`FeedStorage/Migrations/RuntimeMigrations.swift`, written by
    /// `AdmissionEngine.refreshSupply`), and it is what the app's content search reads *exactly when the
    /// launch's runtime owns acquisition*: `RuntimeCompositionRoot.compose` composes the acquiring
    /// runtime for `v2Full` and for nothing else, and `MainFeedRuntime.startSession` installs the read
    /// path (`CanonicalSearchRepository`, behind `FeedStore.useCanonicalContentSearch`). In every other
    /// mode nothing admits into a runtime database, so the read stays on the legacy `feed_item_fts` over
    /// `feedmine.sqlite` (`feedmine/Services/SearchEngine.swift`). The mode decides the index; the index
    /// with rows never decides the mode, and there is no fallback between them.
    case localContentSearch
    /// The one online content demand: explicit, separate and opt-in. It is never an effect of the
    /// local search running, and it never replaces a local result.
    case explicitOnlineContentDemand
}

/// One row of the support matrix.
public struct FeedSurfacePlan: Hashable, Sendable {
    public let surface: FeedSurface
    public let family: FeedSurfaceFamily
    /// The editorial context this surface resolves a plan under, or `nil` when it composes no cards
    /// (catalogue browse).
    public let contextSurface: ContextKey.Surface?
    /// The acquisitions this surface may use, in order and unique. A row with two entries composes
    /// them: `search` searches locally and *separately* demands online content.
    public let acquisitions: [FeedSurfaceAcquisition]
    /// The process component that owns this surface's acquisition **in the modes whose legacy
    /// producers run** (`legacy`, `mirroredShadow`). `FeedStore` is the process's one legacy feed
    /// engine; the other owners never acquire feed content.
    ///
    /// It is no longer the whole answer, because a mode exists in which the runtime acquires: the Main
    /// Feed is `FeedStore`'s in `legacy` and the runtime's in `v2Full` (plan §13). Rather than let a
    /// single string mean "the owner" and be wrong in one mode or the other, the row states both, and
    /// `owner(legacyProducerClosed:)` is the only way to read it.
    public let owner: String
    /// The component that owns this surface's acquisition in a mode whose runtime owns it, or `nil`
    /// when the surface **acquires nothing at all** in that mode.
    ///
    /// `nil` is a statement, not a gap. In a `v2Full` launch the legacy producers are closed
    /// (`LegacyAcquisitionGate`) and the runtime acquires for the surfaces it serves — so a card surface
    /// with no runtime owner serves what the runtime has already admitted, and a surface whose
    /// acquisition is local is unaffected by construction. This slice moved the Main Feed and nothing
    /// else, so this field is also the honest count of what it did not move:
    /// `FeedSurfaceCatalog.surfacesWithoutRuntimeAcquisition`.
    /// The entry point the app calls for this surface.
    public let entryPoint: String
    /// How long a successful refill of a member endpoint satisfies this surface, in milliseconds.
    /// `nil` means "always refill": the surface needs current bytes (the bootstrap, the search sweep,
    /// the background drip) or has its own staleness policy (the Main Feed, a smart feed).
    public let refillFreshnessWindowMs: Int64?
    /// The owner in a mode whose runtime acquires, or `nil` when nothing acquires this surface there.
    /// A `var` with a default so the rows that did not move state nothing rather than restating a `nil`.
    public var runtimeOwner: String? = nil

    /// The owner in one mode's terms. This is how a caller (or a diagnostic) asks the question the
    /// matrix answers, so nobody has to remember which field applies to the mode it is in.
    public func acquisitionOwner(legacyProducerClosed: Bool) -> String {
        guard legacyProducerClosed else { return owner }
        if let runtimeOwner { return runtimeOwner }
        // A surface whose acquisitions are all local is unaffected by the legacy producers closing: a
        // catalogue query and the local content index are reads, not producers, and the gate refuses
        // requests rather than disabling the store. Its owner in this mode is the one it always had.
        return acquiresOverTheNetwork ? Self.noRuntimeOwner : owner
    }

    /// Whether this surface can start a request. `localCatalogueQuery` and `localContentSearch` are
    /// declared "never a network request", so a row that lists only those acquires nothing anywhere.
    public var acquiresOverTheNetwork: Bool {
        acquisitions.contains { $0 == .sharedFeedEngine || $0 == .explicitOnlineContentDemand }
    }

    /// What `acquisitionOwner(legacyProducerClosed: true)` answers for a surface the runtime does not
    /// acquire for. It names the mechanism instead of being empty, because "nothing acquires this here"
    /// is the fact and an empty string would read as an omission.
    public static let noRuntimeOwner =
        "none: the legacy producer is closed in this mode and the runtime acquires for another surface"

    /// The scope key a surface uses when it has no narrower durable key.
    ///
    /// `ContextKey` refuses an empty scope key (an empty identity is not an identity), while a scope
    /// can legitimately be "all of them": `HistoryScope.bookmark(listKey: nil)` is the default list.
    /// This literal is how the two rules meet, and it is named once so a caller cannot invent its own.
    public static let allScopesKey = "all"

    /// The history scope for one scope key.
    ///
    /// The scope names a durable identity, so a surface whose scope is a *runtime* identity cannot be
    /// given one here: `source` throws `runtimeIdentityUnavailable` unless the caller supplies the
    /// allocated `SourceID`, because ADR-003 D2/D18 forbid deriving a runtime identity from a
    /// catalogue id or a URL. That refusal is the reason the Source surface's plan is not migrated in
    /// PR-14, and it is stated rather than approximated.
    ///
    /// For `bookmarks`, `allScopesKey` means the default list (`listKey: nil`); any other scope key is
    /// the list key itself.
    public func historyScope(scopeKey: String, runtimeSourceID: SourceID? = nil) throws -> HistoryScope {
        switch surface {
        case .main:
            return .main
        case .source:
            guard let runtimeSourceID else {
                throw FeedSurfacePlanError.runtimeIdentityUnavailable(.source)
            }
            return .source(runtimeSourceID)
        case .sourceCollection:
            return .collection(key: scopeKey)
        case .bookmarks:
            return .bookmark(listKey: scopeKey == Self.allScopesKey ? nil : scopeKey)
        case .search:
            return .search
        case .smartFeed:
            return .smartFeed(key: scopeKey)
        case .persistentSearch:
            return .persistentSearch(key: scopeKey)
        case .lastClicked:
            return .lastClicked
        case .whatsNew:
            return .whatsNew
        case .onboarding:
            return .onboarding
        case .catalogueBrowse:
            throw FeedSurfacePlanError.surfaceComposesNoFeed(.catalogueBrowse)
        }
    }

    /// The history policy this surface declares. `applySeen` is derived from the ADR-007 D12 matrix
    /// and never declared twice: a surface whose scope may not exclude by `seen` cannot be given a
    /// policy that does, because this function is the only way the catalogue builds one.
    public func historyPolicy(scopeKey: String, runtimeSourceID: SourceID? = nil) throws -> HistoryPolicy {
        let scope = try historyScope(scopeKey: scopeKey, runtimeSourceID: runtimeSourceID)
        return try HistoryPolicy(
            scope: scope,
            applySeen: scope.allowsSeenExclusion,
            showOverlay: true,
            autoExclude: scope.allowsSeenExclusion,
            version: Self.historyPolicyVersion
        )
    }

    public static let historyPolicyVersion = 1
}

public enum FeedSurfacePlanError: Error, Equatable, Sendable {
    /// The surface's history scope is a runtime identity and no allocated value was supplied.
    case runtimeIdentityUnavailable(FeedSurface)
    /// The surface composes no cards, so it has no plan and no history scope.
    case surfaceComposesNoFeed(FeedSurface)
    /// The surface's plan needs an editorial context and the row declares none.
    case surfaceHasNoContext(FeedSurface)
}

/// The support matrix (plan §14 PR-14 item 1; `docs/runtime-v2/rollout.md` §2 and §4).
///
/// Eleven rows, and no surface outside them: a surface that renders feed content and is not here is a
/// surface nobody migrated, which PR-15 would turn into an empty feed. `FeedSurfaceCatalog.validate()`
/// is what makes that a failing test rather than a discovery in production.
public enum FeedSurfaceCatalog {

    public static let matrix: [FeedSurfacePlan] = [
        FeedSurfacePlan(
            surface: .main,
            family: .discovery,
            contextSurface: .main,
            acquisitions: [.sharedFeedEngine],
            owner: "FeedStore",
            entryPoint: "FeedLoader.start / refreshIfStale / loadMoreIfNeeded",
            refillFreshnessWindowMs: nil,
            // The only surface this slice moved: in `v2Full` the runtime's acquisition owner fetches
            // it (`AcquisitionCoordinator` over the composed `SyndicationConnector`s, driven by
            // `V2Acquisition`) and the legacy engine's requests are refused by `LegacyAcquisitionGate`.
            runtimeOwner: "AcquisitionCoordinator"
        ),
        FeedSurfacePlan(
            surface: .source,
            family: .navigableHistory,
            contextSurface: .source,
            acquisitions: [.sharedFeedEngine],
            owner: "FeedStore",
            entryPoint: "FeedStore.loadSourceContent",
            // The reader opened one source: they asked for its current payload, so a refill that
            // happened minutes ago does not answer the tap. History is preserved by the query, not by
            // the freshness of the refill.
            refillFreshnessWindowMs: 300_000
        ),
        FeedSurfacePlan(
            surface: .sourceCollection,
            family: .navigableHistory,
            contextSurface: .collection,
            acquisitions: [.sharedFeedEngine],
            owner: "FeedStore",
            entryPoint: "FeedStore.loadSourceCollectionContent",
            refillFreshnessWindowMs: 300_000
        ),
        FeedSurfacePlan(
            surface: .bookmarks,
            family: .bookmarkList,
            contextSurface: .bookmarks,
            acquisitions: [.sharedFeedEngine],
            owner: "FeedStore",
            entryPoint: "FeedStore.loadBookmarkFeed / FeedLoader.selectedBookmarkListID",
            refillFreshnessWindowMs: nil
        ),
        FeedSurfacePlan(
            surface: .search,
            family: .searchResults,
            contextSurface: .search,
            acquisitions: [.localContentSearch, .explicitOnlineContentDemand],
            owner: "FeedStore",
            entryPoint: "FeedStore.search → SearchEngine.unifiedSearch, FeedStore.runRemoteSearchSweep",
            refillFreshnessWindowMs: nil
        ),
        FeedSurfacePlan(
            surface: .smartFeed,
            family: .preset,
            contextSurface: .smartFeed,
            acquisitions: [.sharedFeedEngine],
            owner: "FeedStore",
            entryPoint: "FeedStore.refreshSmartFeed",
            refillFreshnessWindowMs: nil
        ),
        FeedSurfacePlan(
            surface: .persistentSearch,
            family: .searchResults,
            contextSurface: .persistentSearch,
            // A saved search matches what has been admitted; it demands no refill of its own. The
            // online sweep belongs to the surface that asks for it (`.search`), not to every query
            // that shares its vocabulary.
            acquisitions: [.localContentSearch],
            owner: "FeedStore",
            entryPoint: "FeedStore.matchPersistentSearches",
            refillFreshnessWindowMs: nil
        ),
        FeedSurfacePlan(
            surface: .lastClicked,
            family: .navigableHistory,
            contextSurface: .lastClicked,
            acquisitions: [.sharedFeedEngine],
            owner: "FeedStore",
            entryPoint: "FeedStore.loadLastClickedFeed",
            refillFreshnessWindowMs: 300_000
        ),
        FeedSurfacePlan(
            surface: .whatsNew,
            family: .newContent,
            contextSurface: .whatsNew,
            acquisitions: [.sharedFeedEngine],
            owner: "FeedStore",
            entryPoint: "FeedStore.refreshWhatsNew",
            refillFreshnessWindowMs: 900_000
        ),
        FeedSurfacePlan(
            surface: .onboarding,
            family: .curatedPreview,
            contextSurface: .onboarding,
            acquisitions: [.sharedFeedEngine],
            owner: "FeedStore",
            entryPoint: "FeedStore.curatedOnboardingItems",
            refillFreshnessWindowMs: 900_000
        ),
        FeedSurfacePlan(
            surface: .catalogueBrowse,
            family: .catalogueQuery,
            contextSurface: nil,
            acquisitions: [.localCatalogueQuery],
            owner: "SQLiteCatalogRepository",
            entryPoint: "CatalogBrowserViewModel.loadRoot",
            refillFreshnessWindowMs: nil
        ),
    ]

    public static func plan(for surface: FeedSurface) -> FeedSurfacePlan {
        guard let row = matrix.first(where: { $0.surface == surface }) else {
            preconditionFailure("every FeedSurface has a matrix row; \(surface.rawValue) does not")
        }
        return row
    }

    /// The editorial inputs a surface states its plan with. Editorial only: policies stay at the
    /// declared initial tuning until PR-15 owns acquisition, and a surface does not get to invent a
    /// budget of its own.
    public struct Inputs: Hashable, Sendable {
        public let scopeKey: String
        public let planIdentity: String
        public let presetIdentity: String
        public let region: String
        public let contentType: String
        public let languages: [String]
        public let mood: String
        public let contentFilters: [ContentFilter]
        public let taxonomyURLs: [String]
        public let blockedStableKeys: [SupplyStableKey]
        public let sourceSelection: [SourceSelection]
        /// The reader's own subjects as this surface's card selection, when its cards are not a source's
        /// supply. The *caller* states it: a surface's identity does not imply it, because the catalogue's
        /// `bookmarks` row is a card surface over the supply with a navigable-history policy, while the
        /// app's bookmark box is a screen whose cards are the reader's saved rows. They share a name and
        /// nothing else, which is why the selection travels with the inputs.
        public let subjectSelection: SubjectSelection?

        public init(
            scopeKey: String,
            planIdentity: String,
            presetIdentity: String = "",
            region: String = "",
            contentType: String = "",
            languages: [String] = [],
            mood: String = "",
            contentFilters: [ContentFilter] = [],
            taxonomyURLs: [String] = [],
            blockedStableKeys: [SupplyStableKey] = [],
            sourceSelection: [SourceSelection] = [],
            subjectSelection: SubjectSelection? = nil
        ) {
            self.scopeKey = scopeKey
            self.planIdentity = planIdentity
            self.presetIdentity = presetIdentity
            self.region = region
            self.contentType = contentType
            self.languages = languages
            self.mood = mood
            self.contentFilters = contentFilters
            self.taxonomyURLs = taxonomyURLs
            self.blockedStableKeys = blockedStableKeys
            self.sourceSelection = sourceSelection
            self.subjectSelection = subjectSelection
        }
    }

    /// The plan a surface states, before resolution. The context, the history policy and the declared
    /// policy versions all come from the row, so a surface cannot acquire under one rule and declare
    /// another.
    public static func plan(
        _ surface: FeedSurface,
        inputs: Inputs,
        runtimeSourceID: SourceID? = nil
    ) throws -> FeedPlan {
        let row = plan(for: surface)
        guard let contextSurface = row.contextSurface else {
            throw FeedSurfacePlanError.surfaceHasNoContext(surface)
        }
        let historyPolicy = try row.historyPolicy(
            scopeKey: inputs.scopeKey,
            runtimeSourceID: runtimeSourceID
        )
        return FeedPlan(
            context: try ContextKey(
                surface: contextSurface,
                scopeKey: inputs.scopeKey,
                planIdentity: inputs.planIdentity
            ),
            policies: try [
                PolicyVersion(policyID: .budget, version: SelectionBudget.initial.version),
                PolicyVersion(
                    policyID: .contentRestrictions,
                    version: ContentRestrictionPolicy.none.version
                ),
                PolicyVersion(
                    policyID: .preferences,
                    version: ContentPreferencePolicy.none.version
                ),
                PolicyVersion(policyID: .history, version: historyPolicy.version),
                PolicyVersion(
                    policyID: .repetition,
                    version: RepetitionPolicy.initial.version
                ),
                PolicyVersion(
                    policyID: .editorialClock,
                    version: ClockPolicy.fiveMinutes.version
                ),
            ],
            sourceSelection: inputs.sourceSelection,
            subjectSelection: inputs.subjectSelection,
            presetIdentity: inputs.presetIdentity,
            region: inputs.region,
            contentType: inputs.contentType,
            languages: inputs.languages,
            mood: inputs.mood,
            contentFilters: inputs.contentFilters,
            taxonomyURLs: inputs.taxonomyURLs,
            blockedStableKeys: inputs.blockedStableKeys,
            historyPolicy: historyPolicy
        )
    }

    /// The surfaces that acquire nothing in a mode whose runtime owns acquisition: the legacy producer
    /// is closed for them and the runtime does not serve them, so they show what has already been
    /// admitted (or what is local by construction).
    ///
    /// It exists so the remainder of the owner swap is a number rather than a claim: this slice moved
    /// the Main Feed, and every other card surface is on this list until the slice that moves it.
    public static var surfacesWithoutRuntimeAcquisition: [FeedSurface] {
        matrix
            .filter { $0.runtimeOwner == nil && $0.acquiresOverTheNetwork }
            .map(\.surface)
    }

    /// The violations the matrix can hold, as data. An empty array is the only green state:
    /// `FeedSurfaceMatrixTests` asserts it, so a new surface that forgets its row, a card surface
    /// without a context, or a second online owner fails the suite instead of shipping.
    public static var violations: [String] {
        var found: [String] = []
        let declared = Set(matrix.map(\.surface))
        for surface in FeedSurface.allCases where !declared.contains(surface) {
            found.append("\(surface.rawValue): no matrix row")
        }
        if declared.count != matrix.count {
            found.append("duplicate matrix row")
        }
        for row in matrix {
            if row.owner.isEmpty || row.entryPoint.isEmpty {
                found.append("\(row.surface.rawValue): row names no owner or no entry point")
            }
            // A surface can only have a runtime owner if the shared feed engine is what acquires for it:
            // the runtime's acquisition owner serves endpoints, not a catalogue file or a local index.
            if row.runtimeOwner != nil && !row.acquisitions.contains(.sharedFeedEngine) {
                found.append(
                    "\(row.surface.rawValue): names a runtime owner but acquires through neither engine"
                )
            }
            if row.surface == .catalogueBrowse {
                if row.contextSurface != nil || row.acquisitions != [.localCatalogueQuery] {
                    found.append("catalogueBrowse must be a local catalogue query and nothing else")
                }
                continue
            }
            guard row.contextSurface != nil else {
                found.append("\(row.surface.rawValue): a card surface must declare a context")
                continue
            }
            if row.acquisitions.isEmpty {
                found.append("\(row.surface.rawValue): no acquisition declared")
            }
            if Set(row.acquisitions).count != row.acquisitions.count {
                found.append("\(row.surface.rawValue): duplicate acquisition")
            }
            if !row.acquisitions.contains(.sharedFeedEngine)
                && !row.acquisitions.contains(.localContentSearch)
                && !row.acquisitions.contains(.localCatalogueQuery) {
                found.append("\(row.surface.rawValue): no acquisition can serve it")
            }
            // Plan §14: source search stays a catalogue query, content search stays the canonical FTS,
            // and the online content demand is separate. A card surface that demands the network
            // without the local search is the implicit-sweep defect this row forbids.
            if row.acquisitions.contains(.explicitOnlineContentDemand)
                && !row.acquisitions.contains(.localContentSearch) {
                found.append(
                    "\(row.surface.rawValue): an online content demand must accompany the local search"
                )
            }
            if row.acquisitions.contains(.localContentSearch)
                && row.family != .searchResults {
                found.append("\(row.surface.rawValue): only a search surface searches content")
            }
        }
        return found
    }
}
