import Foundation
import XCTest
import FeedDomain
import FeedRuntime

/// PR-14, surface half: the support matrix and the ADR-007 D12 rule, as data a build can check
/// (plan §14 PR-14, rollout §2 and §4).
///
/// `FeedSurfaceCatalog` is the single statement of which surface reads which history and acquires how,
/// so these tests read the matrix rather than restating it: a surface that forgets its row, a card
/// surface without a context, or a `seen` fact that leaks from Main into a navigable surface fails
/// here instead of shipping.
final class FeedSurfaceMatrixTests: XCTestCase {

    private struct MatrixClock: EditorialClock {
        let now: Date
    }

    private static let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func clock() -> MatrixClock { MatrixClock(now: Self.instant) }

    private func inputs(_ surface: FeedSurface) -> FeedSurfaceCatalog.Inputs {
        FeedSurfaceCatalog.Inputs(
            scopeKey: "scope-\(surface.rawValue)",
            planIdentity: "\(surface.rawValue)Plan"
        )
    }

    /// Every `FeedSurface` has exactly one row, and the matrix reports no violation.
    func test_matrixHasExactlyOneRowPerSurfaceAndNoViolations() {
        XCTAssertEqual(FeedSurfaceCatalog.violations, [], "the matrix is the only green state")

        for surface in FeedSurface.allCases {
            let rows = FeedSurfaceCatalog.matrix.filter { $0.surface == surface }
            XCTAssertEqual(rows.count, 1, "\(surface.rawValue) must have exactly one row")
        }
        XCTAssertEqual(
            FeedSurfaceCatalog.matrix.count,
            FeedSurface.allCases.count,
            "no row outside the surface vocabulary and none missing"
        )
    }

    /// Every card surface resolves its own declared context, and the resolved policy's `applySeen` is
    /// exactly what the scope's own D12 rule allows.
    func test_everyCardSurfaceResolvesAndAgreesWithItsScopesSeenRule() throws {
        for row in FeedSurfaceCatalog.matrix where row.contextSurface != nil {
            let resolved = try FeedSurfaceCatalog.resolvedPlan(
                row.surface,
                inputs: inputs(row.surface),
                clock: clock(),
                runtimeSourceID: row.surface == .source ? try SourceID(42) : nil
            )
            let scope = resolved.historyPolicy.scope
            XCTAssertEqual(
                scope.surface,
                row.contextSurface,
                "\(row.surface.rawValue) resolves the context its row declares"
            )
            XCTAssertEqual(
                resolved.historyPolicy.applySeen,
                scope.allowsSeenExclusion,
                "\(row.surface.rawValue): applySeen is the scope's rule, never a second declaration"
            )
        }
    }

