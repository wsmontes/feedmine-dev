import CryptoKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.feedmine.app", category: "DisplayState")

/// Manages the visible feed state — what the UI renders right now.
/// Extracted from FeedStore (P0-01 audit R1).
///
/// FeedStore delegates display state mutations here so the 7,204-line
/// monolith shrinks by ~200 lines and the display phase lifecycle has
/// a single, focused owner.
///
/// ## Behavioral Contracts
/// - **Stamping**: Every visible item is stamped with `isRead`/`isBookmarked`
///   so views don't observe the global sets directly — reading one item
///   won't invalidate all cards.
/// - **No-op detection**: Redundant updates are dropped before bumping
///   `visibleItemsGeneration`, preventing spurious cache invalidations.
/// - **Atomic epoch**: `advanceEpoch` always bumps the epoch and captures
///   a fresh context in one call — the two are never split.
/// - **First-paint transition**: `publishCards` couples `loadingState ==
///   .initial → .idle` with the phase flip to `.ready`/`.empty`.
///
/// Marked `@Observable` so the FeedStore → FeedLoader → SwiftUI view
/// observation chain tracks property-level dependencies through all
/// three layers. `@unchecked Sendable` is dropped — `@MainActor` classes
/// are implicitly `Sendable`.
@MainActor
@Observable
final class FeedDisplayState {
    /// Items currently rendered in the feed.
    private(set) var visibleItems: [FeedItem] = []

    /// Pre-resolved card presentations for the visible page.
    /// Published alongside `visibleItems` so views can render images
    /// synchronously (no post-insertion downloads). Search and onboarding
    /// paths that skip the pipeline will have an empty `visibleCards` —
    /// views fall back to `CachedAsyncImage`.
    private(set) var visibleCards: [FeedCardPresentation] = []

    /// Monotonic counter incremented on every `visibleItems` change.
    /// `FeedLoader` uses this for cache invalidation instead of item count.
    private(set) var visibleItemsGeneration: UInt64 = 0

    /// Monotonic counter incremented whenever `visibleCards` is published.
    /// `FeedLoader` caches keyed only on `visibleItemsGeneration` would keep
    /// rendering stale card media otherwise.
    ///
    /// There is deliberately no in-place card swap: a published presentation is
    /// immutable, so cards and items always change together through
    /// ``publishCards(_:items:readItemIDs:bookmarkItemIDs:isAppend:)``.
    private(set) var visibleCardsGeneration: UInt64 = 0

    /// Monotonic counter incremented on in-place item mutations that skip
    /// the generation bump (`mutateVisibleItem(bumpGeneration: false)`),
    /// e.g. read-state toggles. `FeedLoader` includes this in its cache
    /// keys so stamped read/bookmark state always re-renders.
    private(set) var readStateRevision: UInt64 = 0

    /// Loading indicator state exposed to the UI.
    private(set) var loadingState: FeedLoadingState = .idle

    /// Current lifecycle phase of the feed (startup, ready, refreshing).
    /// Replaces the error-prone pattern of inferring state from
    /// `items.isEmpty + loadingState`.
    private(set) var feedDisplayPhase: FeedDisplayPhase = .preparing(contextID: 0, reason: .startup)

    /// `true` while the cold-start runway is still being built.
    private(set) var isPreparingInitialRunway = false

    /// itemID → cache key of the image published for it. Written by the prepared pipeline (which is
    /// the only place that knows the key) and persisted with the page so a warm start can rebuild
    /// the cards with their media. Never holds an image.
    private(set) var visibleCardCacheKeys: [String: String] = [:]

    /// True while a user-initiated composition is being fetched/prepared. Read by the surface to prefer the
    /// in-progress view over "no results"; see `FeedStore.isPreparingFilteredComposition`.
    private(set) var isFilteredCompositionInFlight = false

