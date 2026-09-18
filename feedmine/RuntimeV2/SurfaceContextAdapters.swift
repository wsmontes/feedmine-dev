import Foundation
import FeedDomain
import FeedRuntime

/// The context one app surface resolves its plan under (plan §14 PR-14 item 1).
///
/// The screen's `contextKey` and the runtime's `ContextKey` used to be two identities for the same
/// thing: PR-13 built a string by hand (`"main-feed|preset=…|box=…"`) while the runtime's plans had a
/// `ContextKey`. There is one now. The surface's context is the runtime's context, its
/// serialization is what the screen switches on, and the `HistoryScope` the row declares is what
/// decides whether another surface's exposure may hide a card here.
struct FeedSurfaceContext {
    /// The support-matrix row (owner, entry point, allowed acquisitions, refill window).
    let row: FeedSurfacePlan
    let contextKey: ContextKey
    /// Resolved through `FeedSurfaceCatalog.resolvedPlan`, so ADR-007 D12 is enforced by the resolver.
    let plan: ResolvedFeedPlan
    /// The identity this surface is materialized under. The Main Feed's is its published edition;
    /// a surface with no runtime publication gets one from this adapter's ephemeral allocator, which
    /// is the same rule PR-13 stated for the edition counter (the runtime owns allocation once it
    /// owns publication).
    let editionID: EditionID

    var surface: FeedSurface { row.surface }

    /// The string the screen passes to `FeedScreenStore.expect(contextKey:)` and the one a snapshot
    /// carries. One identity, serialized once.
    var contextKeyText: String { contextKey.canonicalSerialization }

    /// Whether a card seen in `factScope` is removed from this surface. Answered through the
    /// surface's own resolved plan, so a surface cannot invent an exposure rule.
    var historyRules: HistoryScopeRules { HistoryScopeRules(policy: plan.historyPolicy) }
}

/// The editorial inputs a surface states its plan with. They are the legacy selectors the app already
/// owns; the adapter translates them, it does not take them over.
struct FeedSurfaceContextInputs {
    var scopeKey: String
    var planIdentity: String
    var presetIdentity: String = ""
    var region: String = ""
    var contentType: String = ""
    var languages: [String] = []
    var mood: String = ""
    var contentFilters: [FeedDomain.ContentFilter] = []
    var taxonomyURLs: [String] = []
    /// The reader's own subjects as this surface's card selection, when its cards are not a source's
    /// supply — a bookmark box. The caller states it, because a surface's identity does not imply it
    /// (`FeedSurfaceCatalog.Inputs.subjectSelection`).
    var subjectSelection: SubjectSelection? = nil
}

/// Builds one `ResolvedFeedPlan` per app surface from the state the app already holds.
///
/// Nothing here acquires, and nothing here is a second owner: it reads the loader's selectors, the
/// content-filter store and the taxonomy, states them in the runtime's plan vocabulary, and hands the
/// resolved plan back with the edition the surface is materialized under. The matrix row it returns
/// is the support matrix itself — `FeedSurfaceCatalog.plan(for:)` — so a surface cannot be documented
/// under one rule and acquire under another.
@MainActor
final class SurfaceContextAdapters {
    private var editionByContextKey: [String: EditionID] = [:]
    private var editionCounter: Int64

    /// The clock the plan is resolved with. Editorial decisions that must be reproducible take the
    /// clock as an input; the app's default is the system clock.
    private let clock: any EditorialClock

    init(
        editionSeed: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        clock: any EditorialClock = SystemEditorialClock()
    ) {
        self.editionCounter = editionSeed
        self.clock = clock
    }

    /// One surface's context. Throws when the surface's row cannot be stated truthfully: a surface
    /// that composes no cards, or one whose history scope is a runtime identity the app cannot
    /// allocate yet (`source`, ADR-003 D2/D18).
    func context(
        _ surface: FeedSurface,
        inputs: FeedSurfaceContextInputs,
        runtimeSourceID: FeedDomain.SourceID? = nil
    ) throws -> FeedSurfaceContext {
        let row = FeedSurfaceCatalog.plan(for: surface)
        let plan = try FeedSurfaceCatalog.resolvedPlan(
            surface,
            inputs: FeedSurfaceCatalog.Inputs(
                scopeKey: inputs.scopeKey,
                planIdentity: inputs.planIdentity,
                presetIdentity: inputs.presetIdentity,
                region: inputs.region,
                contentType: inputs.contentType,
                languages: inputs.languages,
                mood: inputs.mood,
                contentFilters: inputs.contentFilters,
                taxonomyURLs: inputs.taxonomyURLs,
                subjectSelection: inputs.subjectSelection
            ),
            clock: clock,
            runtimeSourceID: runtimeSourceID
        )
        return FeedSurfaceContext(
            row: row,
            contextKey: plan.context,
            plan: plan,
            editionID: edition(for: plan.context.canonicalSerialization)
        )
    }