    /// The rule the classification exists for: a card seen in Main is not removed from any navigable
    /// surface — neither from Bookmark nor Source nor the other surfaces D12 protects — while the
    /// surfaces that do apply `seen` exclude only a fact recorded in their own scope. The overlay half
    /// is asserted too, so "does not exclude" never means "cannot show it".
    func test_mainExposureDoesNotHideBookmarkOrSourceHistory() throws {
        let sourceID = try SourceID(42)

        let unaffected: [(surface: FeedSurface, runtimeSourceID: SourceID?)] = [
            (.bookmarks, nil),
            (.search, nil),
            (.persistentSearch, nil),
            (.whatsNew, nil),
            (.onboarding, nil),
            (.lastClicked, nil),
            (.sourceCollection, nil),
            (.source, sourceID),
        ]
        for entry in unaffected {
            let surface = entry.surface
            XCTAssertFalse(
                try FeedSurfaceCatalog.excludes(
                    surface,
                    cardSeenIn: .main,
                    inputs: inputs(surface),
                    clock: clock(),
                    runtimeSourceID: entry.runtimeSourceID
                ),
                "a fact recorded in Main cannot remove a card from \(surface.rawValue)"
            )
        }

        // The overlay half: a surface that must not exclude still shows the state. The preset
        // surfaces do apply `seen` — within their own scope — so Main's fact is not theirs to show,
        // and they are excluded from this assertion.
        for surface in [FeedSurface.bookmarks, .search, .persistentSearch, .whatsNew, .onboarding, .lastClicked, .source] {
            let resolved = try FeedSurfaceCatalog.resolvedPlan(
                surface,
                inputs: inputs(surface),
                clock: clock(),
                runtimeSourceID: surface == .source ? sourceID : nil
            )
            XCTAssertFalse(resolved.historyPolicy.applySeen, "\(surface.rawValue) never applies `seen`")
            XCTAssertTrue(
                HistoryScopeRules(policy: resolved.historyPolicy)
                    .showsOverlay(forCardRecordedIn: .main),
                "\(surface.rawValue) shows the Main-recorded state as an overlay without excluding"
            )
        }

        // Main applies `seen` to its own facts, and so do a collection and a smart feed within their
        // own scopes; the exclusion requires the fact's own scope, not only `applySeen`.
        XCTAssertTrue(
            try FeedSurfaceCatalog.excludes(
                .main,
                cardSeenIn: .main,
                inputs: inputs(.main),
                clock: clock()
            )
        )
        XCTAssertFalse(
            try FeedSurfaceCatalog.excludes(
                .main,
                cardSeenIn: .bookmark(listKey: nil),
                inputs: inputs(.main),
                clock: clock()
            )
        )
        for surface in [FeedSurface.sourceCollection, .smartFeed] {
            let ownScope = try FeedSurfaceCatalog
                .plan(surface, inputs: inputs(surface))
                .historyPolicy.scope
            XCTAssertTrue(
                try FeedSurfaceCatalog.excludes(
                    surface,
                    cardSeenIn: ownScope,
                    inputs: inputs(surface),
                    clock: clock()
                ),
                "\(surface.rawValue) excludes within its own scope"
            )
        }
        XCTAssertEqual(
            try FeedSurfaceCatalog.plan(.smartFeed, inputs: inputs(.smartFeed)).historyPolicy.scope,
            .smartFeed(key: "scope-smartFeed")
        )
        XCTAssertFalse(
            try FeedSurfaceCatalog.excludes(
                .smartFeed,
                cardSeenIn: .main,
                inputs: inputs(.smartFeed),
                clock: clock()
            ),
            "Main's fact does not reach into a smart feed"
        )
    }

    /// The scope-identity half of D12: a fact recorded in the collection's own scope excludes its
    /// cards, while the same card seen in Main does not reach the collection at all. The two answers
    /// differ by the scope the fact was recorded in, not by the surface's willingness to apply `seen`.
    func test_collectionExcludesOnlyItsOwnSeenFacts() throws {
        let collectionScope = try FeedSurfaceCatalog
            .plan(.sourceCollection, inputs: inputs(.sourceCollection))
            .historyPolicy.scope
        XCTAssertEqual(collectionScope, .collection(key: "scope-sourceCollection"))

        XCTAssertTrue(
            try FeedSurfaceCatalog.excludes(
                .sourceCollection,
                cardSeenIn: collectionScope,
                inputs: inputs(.sourceCollection),
                clock: clock()
            ),
            "a card the collection itself showed is excluded from it"
        )
        XCTAssertFalse(
            try FeedSurfaceCatalog.excludes(
                .sourceCollection,
                cardSeenIn: .main,
                inputs: inputs(.sourceCollection),
                clock: clock()
            ),
            "the same card seen in Main stays in the collection"
        )
    }