    func setFilteredCompositionInFlight(_ value: Bool) {
        guard isFilteredCompositionInFlight != value else { return }
        isFilteredCompositionInFlight = value
        logger.info("filtered composition in flight: \(value)")
    }

    /// What this session has already written for each composition signature.
    ///
    /// Two facts, both about *not* regressing the page on disk: the fingerprint of the page last written (an
    /// unchanged page is not rewritten) and its depth (a thinner publication cannot replace a deeper page — see
    /// ``cacheVisiblePageIfNeeded(filterSignature:)``). Keyed by signature because one session writes several:
    /// a single slot made two compositions invalidate each other's guard.
    private var cachedPages: [String: WrittenPage] = [:]

    private struct WrittenPage {
        let fingerprint: String
        let depth: Int
    }

    /// Monotonic epoch incremented on every filter/preset change.
    /// Every async preparation task captures this; results are discarded
    /// if the epoch changes before the task completes.
    private(set) var presentationEpoch: UInt64 = 0

    /// Context snapshot captured at filter/preset boundaries.
    /// Identifies a specific feed composition session — async tasks that
    /// captured a different context discard their results.
    private(set) var activePresentationContext = FeedPresentationContext(
        epoch: 0, mode: .main,
        filterGeneration: 0, presetGeneration: 0
    )

    // MARK: - Mutations

    /// Stamp and publish items directly (legacy / non-pipeline path).
    ///
    /// Stamps each item with `isRead`/`isBookmarked` so views don't
    /// observe the global sets directly. Guards against no-op updates
    /// to prevent spurious `visibleItemsGeneration` bumps that would
    /// force full cache invalidations in `FeedLoader`.
    ///
    /// This is the legacy replace-only path — FeedStore's legacy
    /// `setVisibleItems` never appends. The prepared pipeline should
    /// use ``publishCards(_:items:readItemIDs:bookmarkItemIDs:isAppend:)``
    /// which supports both append and replace with card publication.
    func setVisibleItems(
        _ items: [FeedItem],
        readItemIDs: Set<String>,
        bookmarkItemIDs: Set<String>,
        shouldCache: Bool = false,
        filterSignature: String = "",
        settlesPhase: Bool = true,
        isUserInitiated: Bool = false
    ) {
        var stamped = items
        for i in stamped.indices {
            stamped[i].stamp(readItemIDs: readItemIDs, bookmarkItemIDs: bookmarkItemIDs)
        }

        // First-paint transition: settle .preparing → .ready/.empty.
        // Keyed on the phase (not loadingState) because a defer in
        // fetchNextBatch can set loadingState = .idle before the async
        // card-prep publish lands — the old loadingState==.initial gate
        // was permanently missed, causing the "Loading your feed" hang.
        //
        // Skip when loadingState == .refreshing: setFilter/shakeToRefresh
        // deliberately enter .preparing + .refreshing, then publish empty
        // transiently before the reload completes. Settling to .empty here
        // would defeat that intent and flash the empty state.
        let isFirstPaint: Bool
        if case .preparing = feedDisplayPhase,
           loadingState != .refreshing {
            // Settle the loading state by the rule the store itself uses for it
            // (`isPreparingInitialRunway && visibleItems.isEmpty ? .initial : .idle`). A
            // *transient* clear that leaves nothing on screen while the runway is still being
            // prepared must not claim `.idle`: the startup watchdog is an inline check at the end
            // of `start()` that answers `.idle` + `.preparing` with `.empty`, which is the
            // "No sources enabled" screen appearing while the catalogue was still loading.
            if loadingState == .initial,
               settlesPhase || !stamped.isEmpty || !isPreparingInitialRunway {
                loadingState = .idle
            }
            if settlesPhase {
                // `settlesPhase: false` marks a transient clear: the empty publication a rebuild
                // starts with. It must not answer a question the rebuild has not asked yet — doing
                // so made the screen claim "No sources enabled" while the catalogue was still
                // loading, and the real page replaced it seconds later. Only the caller knows which
                // empty publications are answers, so it says so.
                isFirstPaint = true
                feedDisplayPhase = stamped.isEmpty
                    ? .empty(contextID: presentationEpoch)
                    : .ready(contextID: presentationEpoch)
                logger.info("setVisibleItems firstPaint: phase=\(String(describing: self.feedDisplayPhase))")
            } else {
                isFirstPaint = false
            }
        } else {
            isFirstPaint = false
        }

        // The page that is already on screen is only replaced by a publication the user asked
        // for (`isUserInitiated`, or the refresh marker setFilter/manualRefresh already use).
        // Everything else — a rebuild's opening clear, a background flush — must leave it alone:
        // that is what the user sees as a feed that vanishes and has to be reassembled.
        let userInitiated = isUserInitiated || publicationIsUserInitiated
        if stamped.isEmpty, !visibleItems.isEmpty, !userInitiated {
            // The page on screen is never blanked by a publication the user did not ask for —
            // transient or terminal. A rebuild's opening clear and an early "empty" composition
            // (the catalogue had not produced anything yet) look identical to the reader: the feed
            // disappears and an absence screen appears for no reason.
            logger.info("setVisibleItems: kept \(self.visibleItems.count) displayed items; refused an empty publication")
            return
        }
        // Auto-heal: a page arriving ends the in-flight state. Clearing it only in the flush tail meant a
        // cancelled `pipelineTask` or a stale-generation exit left it stuck true, and the surface would show
        // "fetching" forever — worse than the absence it replaces.
        if !stamped.isEmpty { setFilteredCompositionInFlight(false) }
        guard stamped != visibleItems else { return }
        visibleItems = stamped
        if stamped.isEmpty { visibleCards = [] }
        visibleItemsGeneration &+= 1
        logger.info("setVisibleItems: items=\(self.visibleItems.count) generation=\(self.visibleItemsGeneration)")

        // Cache the first page for instant warm-start restore. Runs after
        // the assignment so the snapshot includes the published items. The
        // signature keys the file to the composition that produced it.
        if shouldCache, isFirstPaint {
            cacheVisiblePageIfNeeded(filterSignature: filterSignature)
        }
    }