    /// The Main Feed's context, from the loader's selectors.
    ///
    /// The scope key is the two selectors the screen switches on (the preset and the bookmark box)
    /// and nothing about how the page happens to be materialized, which is what PR-13's hand-built
    /// key already meant.
    ///
    /// Cannot fail: every input is a non-empty literal derived from the store, and a resolved plan is
    /// refused only by a declared version this build does not implement, which would be a build defect
    /// and not a runtime condition.
    func mainFeed(loader: FeedLoader) -> FeedSurfaceContext {
        do {
            return try context(.main, inputs: mainFeedInputs(loader: loader))
        } catch {
            preconditionFailure("the Main Feed's plan is stateable by construction: \(error)")
        }
    }

    /// The loader's selectors as a plan input. Shared by every surface reached from the Main Feed, so
    /// a secondary surface inherits the reader's filters instead of inventing its own.
    func mainFeedInputs(loader: FeedLoader) -> FeedSurfaceContextInputs {
        let box = loader.selectedBookmarkListID.map(String.init) ?? "-"
        // A bookmark box is the same screen with a selection: its cards are the saved subjects filed into
        // that list, and the runtime can state that (baseline §8.59/§8.60). The key already carries the
        // box, so the plan and the key agree by construction — and the list key is spelled in exactly one
        // place, `UserStateBridge.listKey(for:)`, or the selection and the row that files it would drift.
        let subjectSelection: SubjectSelection? = loader.selectedBookmarkListID.map {
            .savedSubjects(kind: .bookmark, listKey: UserStateBridge.listKey(for: $0))
        }
        return FeedSurfaceContextInputs(
            scopeKey: "preset=\(loader.activePreset.cacheKey)|box=\(box)",
            planIdentity: "MainFeedPlan",
            presetIdentity: loader.activePreset.cacheKey,
            region: loader.selectedRegion ?? "",
            contentType: loader.selectedContentType.rawValue,
            languages: loader.selectedLanguages.sorted(),
            mood: loader.selectedMood.rawValue,
            contentFilters: Self.declaredContentFilters,
            taxonomyURLs: loader.selectedNodeIDs.isEmpty
                ? []
                : TaxonomyStore.shared.feedURLs(inSubtreesOf: loader.selectedNodeIDs).sorted(),
            subjectSelection: subjectSelection
        )
    }

    /// A secondary surface's inputs: the reader's filters, its own scope key and family.
    ///
    /// The source and collection sheets show a narrower set, but they show it under the same reader
    /// choices, so a card cannot be filtered out of the sheet and left in the feed.
    func secondaryInputs(
        loader: FeedLoader,
        scopeKey: String,
        planIdentity: String
    ) -> FeedSurfaceContextInputs {
        var inputs = mainFeedInputs(loader: loader)
        inputs.scopeKey = scopeKey
        inputs.planIdentity = planIdentity
        return inputs
    }

    /// One row of the matrix, for a caller that needs the owner, the entry point or the refill window
    /// without resolving a plan.
    func row(_ surface: FeedSurface) -> FeedSurfacePlan {
        FeedSurfaceCatalog.plan(for: surface)
    }

    /// The identity a surface is materialized under, without resolving its plan.
    ///
    /// Used where the app renders a surface but cannot yet state its plan — the Source surface needs
    /// an allocated `SourceID` (ADR-003 D2/D18), which no shipping mode can produce while the runtime
    /// does not own acquisition. The surface still gets one identity for its actions, so an offer
    /// built on it is comparable with the capability it was presented under.
    func materializationEdition(surface: FeedSurface, scopeKey: String) -> EditionID {
        edition(for: "\(surface.rawValue)|\(scopeKey)")
    }

    /// The content filters the reader has enabled, in the plan's vocabulary.
    ///
    /// `ContentFilterStore` stays the owner of this durable state (recon §4): the adapter reads it and
    /// states it, and a filter the reader switched off is not part of the plan. An enabled filter is
    /// hard eligibility — the store's model hides matches rather than scoring them down — so it maps
    /// to a mandatory filter, never to a soft preference.
    static var declaredContentFilters: [FeedDomain.ContentFilter] {
        ContentFilterStore.shared.filters.compactMap { filter in
            guard filter.isEnabled, !filter.keywords.isEmpty else { return nil }
            return try? FeedDomain.ContentFilter(
                filterID: filter.templateKey ?? filter.name,
                keywords: filter.keywords,
                isMandatory: true
            )
        }
    }

    /// The ephemeral edition for one context key. Monotonic inside this launch and stable for the same
    /// context, which is what an anchor needs while a runtime database is not composed.
    private func edition(for contextKey: String) -> EditionID {
        if let existing = editionByContextKey[contextKey] { return existing }
        editionCounter += 1
        let raw = editionCounter == 0 ? 1 : editionCounter
        guard let edition = try? EditionID(raw) else {
            preconditionFailure("edition \(raw) is inside the allocatable range and cannot be refused")
        }
        editionByContextKey[contextKey] = edition
        return edition
    }
}