    /// The Source surface's scope is a runtime identity, so its row refuses without an allocated
    /// `SourceID` rather than deriving one from a catalogue id or a URL; once supplied it resolves.
    func test_sourceRowRequiresAnAllocatedRuntimeIdentity() throws {
        XCTAssertThrowsError(try FeedSurfaceCatalog.plan(.source, inputs: inputs(.source))) { error in
            XCTAssertEqual(
                error as? FeedSurfacePlanError,
                FeedSurfacePlanError.runtimeIdentityUnavailable(.source)
            )
        }
        XCTAssertThrowsError(
            try FeedSurfaceCatalog.resolvedPlan(.source, inputs: inputs(.source), clock: clock())
        ) { error in
            XCTAssertEqual(
                error as? FeedSurfacePlanError,
                FeedSurfacePlanError.runtimeIdentityUnavailable(.source)
            )
        }

        let sourceID = try SourceID(42)
        let resolved = try FeedSurfaceCatalog.resolvedPlan(
            .source,
            inputs: inputs(.source),
            clock: clock(),
            runtimeSourceID: sourceID
        )
        XCTAssertEqual(resolved.historyPolicy.scope, .source(sourceID))
        XCTAssertFalse(resolved.historyPolicy.applySeen, "a source is navigable history")
    }

    /// Catalogue browsing composes no cards: it has no plan and no history scope, and its row is
    /// refused instead of approximated.
    func test_catalogueBrowseComposesNoFeedAndNeverResolves() {
        XCTAssertThrowsError(try FeedSurfaceCatalog.plan(.catalogueBrowse, inputs: inputs(.catalogueBrowse))) { error in
            XCTAssertEqual(
                error as? FeedSurfacePlanError,
                FeedSurfacePlanError.surfaceHasNoContext(.catalogueBrowse)
            )
        }
        XCTAssertThrowsError(
            try FeedSurfaceCatalog.resolvedPlan(
                .catalogueBrowse,
                inputs: inputs(.catalogueBrowse),
                clock: clock()
            )
        ) { error in
            XCTAssertEqual(
                error as? FeedSurfacePlanError,
                FeedSurfacePlanError.surfaceHasNoContext(.catalogueBrowse)
            )
        }
    }

    /// The search split, as the matrix declares it: source search is a catalogue query, content search
    /// is the canonical local FTS, and the online sweep is a separate, explicit demand held by the
    /// main search surface alone.
    func test_searchSplitIsDeclaredInTheMatrix() {
        XCTAssertEqual(
            FeedSurfaceCatalog.plan(for: .search).acquisitions,
            [.localContentSearch, .explicitOnlineContentDemand],
            "search: local FTS first, the online sweep separate and explicit"
        )

        let searchSurfaces = FeedSurfaceCatalog.matrix
            .filter { $0.family == .searchResults }
            .map(\.surface)
        XCTAssertEqual(
            Set(searchSurfaces),
            [.search, .persistentSearch],
            "the content-search family is exactly the two search surfaces"
        )
        for row in FeedSurfaceCatalog.matrix where row.family == .searchResults {
            XCTAssertTrue(
                row.acquisitions.contains(.localContentSearch),
                "\(row.surface.rawValue): content search is the canonical local FTS"
            )
        }
        for row in FeedSurfaceCatalog.matrix where row.family != .searchResults {
            XCTAssertFalse(
                row.acquisitions.contains(.localContentSearch),
                "\(row.surface.rawValue): only a search surface searches content"
            )
        }

        let onlineDemands = FeedSurfaceCatalog.matrix
            .filter { $0.acquisitions.contains(.explicitOnlineContentDemand) }
            .map(\.surface)
        XCTAssertEqual(
            onlineDemands,
            [.search],
            "the online content sweep is one explicit demand, never an implicit effect of a local search"
        )
        XCTAssertEqual(
            FeedSurfaceCatalog.plan(for: .persistentSearch).acquisitions,
            [.localContentSearch],
            "a saved search matches what has been admitted and demands no refill of its own"
        )

        let browse = FeedSurfaceCatalog.plan(for: .catalogueBrowse)
        XCTAssertEqual(browse.family, .catalogueQuery)
        XCTAssertEqual(browse.acquisitions, [.localCatalogueQuery], "source search is a catalogue query")
        XCTAssertNil(browse.contextSurface)
    }
}