    /// Publish render-ready cards alongside their items (prepared pipeline).
    ///
    /// Items and cards are published atomically — the UI never sees a card
    /// without its resolved media. Re-stamps items to capture any read/bookmark
    /// state changes that occurred during card preparation.
    ///
    /// On first paint (`loadingState == .initial`), transitions to `.idle`
    /// and flips `feedDisplayPhase` to `.ready` or `.empty` together —
    /// the two are never desynchronized.
    func publishCards(
        _ cards: [FeedCardPresentation],
        items: [FeedItem],
        readItemIDs: Set<String>,
        bookmarkItemIDs: Set<String>,
        isAppend: Bool,
        shouldCache: Bool = false,
        filterSignature: String = "",
        settlesPhase: Bool = true,
        isUserInitiated: Bool = false,
        mediaCacheKeys: [String: String] = [:]
    ) {
        // Re-stamp: read/bookmark state may have changed during preparation.
        var stampedItems = items
        for i in stampedItems.indices {
            stampedItems[i].stamp(readItemIDs: readItemIDs, bookmarkItemIDs: bookmarkItemIDs)
        }


        let userInitiated = isUserInitiated || publicationIsUserInitiated
        if !isAppend, stampedItems.isEmpty, !visibleItems.isEmpty, !userInitiated {
            logger.info("publishCards: kept \(self.visibleItems.count) displayed items; refused an empty publication")
            return
        }

        // NOTE: converting a background *replace* into an append was tried here and reverted — it
        // crashed (`Fatal error: Duplicate values for key`) on the filter paths, because a merged
        // page can leave `visibleItems` and `visibleCards` describing different sets. The rule
        // "background never takes over the page" is delivered instead by the guard above (an empty
        // publication cannot blank the page) together with restoring the page *with* its media, so
        // the pipeline's first publication matches what is already on screen.
        // Same auto-heal on the card path.
        if !stampedItems.isEmpty { setFilteredCompositionInFlight(false) }

        // Background merge over a displayed page: keep the displayed *order*, keep the better card
        // per id, append the ids this batch adds at the end. Reordering is what the user reports as
        // "cards moving up and down", so the displayed order wins over the batch's order; removal is
        // not this path's job either (a user-initiated change replaces the page instead), and a batch
        // that has not resolved an image yet must not take an image away from a card on screen.
        if !isAppend, !userInitiated, !visibleItems.isEmpty, !cards.isEmpty {
            var incomingCard = [String: FeedCardPresentation](minimumCapacity: cards.count)
            var incomingItem = [String: FeedItem](minimumCapacity: stampedItems.count)
            for (card, item) in zip(cards, stampedItems) where incomingCard[card.id] == nil {
                incomingCard[card.id] = card
                incomingItem[card.id] = item
            }
            var mergedCards: [FeedCardPresentation] = []
            var mergedItems: [FeedItem] = []
            mergedCards.reserveCapacity(max(visibleCards.count, cards.count))
            var placed = Set<String>(minimumCapacity: cards.count)
            for (shownCard, shownItem) in zip(visibleCards, visibleItems) {
                guard placed.insert(shownCard.id).inserted else { continue }
                if let card = incomingCard[shownCard.id] {
                    let keepShown = !Self.cardHasMedia(card.media) && Self.cardHasMedia(shownCard.media)
                    mergedCards.append(keepShown ? shownCard : card)
                    mergedItems.append(incomingItem[shownCard.id] ?? shownItem)
                } else {
                    mergedCards.append(shownCard)
                    mergedItems.append(shownItem)
                }
            }
            for (card, item) in zip(cards, stampedItems) where placed.insert(card.id).inserted {
                mergedCards.append(card)
                mergedItems.append(item)
            }
            // A merge that changes nothing must not churn the visible page. Assigning and bumping
            // both generations re-renders every card, and a re-render landing between a test's
            // stability check and its tap is what loses the tap — recorded as
            // `miss_cause=feed_unchanged_verified` in the release journey. The settle and the
            // page-cache write below still run either way.
            if mergedCards != visibleCards || mergedItems != visibleItems {
                visibleCards = mergedCards
                visibleItems = mergedItems
                visibleItemsGeneration &+= 1
                visibleCardsGeneration &+= 1
            }
            for card in mergedCards where mediaCacheKeys[card.id] != nil {
                visibleCardCacheKeys[card.id] = mediaCacheKeys[card.id]
            }
            // Fall through on purpose: the first-paint settle and the page-cache write below must
            // still run, or a warm page would never be re-cached (measured: the cache froze at the
            // boot batch, which had no media, so the next launch restored a worse page).
        } else if isAppend {

            let existingIDs = Set(visibleCards.map(\.id))
            let newCards = cards.filter { !existingIDs.contains($0.id) }
            guard !newCards.isEmpty else { return }
            // Filter items by the same set of new card IDs so visibleItems
            // and visibleCards stay 1:1 — never append an item without a
            // matching card (review finding: items/cards divergence).
            let newIDs = Set(newCards.map(\.id))
            let newItems = stampedItems.filter { newIDs.contains($0.id) }
            visibleCards.append(contentsOf: newCards)
            visibleItems.append(contentsOf: newItems)
            for (id, key) in mediaCacheKeys { visibleCardCacheKeys[id] = key }
        } else {
            visibleCards = cards
            visibleItems = stampedItems
            visibleCardCacheKeys = mediaCacheKeys
        }

        visibleItemsGeneration &+= 1
        visibleCardsGeneration &+= 1

        // First-paint transition: settle .preparing → .ready/.empty.
        // Skips when loadingState == .refreshing to avoid flashing the
        // empty state during setFilter/shakeToRefresh transient clears.
        if case .preparing = feedDisplayPhase,
           loadingState != .refreshing {
            // Same rule as `setVisibleItems`: the loading state settles because a page exists,
            // while a transient clear with nothing on screen keeps the runway's own `.initial`.
            if loadingState == .initial,
               settlesPhase || !stampedItems.isEmpty || !isPreparingInitialRunway {
                loadingState = .idle
            }
            if settlesPhase {
                feedDisplayPhase = visibleItems.isEmpty
                    ? .empty(contextID: presentationEpoch)
                    : .ready(contextID: presentationEpoch)
                logger.info("publishCards firstPaint: items=\(self.visibleItems.count) cards=\(self.visibleCards.count)")
            }
        }

        // Persist the first page so the next launch paints instantly while
        // the async OPML → taxonomy → SQLite → card-prep pipeline rebuilds.
        // Cache with filter signature so filtered/config-specific pages
        // are also restored instantly on restart.
        if shouldCache {
            cacheVisiblePageIfNeeded(filterSignature: filterSignature)
        }
    }

