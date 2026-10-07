import Foundation
import UIKit

/// Actor that manages the editorial sequence, concurrent preparation,
/// and contiguous-prefix promotion. Replaces ReadyCardQueue.
///
/// Key invariant: cards finish preparation out of order, but are only
/// promoted in contiguous editorial order. A slow item at position 3
/// blocks promotion of items 4..N until it reaches a terminal state.
actor CardPreparationCoordinator {

    // MARK: - Internal state

    private var orderedItems: [FeedItem] = []
    private var stateByID: [String: CardPreparationState] = [:]
    private var resolvedByID: [String: ResolvedCardAsset] = [:]
    private var renderReadyByID: [String: PreparedFeedCard] = [:]

    /// IDs of the items still waiting to be published, i.e. the ones that are in
    /// `orderedItems`. Kept as a set so `storeResolved`/`storeRenderReady` can
    /// answer "is this ID still part of the runway?" in O(1): an ID that was
    /// published (and dropped from `orderedItems` by ``trimToPublishedIndex()``)
    /// must never re-enter the maps. A late deferred retry used to do exactly
    /// that, and `fillRunway` counted those orphans as ready depth — supply stopped
    /// early on a number that did not correspond to any card that could be
    /// published (S06).
    ///
    /// Every mutation of `orderedItems` keeps this in step: replacement and
    /// append assign/union, `trimToPublishedIndex()` subtracts.
    private var editorialIDs: Set<String> = []

    /// IDs of items whose prepare task is still running, keyed by a per-dispatch
    /// token. `handleMemoryPressure` resets `nextPrepareIndex` backward so
    /// demoted items can be re-decoded; without this set, `fillRunway` would
    /// re-dispatch every item between the demoted index and the old
    /// `nextPrepareIndex`, double-preparing the ones already in flight.
    /// Token-keyed so a stale task completing after a context switch doesn't
    /// remove the new context's in-flight marker (review finding).
    private var inFlightIDs: [String: UUID] = [:]

    /// Active deferred-retry tasks, keyed by item ID. Cancelled on context
    /// change so stale upgrades can't mutate a newer coordinator state.
    private var deferredRetryTasks: [String: Task<Void, Never>] = [:]

    /// Per-ID token for the retry in `deferredRetryTasks`, for the same reason
    /// `inFlightIDs` is token-keyed: the retry's `defer` runs after the body, and
    /// a newer retry for the same ID can already be installed by then. Removing
    /// by ID alone dropped the *new* task, which then survived the next context
    /// switch uncancelled (review finding).
    private var deferredRetryTokens: [String: UUID] = [:]

    /// Called when artwork that missed its deadline finally resolves and the card has been refreshed in
    /// the render-ready store. The store uses it to heal the *published* card in place; without a
    /// consumer the image waits for the next composition, which on a stalled feed is never.
    private var mediaUpgradeHandler: (@MainActor (PreparedFeedCard) async -> Void)?

    /// Install the media-upgrade consumer. Called once by `FeedStore` when the pipeline is wired.
    func setMediaUpgradeHandler(_ handler: @escaping @MainActor (PreparedFeedCard) async -> Void) {
        mediaUpgradeHandler = handler
    }

    /// Index of the next item that hasn't started preparation.
    private var nextPrepareIndex: Int = 0

    /// Index of the first item whose render-ready card hasn't been taken
    /// by a call to `takeRenderReadyPrefix`.
    private var nextPublishIndex: Int = 0

    /// Continuations waiting for the contiguous prefix to grow.
    /// Woken by storeRenderReady when a new card joins the prefix.
    /// Boxed so the onCancel handler and the registration site can both
    /// reach the same continuation reference (fixes leaked suspended tasks
    /// when the calling task is cancelled mid-wait).
    private var prefixWaiters: [UUID: PrefixWaiter] = [:]
    private final class PrefixWaiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
    }

    /// The context this coordinator is currently serving.
    private var activeContext: FeedPresentationContext?

    // MARK: - Dependencies

    private let mediaStore: MediaAssetStore
    private let policy: RunwayPolicy
    private let limiter: AsyncLimiter

    // MARK: - Initialization

    init(mediaStore: MediaAssetStore, policy: RunwayPolicy) {
        self.mediaStore = mediaStore
        self.policy = policy
        self.limiter = AsyncLimiter(categories: [
            ("direct_image", 8),
            ("article_html", 3),
            ("disk_decode", 4),
            ("background_retry", 2),
        ])
    }

    // MARK: - Public API

    /// Replace the entire editorial sequence. An older context (lower epoch)
    /// can never replace a newer one — this prevents stale tasks from
    /// resurrecting a discarded feed composition.
    func replaceEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        // Guard: never let an older epoch overwrite a newer one.
        if let current = activeContext, context.epoch < current.epoch {
            return
        }
        // cancelAll is intentionally a no-op — downloads are shared across
        // contexts. But it's an actor call that creates a suspension point.
        // Re-validate the epoch guard after resuming to prevent a race where
        // a newer context was installed during the suspension.
        await mediaStore.cancelAll()
        if let current = activeContext, context.epoch < current.epoch {
            return
        }
        // Deduplicate within the batch itself — duplicate IDs in the same
        // batch would corrupt renderReadyByID and permanently block the
        // publish index when the first commit removes the shared card.
        var seenIDs = Set<String>()
        let uniqueItems = items.filter { seenIDs.insert($0.id).inserted }
        orderedItems = uniqueItems
        editorialIDs = Set(uniqueItems.map(\.id))
        stateByID.removeAll()
        resolvedByID.removeAll()
        renderReadyByID.removeAll()
        // In-flight tasks from the old context are orphans — their guarded
        // writes will be rejected, so they must not block re-preparation of
        // same-ID items in the new context.
        inFlightIDs.removeAll()
        // Cancel any in-progress deferred retries and clear their state.
        for (_, task) in deferredRetryTasks { task.cancel() }
        deferredRetryTasks.removeAll()
        deferredRetryTokens.removeAll()
        nextPrepareIndex = 0
        nextPublishIndex = 0
        activeContext = context

        // Wake any prefix waiters — the sequence changed so they should
        // re-evaluate whether their prefix condition is met.
        let waiters = prefixWaiters
        prefixWaiters.removeAll()
        for (_, box) in waiters {
            if let c = box.continuation {
                box.continuation = nil
                c.resume()
            }
        }
    }

    /// Append items to the end of the editorial sequence. Filters out
    /// items whose IDs are already known (single source of truth for
    /// deduplication — callers don't need to pre-filter).
    func appendEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        guard context == activeContext else { return }
        // Track both existing and newly-seen IDs within this batch so
        // intra-batch duplicates are also filtered.
        var seenIDs = Set(orderedItems.map(\.id))
        let newItems = items.filter { seenIDs.insert($0.id).inserted }
        guard !newItems.isEmpty else { return }
        orderedItems.append(contentsOf: newItems)
        editorialIDs.formUnion(newItems.map(\.id))
    }

    /// Fill the runway up to the specified target count of render-ready cards.
    func fillRunway(targetRenderReady: Int, context: FeedPresentationContext) async {
        guard context == activeContext else { return }
        let currentReady = renderReadyByID.count
        guard currentReady < targetRenderReady else { return }

        // Start preparation for items up to targetRenderReady * 2 (buffer)
        let prepareUpTo = min(orderedItems.count, nextPublishIndex + targetRenderReady * 2)
        while nextPrepareIndex < prepareUpTo {
            let idx = nextPrepareIndex
            let item = orderedItems[idx]
            nextPrepareIndex += 1
            // After a memory-pressure demotion, nextPrepareIndex may have been
            // reset backward across items whose tasks are still in flight.
            // Those must not be dispatched a second time — advance past them
            // and let the original task finish.
            guard inFlightIDs[item.id] == nil else { continue }
            prepareItem(at: idx, item: item, context: context)
        }
    }

    /// Take the longest contiguous prefix of render-ready cards starting
    /// from `nextPublishIndex`. Returns cards in editorial order.
    /// Published cards are removed from internal maps — the UI holds a strong
    /// reference to the UIImage, so the coordinator doesn't need to retain it.
    ///
    /// Prefer `peekRenderReadyPrefix` + `commitPublished` for callers that
    /// need to validate cancellation/context before consuming cards.
    func takeRenderReadyPrefix(
        maximumCount: Int,
        context: FeedPresentationContext
    ) -> [PreparedFeedCard] {
        let cards = peekRenderReadyPrefix(maximumCount: maximumCount, context: context)
        let ids = cards.map(\.id)
        guard commitPublished(expectedIDs: ids, context: context) else { return [] }
        return cards
    }

    /// Non-destructive peek at the contiguous render-ready prefix. Does NOT
    /// advance nextPublishIndex or remove cards from maps. Useful for waiting
    /// loops that need to check readiness without risking card loss on cancel.
    func peekRenderReadyPrefix(
        maximumCount: Int,
        context: FeedPresentationContext
    ) -> [PreparedFeedCard] {
        guard context == activeContext else { return [] }
        var ready: [PreparedFeedCard] = []
        var idx = nextPublishIndex

        while ready.count < maximumCount, idx < orderedItems.count {
            let item = orderedItems[idx]
            if let card = renderReadyByID[item.id] {
                ready.append(card)
                idx += 1
            } else {
                break
            }
        }
        return ready
    }

    /// Suspend until the contiguous prefix reaches `minimumCount`, or the
    /// deadline expires, or the context changes. Returns the prefix at that
    /// point (may be shorter than minimumCount if the deadline fired).
    ///
    /// Unlike the old polling loop in FeedStore, this suspends passively —
    /// `storeRenderReady` wakes waiters when a new card joins the prefix.
    /// This eliminates the 300ms polling interval and the race window at
    /// the deadline instant.
    ///
    /// The deadline is a REAL wake source, not a comment: the waiter
    /// suspends in a task group raced against `Task.sleep(until:)`, so a
    /// waiter that missed its `storeRenderReady` wake (suspended between
    /// the peek above and its registration) still re-evaluates at the
    /// deadline instead of suspending forever.
    func waitForContiguousPrefix(
        minimumCount: Int,
        maximumCount: Int,
        deadline: ContinuousClock.Instant,
        context: FeedPresentationContext
    ) async -> [PreparedFeedCard] {
        while true {
            guard !Task.isCancelled else { return [] }
            let cards = peekRenderReadyPrefix(
                maximumCount: maximumCount, context: context
            )
            if cards.count >= minimumCount { return cards }
            guard context == activeContext else { return [] }
            guard ContinuousClock().now < deadline else { return cards }

            // Suspend until storeRenderReady signals OR the deadline fires.
            // The PrefixWaiter box lets both the registration site and the
            // onCancel handler reach the same continuation — the first to
            // fire resumes it, the second is a no-op. The old code only
            // removed the waiter from the dictionary, permanently leaking
            // the suspended task (review finding).
            let waiterID = UUID()
            let box = PrefixWaiter()
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.suspendForPrefixSignal(waiterID: waiterID, box: box)
                }
                // Primary deadline: always wakes the group even when zero
                // storeRenderReady calls happen while this waiter is
                // suspended. The loop re-checks prefix/context/deadline.
                group.addTask {
                    try await Task.sleep(until: deadline, tolerance: .milliseconds(100))
                }
                // First to finish wins; cancel the loser.
                _ = try await group.next()
                group.cancelAll()
            }
        }
    }

    /// Register a PrefixWaiter and suspend until it is resumed by
    /// `storeRenderReady`, cancellation, or the deadline race cancelling
    /// this child task.
    private func suspendForPrefixSignal(waiterID: UUID, box: PrefixWaiter) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                box.continuation = cont
                prefixWaiters[waiterID] = box
                // If cancelled between entering withTaskCancellationHandler
                // and this line, onCancel has already fired (no-op since
                // continuation was nil). Re-check and resume immediately.
                if Task.isCancelled, let c = box.continuation {
                    box.continuation = nil
                    prefixWaiters.removeValue(forKey: waiterID)
                    c.resume()
                }
            }
        } onCancel: {
            // Route through the actor to serialize with storeRenderReady.
            // Resuming the continuation directly from onCancel races with
            // storeRenderReady's resume — both can fire concurrently,
            // causing a double-resume fatal error (review finding).
            Task { [weak self] in
                await self?.cancelPrefixWaiter(waiterID)
            }
        }
    }

    /// Commit previously peeked cards as published. Validates that the
    /// context is still active and that the expected IDs match the actual
    /// contiguous prefix — a stale or duplicate commit is rejected.
    /// Returns true if the commit succeeded (cards were removed and
    /// nextPublishIndex advanced); false if the context changed or the
    /// prefix no longer matches.
    func commitPublished(
        expectedIDs: [String],
        context: FeedPresentationContext
    ) -> Bool {
        guard context == activeContext else { return false }

        // Verify expectedIDs match the actual contiguous prefix.
        let actual = peekRenderReadyPrefix(
            maximumCount: expectedIDs.count,
            context: context
        ).map(\.id)
        guard actual == expectedIDs else { return false }

        // Commit: advance publish index and clean up maps in one pass.
        nextPublishIndex += expectedIDs.count
        for id in expectedIDs {
            renderReadyByID.removeValue(forKey: id)
            resolvedByID.removeValue(forKey: id)
            stateByID.removeValue(forKey: id)
        }
        trimToPublishedIndex()
        return true
    }

    /// Drop published items (everything before `nextPublishIndex`) from
    /// `orderedItems` so the editorial sequence doesn't grow unboundedly
    /// across many append/commit cycles. Both indices are shifted to match
    /// the new array positions, so `fillRunway` and the count accessors keep
    /// referring to the same items.
    private func trimToPublishedIndex() {
        guard nextPublishIndex > 0 else { return }
        let trimmed = nextPublishIndex
        for item in orderedItems.prefix(trimmed) {
            // Published IDs were already removed by commitPublished; these
            // removals are belt-and-suspenders for any stragglers.
            stateByID.removeValue(forKey: item.id)
            resolvedByID.removeValue(forKey: item.id)
            renderReadyByID.removeValue(forKey: item.id)
            // The item stops being part of the runway here: from now on a write
            // for this ID is a write for a card the reader already has.
            editorialIDs.remove(item.id)
        }
        orderedItems.removeFirst(trimmed)
        nextPublishIndex = 0
        nextPrepareIndex = max(0, nextPrepareIndex - trimmed)
    }

    /// Discard all state for a context that's no longer active.
    func invalidate(context: FeedPresentationContext) {
        // Only invalidate the given context — never destroy the active one.
        guard context != activeContext else { return }
        // Currently dead code (no callers). When wired: clear only maps
        // belonging to the stale context, not everything.
    }

    func handleMemoryPressure() {
        // Demote distant render-ready cards back to resolved (disk-level)
        // instead of deleting them permanently. If they're deleted, the
        // feed stops at the first missing card because fillRunway only
        // advances nextPrepareIndex forward. Demotion allows re-decode
        // when the user scrolls closer.
        let keepUpTo = nextPublishIndex + policy.publishedAheadTarget
        for (id, _) in renderReadyByID {
            guard let idx = orderedItems.firstIndex(where: { $0.id == id }),
                  idx >= keepUpTo else { continue }
            // Demote: revert state to resolved so fillRunway can re-decode.
            if let asset = resolvedByID[id] {
                stateByID[id] = .resolved(asset)
            }
            renderReadyByID.removeValue(forKey: id)
            // Reset nextPrepareIndex so fillRunway picks this item up again.
            if idx < nextPrepareIndex {
                nextPrepareIndex = idx
            }
        }
        Task { await mediaStore.clearMemoryCache() }
    }

    /// Number of render-ready cards ahead of the publish index (not yet published).
    var renderReadyCount: Int {
        // Single pass over orderedItems — a firstIndex scan per map key would
        // be O(n²) with hundreds of keys and thousands of items.
        var count = 0
        for i in nextPublishIndex..<orderedItems.count {
            if renderReadyByID[orderedItems[i].id] != nil { count += 1 }
        }
        return count
    }

    /// Why a scheduled publication had nothing to promote. A page that is handed to the pipeline and never
    /// appears leaves no other trace, so the sequence's own numbers have to be readable.
    var editorialDiagnostics: String {
        "ordered=\(orderedItems.count) nextPublish=\(nextPublishIndex) nextPrepare=\(nextPrepareIndex) ready=\(renderReadyByID.count) resolved=\(resolvedByID.count) inFlight=\(inFlightIDs.count) activeEpoch=\(activeContext.map { String($0.epoch) } ?? "-")"
    }

    /// Number of resolved (disk-level) cards ahead of the publish index.
    var resolvedCount: Int {
        var count = 0
        for i in nextPublishIndex..<orderedItems.count {
            if resolvedByID[orderedItems[i].id] != nil { count += 1 }
        }
        return count
    }

    /// Total items in the editorial sequence (includes published + pending).
    var editorialCount: Int { orderedItems.count }

    /// Remaining editorial items after the publish index.
    var editorialAheadCount: Int {
        max(0, orderedItems.count - nextPublishIndex)
    }

    // MARK: - Private

    private func prepareItem(
        at index: Int, item: FeedItem, context: FeedPresentationContext
    ) {
        setState(item.id, to: .queued)
        let dispatchToken = UUID()
        inFlightIDs[item.id] = dispatchToken
        let deadline = deadlineForIndex(index)
        let kind = placeholderKind(for: item)

        Task { [weak self] in
            guard let self else { return }
            let startedAt = ContinuousClock().now
            defer {
                // Only remove if this dispatch's token still matches — stale
                // tasks from old contexts must not strip a new context's marker.
                Task { await self.markPrepareFinished(item.id, token: dispatchToken) }
            }

            // Resolve to disk-level asset
            await self.setState(item.id, to: .resolvingDirectImage)
            let asset = await self.resolveImageAsset(
                for: item, context: context, deadline: deadline
            )

            let resolved: ResolvedCardAsset
            if let asset {
                resolved = .image(asset)
            } else if item.hasPotentialImage {
                resolved = .placeholder(kind)
            } else {
                resolved = .none
            }

            let outcome: String
            switch resolved {
            case .image: outcome = "image"
            case .placeholder: outcome = "placeholder"   // deadline miss or failure — the card goes out without its artwork
            case .none: outcome = "none"
            }
            let elapsed = ContinuousClock().now - startedAt
            let elapsedMs = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            ImageLog.prepareOutcome(itemID: item.id, outcome: outcome, ms: elapsedMs, index: index)

            // Atomic guard+write — no suspension between check and write
            // so a context change can't sneak in (TOCTOU fix).
            guard await self.storeResolved(item.id, asset: resolved, context: context,
                                           dispatchToken: dispatchToken) else { return }

            // Decode to render-ready
            await self.setState(item.id, to: .decoding)
            let renderReady = await self.decodeToRenderReady(
                item: item, asset: resolved, context: context
            )

            // Atomic guard+write — context-validated in one actor transaction.
            guard await self.storeRenderReady(item.id, card: renderReady, context: context,
                                              dispatchToken: dispatchToken) else { return }

            // If image missed the deadline, start a deferred retry. The card goes
            // out as text-only and **stays that way for this session**: the retry
            // only refreshes the runway entry, so the next composition can publish
            // the image — a published presentation is never mutated (P0.1).
            if case .placeholder = resolved {
                Task { [weak self] in
                    await self?.startDeferredImageRetry(
                        for: item, at: index, kind: kind, context: context
                    )
                }
            }
        }
    }

    // MARK: - Actor state helpers (called from Task closures)

    private func setState(_ id: String, to state: CardPreparationState) {
        stateByID[id] = state
    }

    private func markPrepareFinished(_ id: String, token: UUID? = nil) {
        if let token {
            guard inFlightIDs[id] == token else { return }
        }
        inFlightIDs.removeValue(forKey: id)
    }

    private func isContextActive(_ context: FeedPresentationContext) -> Bool {
        context == activeContext
    }

    /// Atomic guard+write: stores the resolved asset only if the context is
    /// still active **and the ID is still waiting to be published**. Callers
    /// suspended between their last context check and the write are protected —
    /// the check and write happen in one actor transaction with no suspension
    /// point between them (TOCTOU fix). The membership check is what keeps a
    /// late retry for an already-published card out of the runway.
    ///
    /// `dispatchToken` is the token of the prepare dispatch this write belongs
    /// to, when there is one: it prevents a superseded task from clearing a
    /// newer dispatch's in-flight marker (and thus from letting `fillRunway`
    /// dispatch the same ID a third time).
    @discardableResult
    private func storeResolved(_ id: String, asset: ResolvedCardAsset,
                                context: FeedPresentationContext,
                                dispatchToken: UUID? = nil) -> Bool {
        guard context == activeContext else { return false }
        guard editorialIDs.contains(id) else { return false }
        resolvedByID[id] = asset
        stateByID[id] = .resolved(asset)
        markPrepareFinished(id, token: dispatchToken)
        return true
    }

    /// Atomic guard+write for render-ready cards. Same TOCTOU fix, same
    /// "still waiting to be published" rule, same dispatch-token rule as above.
    @discardableResult
    private func storeRenderReady(_ id: String, card: PreparedFeedCard,
                                   context: FeedPresentationContext,
                                   dispatchToken: UUID? = nil) -> Bool {
        guard context == activeContext else { return false }
        guard editorialIDs.contains(id) else { return false }
        renderReadyByID[id] = card
        stateByID[id] = .renderReady(card)
        markPrepareFinished(id, token: dispatchToken)

        // Wake any callers suspended in waitForContiguousPrefix so they
        // can re-evaluate whether the prefix is now long enough.
        let waiters = prefixWaiters
        prefixWaiters.removeAll()
        for (_, box) in waiters {
            if let c = box.continuation {
                box.continuation = nil
                c.resume()
            }
        }
        return true
    }

    private func cancelPrefixWaiter(_ id: UUID) {
        guard let box = prefixWaiters.removeValue(forKey: id),
              let c = box.continuation else { return }
        box.continuation = nil
        c.resume()
    }

    private func removePrefixWaiter(_ id: UUID) {
        prefixWaiters.removeValue(forKey: id)?.continuation = nil
    }

    private func resolveImageAsset(
        for item: FeedItem,
        context: FeedPresentationContext,
        deadline: ContinuousClock.Instant
    ) async -> ResolvedImageAsset? {
        if let imageURL = item.bestImageURL.flatMap(URL.init(string:)) {
            let request = ImageResolutionRequest(
                itemID: item.id,
                url: imageURL,
                cacheKey: ImageCacheKey.forURL(imageURL),
                source: .directImageURL
            )

            // Race: resolution vs deadline. withSlot throws CancellationError
            // when the caller was cancelled while queued — degrade to nil
            // (placeholder) exactly like a deadline miss.
            return try? await raceWithDeadline(deadline: deadline) {
                try await self.limiter.withSlot(category: "direct_image") {
                    await self.mediaStore.resolve(request: request)
                }
            }
        }

        // An item whose artwork lives only on its article page had no path here at all: this returned nil at
        // once, the deferred retry re-ran the very same function and returned in 1 ms, and the card kept its
        // placeholder for the whole session — measured on one fast scroll: 168 `deferred-retry … image=0
        // ms=1`, not one image, on a feed where every card carried `canResolveArticleImage`. The resolver the
        // legacy path already uses is called here too, under the same deadline and the same slot budget; the
        // candidate lookup happens before a slot is taken, so an article page never occupies a download slot.
        guard item.canResolveArticleImage, let articleURL = URL(string: item.url) else {
            // Why a card ends with a stand-in and never gets art: the direct URL is absent or unparsable and
            // there is no article page to ask. Measured on a fast scroll: 224 such retries in one session,
            // every one `image=0 ms=1` — the retry is instantaneous because there is nothing to try.
            let raw = item.bestImageURL
            let rawState = raw == nil ? "absent" : (URL(string: raw!) == nil ? "unparsable" : "present")
            Log.feed.info("[Media] unresolved item=\(item.id) rawImage=\(rawState) canResolveArticle=\(item.canResolveArticleImage ? 1 : 0) — no artwork source for this item")
            return nil
        }
        let candidates = await ArticleImageResolver.shared.imageURLs(for: articleURL)
        if candidates.isEmpty {
            Log.feed.info("[Media] unresolved item=\(item.id) rawImage=\((item.bestImageURL ?? "nil") == "nil" ? "absent" : "present") articleHost=\(articleURL.host ?? "-") — the article page yielded no candidates")
        }
        for candidate in candidates.prefix(3) {
            guard !Task.isCancelled, ContinuousClock().now < deadline else { return nil }
            let request = ImageResolutionRequest(
                itemID: item.id,
                url: candidate,
                cacheKey: ImageCacheKey.forURL(candidate),
                source: .articleOpenGraph
            )
            let resolved: ResolvedImageAsset? = try? await raceWithDeadline(deadline: deadline) {
                try await self.limiter.withSlot(category: "direct_image") {
                    await self.mediaStore.resolve(request: request)
                }
            }
            if let resolved { return resolved }
        }
        return nil
    }

    /// Start a deferred image retry with an extended deadline. The card is
    /// already published as text-only (`.none` + `.textOnly`) — it does NOT
    /// block the contiguous prefix. This retry runs in the background:
    ///
    /// - Image arrives → kept in the render-ready cache for the next composition
    /// - Deadline fires → no-op (card is already terminal text-only)
    private func startDeferredImageRetry(
        for item: FeedItem,
        at index: Int,
        kind: PlaceholderKind,
        context: FeedPresentationContext
    ) async {
        // Cancel any prior retry for this ID.
        deferredRetryTasks[item.id]?.cancel()
        let retryDeadline = ContinuousClock().now.advanced(by: .seconds(12))
        let retryToken = UUID()
        deferredRetryTokens[item.id] = retryToken

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { await self.cleanupDeferredRetry(item.id, token: retryToken) }
            }

            let retryStartedAt = ContinuousClock().now
            let asset = await self.resolveImageAsset(
                for: item, context: context,
                deadline: retryDeadline
            )
            let retryElapsed = ContinuousClock().now - retryStartedAt
            let retryMs = Int(retryElapsed.components.seconds * 1_000 + retryElapsed.components.attoseconds / 1_000_000_000_000_000)

            guard !Task.isCancelled, let asset else {
                // Timeout or cancellation — card stays text-only (already OK).
                ImageLog.deferredRetry(itemID: item.id, ms: retryMs, gotImage: false)
                return
            }
            ImageLog.deferredRetry(itemID: item.id, ms: retryMs, gotImage: true)

            // Image arrived! Upgrade the card to hero.
            await self.upgradeDeferredToHero(
                item: item, asset: asset, context: context
            )
        }
        deferredRetryTasks[item.id] = task
    }

    /// Upgrade a deferred-retry card from text-only to hero with image.
    ///
    /// The card's **published presentation is immutable**: once a card has left
    /// the render-ready runway, its media and layout do not change, because
    /// activating the hero slot changes the card's height and would shift
    /// everything below it while the user is reading. A late image is therefore
    /// kept for the next composition instead of being applied in place.
    private func upgradeDeferredToHero(
        item: FeedItem, asset: ResolvedImageAsset, context: FeedPresentationContext
    ) async {
        await setState(item.id, to: .decoding)
        let resolved: ResolvedCardAsset = .image(asset)
        _ = await storeResolved(item.id, asset: resolved, context: context)
        guard !Task.isCancelled else { return }

        let renderReady = await decodeToRenderReady(
            item: item, asset: resolved, context: context
        )
        guard !Task.isCancelled, case .image = renderReady.media else { return }

        // The published presentation is immutable in the sense that matters: a card never grows a hero
        // slot under a reader who is mid-scroll. What is not immutable is the *frame that was already
        // reserved* — a card showing a stand-in at the layout it will keep can take the real image
        // without moving anything below it. So the runway entry is refreshed first — while the ID is
        // still waiting to be published; a card that was already published has been trimmed out of the
        // sequence and must not be re-inserted into the maps (S06) — and the media-upgrade consumer
        // (the store) then heals the published card when the layout allows it.
        _ = await storeRenderReady(item.id, card: renderReady, context: context)
        if let handler = mediaUpgradeHandler {
            await handler(renderReady)
        }
    }

    /// Remove tracking state for a completed deferred retry. Token-checked:
    /// this runs from the retry's own `defer`, so by the time an older retry
    /// unwinds a newer one for the same ID can already own the slot — removing
    /// by ID alone would drop the new task, which would then survive the next
    /// `replaceEditorialSequence` uncancelled.
    private func cleanupDeferredRetry(_ id: String, token: UUID? = nil) {
        if let token {
            guard deferredRetryTokens[id] == token else { return }
        }
        deferredRetryTokens.removeValue(forKey: id)
        deferredRetryTasks.removeValue(forKey: id)
    }

    private func decodeToRenderReady(
        item: FeedItem,
        asset: ResolvedCardAsset,
        context: FeedPresentationContext
    ) async -> PreparedFeedCard {
        let media: RenderReadyMedia
        let layout: PreparedCardLayout

        switch asset {
        case .image(let resolvedAsset):
            if let image = await mediaStore.decodedImage(for: resolvedAsset.cacheKey) {
                let renderImage = RenderImage(cacheKey: resolvedAsset.cacheKey, image: image)
                media = .image(renderImage)
                layout = .hero
            } else {
                media = .placeholder(placeholderKind(for: item))
                layout = .textOnly
            }

        case .placeholder:
            // Never publish a placeholder in a hero slot — a card without
            // its real image must render as text-only. The deferred retry in
            // prepareItem refreshes the *runway entry* when the image arrives,
            // so the next composition publishes it with media; this session's
            // published card keeps its terminal text-only decision (P0.1).
            media = .none
            layout = .textOnly

        case .none:
            media = .none
            layout = .textOnly
        }

        return PreparedFeedCard(
            item: item,
            media: media,
            layout: layout,
            presentationEpoch: context.epoch
        )
    }

    private func deadlineForIndex(_ index: Int) -> ContinuousClock.Instant {
        let duration: Duration
        if index < policy.initialPublishedCount {
            duration = policy.initialViewportDeadline
        } else if index < policy.renderReadyTarget {
            duration = policy.nearRunwayDeadline
        } else {
            duration = policy.deepRunwayDeadline
        }
        return ContinuousClock().now.advanced(by: duration)
    }

    private func placeholderKind(for item: FeedItem) -> PlaceholderKind {
        if item.isYouTube { return .video }
        if item.isPodcast { return .podcast }
        if item.isForum { return .forum }
        return .article
    }
}

// MARK: - Deadline Helper

/// Race an async operation against a deadline. Uses TaskGroup so the first
/// to complete wins — the deadline is a hard guarantee, not a cooperative
/// cancellation request. If the deadline fires first, the operation's
/// TaskGroup child is cancelled (but the actual download may continue in
/// shared MediaAssetStore state — that's fine; this caller abandons the
/// wait and returns nil, which the coordinator converts to a placeholder).
///
/// The operation's result is returned only if it completes before the
/// deadline. Otherwise nil is returned and the operation is abandoned.
/// Throws when the operation itself throws (e.g. withSlot's
/// CancellationError for a caller cancelled while queued).
private func raceWithDeadline<T: Sendable>(
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async throws -> T?
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        // Runner: the actual operation
        group.addTask {
            return try await operation()
        }
        // Timer: fires at deadline, returns nil
        group.addTask {
            try? await Task.sleep(until: deadline, clock: .continuous)
            return nil
        }
        // First to complete wins; cancel the other
        let result = try await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