    /// Mutate a single visible item in-place.
    ///
    /// Unlike ``setVisibleItems(_:readItemIDs:bookmarkItemIDs:)``, this method
    /// does **not** re-stamp the item — it applies the transform directly.
    /// Callers that need read/bookmark state updated should set `isRead` /
    /// `isBookmarked` inside the transform after updating the corresponding
    /// `readItemIDs` / `bookmarkItemIDs` sets on FeedStore.
    ///
    /// - Parameters:
    ///   - index: Index in `visibleItems` to mutate. Guards out-of-bounds.
    ///   - bumpGeneration: If `true`, increments `visibleItemsGeneration`
    ///     so `FeedLoader` caches invalidate. Set to `false` for read-state
    ///     changes that should only re-render the affected card without
    ///     shifting the feed or invalidating the cache.
    ///   - transform: Closure that receives an `inout FeedItem` to modify.
    func mutateVisibleItem(
        at index: Int,
        bumpGeneration: Bool = false,
        _ transform: (inout FeedItem) -> Void
    ) {
        guard visibleItems.indices.contains(index) else { return }
        transform(&visibleItems[index])
        // Always bump the read-state revision: in-place mutations (e.g.
        // read toggles with bumpGeneration: false) must invalidate
        // FeedLoader's filteredItems/dateSections caches, or the UI keeps
        // rendering the pre-mutation stamp.
        readStateRevision &+= 1
        if bumpGeneration {
            visibleItemsGeneration &+= 1
        }
    }

    /// Replace visible cards directly (legacy queue path).
    ///
    /// Used when the legacy `cardQueue` produces card presentations
    /// separately from item publication. Does not touch `visibleItems`
    /// or bump `visibleItemsGeneration` — the caller is responsible
    /// for keeping items and cards in sync.
    func setVisibleCards(_ cards: [FeedCardPresentation]) {
        visibleCards = cards
        visibleCardsGeneration &+= 1
    }

    /// Bump the presentation epoch and capture a fresh context atomically.
    ///
    /// FeedStore always performs these two operations together — splitting
    /// them would let a caller bump the epoch without refreshing the context,
    /// causing every epoch-guarded prepare task to discard valid work.
    ///
    /// - Returns: The old and new contexts so the caller can stop/start
    ///   the runway controller (matching FeedStore's pattern).
    func advanceEpoch(
        mode: FeedPresentationMode,
        filterGeneration: Int64,
        presetGeneration: Int64
    ) -> (old: FeedPresentationContext, new: FeedPresentationContext) {
        presentationEpoch &+= 1
        let old = activePresentationContext
        activePresentationContext = FeedPresentationContext(
            epoch: presentationEpoch, mode: mode,
            filterGeneration: filterGeneration, presetGeneration: presetGeneration
        )
        return (old, activePresentationContext)
    }

    /// Persisted snapshot of the first visible page — written after every
    /// non-append publish so warm starts can paint instantly while the async
    /// pipeline rebuilds the runway. When filters are active, the cache key
    /// includes a filter signature so each configuration gets its own slot.
    private static let pageCacheBaseURL: URL? = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first
    }()

    /// How much of the page the cache keeps: one page, the same depth the pipeline publishes as its first page
    /// (`RunwayPolicy.initialPublishedCount`). More than this is the reader scrolling, not the reader reopening.
    nonisolated static let cachedPageDepth = Reservoir.pageSize

    /// Returns the cache URL for the given filter signature (empty = main).
    ///
    /// The signature is hashed with SHA-256, not `hashValue`: Swift seeds
    /// `hashValue` per process, so a signature-keyed file written by one launch
    /// could never be read by the next one — the cache would miss every time.
    private static func pageCacheURL(filterSignature: String) -> URL? {
        guard let base = pageCacheBaseURL else { return nil }
        if filterSignature.isEmpty {
            return base.appendingPathComponent("visible-page-cache.json")
        }
        let digest = SHA256.hash(data: Data(filterSignature.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("visible-page-cache-\(name.prefix(32)).json")
    }

    struct CachedPage: Codable {
        let items: [FeedItem]
        var visibleItemsGeneration: UInt64
        /// Disk-level media projection for the page's cards: the cache key of each resolved image,
        /// never the image itself. Optional so a page written by an older build still decodes.
        ///
        /// This exists so the restored page can be reconstructed *with* its media, by re-running the
        /// pipeline's own decode, instead of painting placeholders that the first prepared batch then
        /// swaps out under the reader's eyes.
        var cards: [CachedCardMedia]?
    }

    struct CachedCardMedia: Codable {
        let itemID: String
        /// Terminal layout the pipeline decided for this card (`hero` / `thumb` / `text`).
        ///
        /// Persisted so a warm start restores the *prepared* page rather than re-deriving it: without it every card that
        /// had a local image came back as `.hero`, so a reopened feed had different shapes than the session that wrote it
        /// (review P0.2). Optional because a page written by an older build carries only `itemID` + `cacheKey`, and those
        /// entries must keep decoding.
        var layout: String?
        /// `image` / `placeholder` / `none` at publication time — the presentation decision, not the asset.
        var mediaKind: String?
        let cacheKey: String?
    }

    /// Save the current first page so the next warm launch paints instantly.
    ///
    /// Four rules decide *which* page a signature keeps, each one a measured defect:
    ///
    /// 1. **Every publication writes, appends included.** Excluding appends froze the cache at the first flush of a
    ///    session. On a clean container that flush publishes whatever the reservoir holds — measured **2 items**,
    ///    written at first paint and never touched again, so the reopen restored `page[restore] items=2` while the
    ///    reader of the session that wrote it had a full page (`visible-page-cache-ded4e5c9….json items=2`, mtime ==
    ///    first paint, 2026-09-17). Everything a feed does *after* its first page is an append, so the append is
    ///    exactly where a deeper page comes from.
    /// 2. **A page, not the scrollback.** Only the first ``cachedPageDepth`` items are persisted — the depth the
    ///    pipeline itself publishes as a page — so a long scroll cannot turn the next launch into a restore of
    ///    hundreds of cards.
    /// 3. **Never thinner.** A page with fewer items than the one already written for this signature is the
    ///    composition arriving in pieces, not a smaller page.
    /// 4. **Never a page that lost its media.** Cards that carry an image with no cache key to rebuild it would come
    ///    back as placeholders on the next launch (measured: a warm reopen restored `withMedia=17` and the very next
    ///    write persisted `cards: null`), so that write is refused and the page on disk stays.
    ///
    /// One publication is deliberately *not* persisted: a page below ``cachedPageDepth`` while the cold-start
    /// runway is still being built. The composition is still arriving and the page gate is moments away — handing
    /// that snapshot to the next launch is the `partial → better` sequence review P0.3 forbids, and it is how a
    /// clean-container cold start left a 2-card page behind.
    ///
    /// That gate is best-effort by nature: promotion is async, so a cold-start flush can land its page after the
    /// runway flag has already been cleared. Measured on a clean container (2026-09-17): a 7-item first paint was
    /// written, the page reached 20 items **146 ms** later and rule 1 wrote that — which is the rule that actually
    /// keeps the page honest here. Once the runway has stopped preparing one, a short page *is* the composition
    /// (a narrow filter's own page) and is cached exactly as before.
    ///
    /// JSON encode + write run off the main actor so the UI never freezes.
    func cacheVisiblePageIfNeeded(filterSignature: String = "") {
        guard !visibleItems.isEmpty, let url = Self.pageCacheURL(filterSignature: filterSignature) else { return }
        let key = filterSignature.isEmpty ? "main" : "filtered"
        let depth = min(visibleItems.count, Self.cachedPageDepth)
        let written = cachedPages[filterSignature]
        if let written, depth < written.depth {
            logger.info("page[cache] skip sig=\(key) items=\(depth) reason=thinner-than-written kept=\(written.depth)")
            return
        }
        if depth < Self.cachedPageDepth, isPreparingInitialRunway {
            logger.info("page[cache] skip sig=\(key) items=\(depth) reason=runway-still-building")
            return
        }
        let items = Array(visibleItems.prefix(depth))
        let cards = Array(visibleCards.prefix(depth))
        // A page whose cards carry media without the keys to rebuild it has *lost* its media: writing it would hand
        // the next launch placeholders where this launch had images. Whatever is already on disk is the better page.
        if visibleCardCacheKeys.isEmpty, cards.contains(where: { Self.cardHasMedia($0.media) }) {
            logger.info("page[cache] skip sig=\(key) items=\(depth) reason=media-without-keys")
            return
        }
        // Skip the rewrite only when nothing about the page changed — keyed on the *full* fingerprint
        // (`id|layout|hasMedia`), never on the id list alone. The warm path's upgrade-only merge keeps
        // the ids and improves the media, so an id-keyed guard would decide "unchanged", keep a
        // media-less page cached, and hand the next launch the image pop-in it just fixed.
        let fingerprint = Self.pageFingerprint(cards: cards, items: items)
        guard fingerprint != written?.fingerprint else { return }
        cachedPages[filterSignature] = WrittenPage(fingerprint: fingerprint, depth: depth)
        let cardsByID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projection: [CachedCardMedia]? = visibleCardCacheKeys.isEmpty ? nil : items.map { item in
            let card = cardsByID[item.id]
            return CachedCardMedia(
                itemID: item.id,
                layout: card.map { Self.layoutKey($0.layout) },
                mediaKind: card.map { Self.mediaKindKey($0.media) },
                cacheKey: visibleCardCacheKeys[item.id]
            )
        }
        let page = CachedPage(
            items: items,
            visibleItemsGeneration: visibleItemsGeneration,
            cards: projection
        )
        logger.info("page[cache] write sig=\(key) items=\(items.count) cards=\(cards.count) mediaKeys=\(self.visibleCardCacheKeys.count)")
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(page)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.warning("Failed to cache visible page: \(error)")
            }
        }
    }

    /// Restore a previously-cached first page so the UI paints instantly.
    /// Returns nil when no cache exists or decoding fails.
    /// File read + JSON decode run off the main actor so startup never janks.
    /// Pass a filter signature to restore a filtered/config-specific page.
    func restoreCachedPage(filterSignature: String = "") async -> (items: [FeedItem], cards: [CachedCardMedia]?, generation: UInt64)? {
        guard let url = Self.pageCacheURL(filterSignature: filterSignature) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let page = try? JSONDecoder().decode(CachedPage.self, from: data),
                  !page.items.isEmpty else { return nil }
            return (page.items, page.cards, page.visibleItemsGeneration)
        }.value
    }


    /// `id|layout|hasMedia` per card, in order — the key that decides whether the page cache is stale.
    static func pageFingerprint(cards: [FeedCardPresentation], items: [FeedItem]) -> String {
        cards.map { card in
            "\(card.item.id)|\(layoutKey(card.layout))|\(mediaKindKey(card.media) == "image" ? "img" : "no")"
        }
        .joined(separator: ",")
    }

    /// The persisted spelling of a layout. Shared by the fingerprint and the persisted decision so the two can never
    /// disagree about what "unchanged" means.
    static func layoutKey(_ layout: FeedCardLayout) -> String {
        switch layout {
        case .hero: return "hero"
        case .thumbnail: return "thumb"
        case .textOnly: return "text"
        }
    }

    /// The layout a persisted `layout` string names, or nil for pages written before layouts were persisted.
    ///
    /// `nonisolated` because it is a pure mapping with no state: the restored-page path (`PreparedPageRestoration`)
    /// rebuilds cards off the main actor, and a string→enum switch has no business forcing a hop back onto it.
    nonisolated static func layout(from key: String) -> FeedCardLayout? {
        switch key {
        case "hero": return .hero
        case "thumb", "thumbnail": return .thumbnail
        case "text", "textOnly": return .textOnly
        default: return nil
        }
    }

    /// The persisted spelling of the media decision.
    static func mediaKindKey(_ media: ResolvedCardMedia) -> String {
        switch media {
        case .image: return "image"
        case .placeholder: return "placeholder"
        case .none: return "none"
        }
    }

    /// Whether a card carries a resolved image.
    private static func cardHasMedia(_ media: ResolvedCardMedia) -> Bool {
        if case .image = media { return true }
        return false
    }

    /// Whether the publication in flight was asked for by the user.
    ///
    /// Three sources, because each covers a case the others miss: the explicit `isUserInitiated`
    /// flag from a caller that knows; the `.refreshing` marker `setFilter`/`manualRefresh` already
    /// set; and the phase's own `reason`, which is in scope in both publication paths and therefore
    /// cannot be forgotten at a call site — `.startup` is background work, everything else
    /// (`filterChange`, `presetChange`, `manualRefresh`, `source`, `collection`) is the user asking
    /// for a different composition. Getting this wrong at one call site is what broke two attempts
    /// at the rule, so deriving it where it cannot be missed matters more than the plumbing.
    private var publicationIsUserInitiated: Bool {
        if case .preparing(_, let reason) = feedDisplayPhase, reason != .startup { return true }
        return loadingState == .refreshing
    }

    func setLoadingState(_ state: FeedLoadingState) {
        let old = loadingState
        loadingState = state
        if old != state {
            logger.info("loadingState: \(String(describing: old)) → \(String(describing: state))")
        }
    }

    func setFeedDisplayPhase(_ phase: FeedDisplayPhase) {
        let old = feedDisplayPhase
        feedDisplayPhase = phase
        if case .preparing = old, case .preparing = phase { return }
        logger.info("feedDisplayPhase: \(String(describing: old)) → \(String(describing: phase))")
    }

    func setIsPreparingInitialRunway(_ value: Bool) {
        isPreparingInitialRunway = value
    }

    /// Reset all display state consistently.
    ///
    /// Resets `activePresentationContext` alongside `presentationEpoch`
    /// so epoch-guarded tasks don't encounter a stale context after a reset.
    func clear() {
        visibleItems = []
        visibleCards = []
        loadingState = .idle
        feedDisplayPhase = .preparing(contextID: 0, reason: .startup)
        isPreparingInitialRunway = false
        presentationEpoch = 0
        visibleItemsGeneration = 0
        visibleCardsGeneration = 0
        readStateRevision = 0
        activePresentationContext = FeedPresentationContext(
            epoch: 0, mode: .main,
            filterGeneration: 0, presetGeneration: 0
        )
    }
}
