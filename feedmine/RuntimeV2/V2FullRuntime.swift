import Foundation
import FeedDomain
import FeedMedia
import FeedRuntime
import FeedStorage

/// The durable user-state port for a runtime-composed card (plan §5.2, ADR-004 D6/D7, D12).
///
/// `FeedSessionUserActions` exists so durable intentions have exactly one path: the session never writes
/// user state itself, and the app decides how a card's identity maps onto the authority that holds
/// bookmarks and read state. For a card the runtime composed, this type is that mapping, and it spans
/// three databases in the order ADR-004 D6 fixes:
///
/// 1. **The durable subject.** A card becomes a legacy item id — the value `user.sqlite` is keyed by and
///    legacy hydration reads (`BookmarkStore.bookmarkedItems` joins `bookmark_item.item_id` to
///    `feedmine.sqlite.feed_item`, and that join is the only hydration build 17 has). It is derived the
///    way the legacy reader derives its own ids (`FeedItem.generateID` over the source URL and what the
///    card froze: the external action's URL, or the title and the declared date), so a legacy re-fetch of
///    the same article lands on the same id instead of beside it.
/// 2. **The authority and the runtime projection**, through `UserStateBridge`: the intention, the
///    `bookmark_item` row and the snapshot commit in `user.sqlite` first, the runtime's
///    `user_state_projection` after. A failure here is reported and the session keeps the state it was
///    showing (`FeedSession.performBookmark`).
/// 3. **The legacy compatibility projection**, through `LegacyContentProjection`: the `feed_item` row
///    legacy hydrates, its retention pin, and the durable alias (`legacy_item_map`) that lets the runtime
///    — and a reader holding only these two databases — resolve the subject back to the canonical record.
///    It runs for the card the reader acted on and for no other, and it is what makes the bookmark
///    survive the rollback ADR-004 D12 keeps open.
///
/// Every store write is idempotent on its own key, so a retry re-runs the whole path and heals whatever
/// is missing; a step that fails marks the operation failed and throws, rather than reporting an action
/// as done that a relaunch would not show.
///
/// `setRead` takes the same path with one fewer step, and the missing step is a decision rather than an
/// omission: read has no authority row in `user.sqlite`, and the legacy half (the content row and the
/// legacy `feed_item.is_read` write) is the durable-state policy question the owner reserved. It is
/// implemented for the runtime's own state — the same durable subject, the runtime projection, the
/// confirmed state — and named, with evidence, in `docs/runtime-v2/read-state-report.md`.
struct RuntimeCardUserActions: FeedSessionUserActions {
    let cards: PublicationRepository
    let userState: UserStateBridge
    let legacy: LegacyContentProjection

    @MainActor
    func setBookmarked(
        cardID: PublicationCardID,
        wanted: Bool,
        operationID: String
    ) async throws -> FeedSessionUserState {
        guard let card = try cards.card(cardID) else {
            throw RuntimeCardUserActionError.cardUnavailable(cardID)
        }
        let at = Date()
        let subject = try LegacyUserSubject(card: card, legacy: legacy, at: at)

        let outcome = await userState.setBookmarked(
            itemID: subject.itemID,
            wanted: wanted,
            operationID: operationID,
            snapshot: subject.snapshot,
            at: at
        )
        guard outcome.state == .applied else {
            throw RuntimeCardUserActionError.notDurable(
                cardID,
                reason: outcome.reason ?? "the user database write did not complete"
            )
        }

        if wanted {
            do {
                try await legacy.write(subject.content, alias: subject.alias)
            } catch {
                // The bookmark is stored; only the legacy projection is owed. The operation must not
                // claim to be applied, which is the same rule the runtime projection follows — and a
                // retry with a new operation id re-runs the whole path.
                let reason = "legacy content projection failed: \(error.localizedDescription)"
                try? await userState.bookmarks.markOperation(
                    operationID, state: .failed, reason: reason, at: at
                )
                throw RuntimeCardUserActionError.notDurable(cardID, reason: reason)
            }
        }

        // Read state is answered from what the reader would see, in both databases that can hold it:
        // the runtime's own projection of the read intent (the port below writes it) and the legacy
        // content row (every build before this one, and the legacy lane, write that one). A hard `false`
        // would take the read overlay off a card this launch already marked read.
        let read = await readState(subjectID: subject.itemID)
        return FeedSessionUserState(
            cardID: cardID,
            // The card-level state is global across bookmark boxes. The action's `wanted` applies to
            // the list this write targeted; another list may still contain the same durable subject.
            bookmarked: await bookmarkState(subjectID: subject.itemID),
            read: read,
            operationID: operationID
        )
    }

    /// Marks one card read, durably (ADR-004 D6/D7, ADR-007 D5/D7; plan §5.2).
    ///
    /// It is the bookmark's path with the halves this slice can take: the card becomes the same durable
    /// subject (never the card id this runtime allocated), and the runtime's own projection of the read
    /// intent is written through the bridge. The legacy half — the content row and the legacy
    /// `feed_item.is_read` write — is deliberately **not** performed here: it is a durable-state policy
    /// decision the plan reserves for the owner, named with its evidence in
    /// `docs/runtime-v2/read-state-report.md`, and taking it silently would change what the legacy page
    /// contains and what the unread badge counts. So the display id the presentation synthesizes is
    /// never written anywhere by this path, and a read is durable inside the runtime: the history
    /// projection's `read_at_ms` plus the `read` fact the session records under this same operation id.
    @MainActor
    func setRead(
        cardID: PublicationCardID,
        operationID: String
    ) async throws -> FeedSessionUserState {
        guard let card = try cards.card(cardID) else {
            throw RuntimeCardUserActionError.cardUnavailable(cardID)
        }
        let at = Date()
        let subject = try LegacyUserSubject(card: card, legacy: legacy, at: at)

        let outcome = userState.setRead(
            itemID: subject.itemID,
            operationID: operationID,
            at: at
        )
        guard outcome.state == .applied else {
            throw RuntimeCardUserActionError.notDurable(
                cardID,
                reason: outcome.reason ?? "the runtime projection of the read did not complete"
            )
        }

        return FeedSessionUserState(
            cardID: cardID,
            bookmarked: await bookmarkState(subjectID: subject.itemID),
            read: true,
            operationID: operationID
        )
    }

    /// Whether the reader would see this subject as read.
    ///
    /// Two databases can answer, and both answers are honest: the runtime's own projection of the read
    /// intent (written by `setRead`) and the legacy content row the legacy lane writes. Either alone
    /// would deny a read the other recorded, and the session adopts this value into the card it shows.
    private func readState(subjectID: String) async -> Bool {
        if (try? userState.projections.projection(kind: .read, subjectID: subjectID))?.wanted == true {
            return true
        }
        return (try? await legacy.isRead(itemID: subjectID)) ?? false
    }

    /// Whether the reader would see this subject as bookmarked: the authority the app's own bookmark
    /// surface reads (`user.sqlite.bookmark_item`).
    ///
    /// A read confirmation carries the card's bookmark state as well (`FeedSessionUserState` is the whole
    /// confirmed state), so a hard `false` would take the bookmark overlay off a card the reader saved —
    /// including one saved by the legacy lane, which the runtime's own projection never saw.
    private func bookmarkState(subjectID: String) async -> Bool {
        (try? await legacy.bookmarks.isBookmarkedAnywhere(itemID: subjectID)) ?? false
    }
}

/// One published card as durable user state: the subject both databases are keyed by, the bookmark's
/// snapshot, the legacy content row, and the alias that resolves the subject to canonical content.
///
/// The identity is the card's frozen declaration and nothing else — never the card id, which the runtime
/// allocates and a rebuild changes (ADR-004 D7: integer runtime ids are never the only reference).
struct LegacyUserSubject {
    let itemID: String
    let snapshot: BookmarkSnapshot
    let content: LegacyCardContent
    let alias: LegacyItemMapping

    @MainActor
    init(card: PublishedCardRecord, legacy: LegacyContentProjection, at: Date) throws {
        let payload = card.payload
        // The source URL is the one durable evidence of it (ADR-003 D18); a card's payload carries no
        // source URL, and D2 forbids deriving one.
        let sourceURL = try legacy.legacySourceURL(for: payload.origin.sourceID) ?? ""
        let link: String?
        if case .externalURL(let url) = payload.primaryAction {
            link = url.absoluteString
        } else {
            link = nil
        }

        let itemID = FeedItem.generateID(
            sourceURL: sourceURL,
            guid: nil,
            link: link,
            title: payload.title,
            publishedAt: payload.publishedAt
        )
        let snapshot = BookmarkSnapshot(
            itemID: itemID,
            listID: legacy.bookmarks.defaultListID(),
            title: payload.title ?? "",
            url: link,
            sourceTitle: payload.origin.sourceDisplayName,
            sourceURL: sourceURL.isEmpty ? nil : sourceURL,
            excerpt: payload.primaryText.map { FeedTextSanitizer.displayExcerpt($0) },
            // The payload's media references name published bytes by digest, and publication composes no
            // media today: a digest is not an address, so the row declares none instead of one the
            // legacy renderer would try to fetch.
            mediaURL: nil,
            authoredAt: payload.publishedAt,
            capturedAt: at
        )
        self.itemID = itemID
        self.snapshot = snapshot
        self.content = LegacyCardContent(snapshot: snapshot)
        self.alias = LegacyItemMapper.mapping(
            legacyItemID: itemID,
            legacySourceURL: sourceURL,
            record: payload.origin.originRecordID,
            revision: payload.origin.originRevisionID,
            material: LegacyItemMapper.material(
                guid: nil,
                link: link,
                title: payload.title,
                publishedAt: payload.publishedAt,
                disambiguator: LegacyItemMapper.fallbackDisambiguator(legacyItemID: itemID)
            ),
            mappedAt: at
        )
    }
}

enum RuntimeCardUserActionError: Error, Equatable, CustomStringConvertible {
    /// The card identity names no row in the publication store.
    case cardUnavailable(PublicationCardID)
    /// The action is not durable: an authority write or a projection failed, and the session must keep
    /// the state it was showing instead of reporting success (plan §5.2 step 5).
    case notDurable(PublicationCardID, reason: String)

    var description: String {
        switch self {
        case .cardUnavailable(let cardID):
            return "card \(cardID) is not in the publication store; nothing durable can be keyed to it"
        case .notDurable(let cardID, let reason):
            return "the bookmark for card \(cardID) is not durable: \(reason)"
        }
    }
}

/// How a `v2Full` launch's feed is run: the acquisition owner, the session, and the snapshot stream.
///
/// The pieces are composed here rather than in `RuntimeCompositionRoot` because two of them need the
/// loader, which exists only after the screen attaches: the plan a surface composes under comes from the
/// app's own selectors (`SurfaceContextAdapters`), and the sources to acquire come from the catalogue the
/// loader holds. Everything that does *not* need the loader — the database, the transport, the
/// gate — is composed at launch, so a failure to open the runtime database is reported once and the
/// launch falls back to legacy instead of discovering it on first paint.
@MainActor
final class V2FullRuntime {
    let database: RuntimeDatabase
    let acquisition: V2Acquisition
    let repository: PublicationRepository
    let coordinator: PublicationCoordinator
    let media: V2MediaPipeline

    private let checkpoints: SessionCheckpointStore
    private let facts: ExposureFactStore
    private let editorialClock: any EditorialClock
    private let monotonicClock = SystemMonotonicClock()

    private var session: FeedSession?
    private var snapshotTask: Task<Void, Never>?
    private(set) var sessionStamp: SessionStamp
    private(set) var contextKey: ContextKey?
    private(set) var report = V2AcquisitionReport()
    private(set) var lastSummary: AcquisitionRunSummary?
    private(set) var startupReport: StartupReport?

    init(
        database: RuntimeDatabase,
        acquisition: V2Acquisition,
        transport: any HTTPTransport,
        assetRoot: URL,
        clock: any EditorialClock = SystemEditorialClock()
    ) {
        self.database = database
        self.acquisition = acquisition
        self.editorialClock = clock
        self.checkpoints = SessionCheckpointStore(database: database)
        self.facts = ExposureFactStore(database: database)
        let repository = PublicationRepository(database: database)
        self.repository = repository
        let media = V2MediaPipeline(
            database: database,
            transport: transport,
            rootDirectory: assetRoot,
            clock: clock
        )
        self.media = media
        self.coordinator = PublicationCoordinator(
            repository: repository,
            clock: clock,
            assets: media.assets
        )
        self.sessionStamp = SessionStamp(UInt64(Date().timeIntervalSince1970 * 1000))
    }

    /// Opens the session for one screen and hands every snapshot to `onSnapshot`, on the main actor.
    ///
    /// - Parameters:
    ///   - descriptors: the sources this launch will acquire from, already bounded by the caller. They
    ///     are watched before the session starts, because the first composition acquires.
    ///   - userActions: the app's durable user-state port. It is the caller's to compose because it needs
    ///     the legacy store — `user.sqlite` and the content database a bookmark has to be readable in —
    ///     which exists only once the loader does (`MainFeedRuntime.startSession`). The runtime does not
    ///     invent a subject of its own: a card id would be a bookmark legacy and a rebuild both lose.
    ///   - onWatched: the owner's watch report, stated the moment it exists. It is the loading surface's
    ///     own source (`MainFeedLoadingStatement`), and this is the only moment the report is written:
    ///     a reader that took it after `start` returned would read it after the first publication, when
    ///     the loading surface is already gone.
    func start(
        plan surface: FeedSurfaceContext,
        descriptors: [V2AcquisitionSourceDescriptor],
        renderEnvironment: RenderEnvironmentRevision,
        userActions: any FeedSessionUserActions,
        onWatched: @MainActor (V2AcquisitionReport) -> Void,
        onSnapshot: @escaping @MainActor (
            FeedPresentationSnapshot,
            [PublicationCardID: RenderImage]
        ) -> Void
    ) async {
        report = await acquisition.watch(descriptors)
        onWatched(report)
        contextKey = surface.contextKey

        let compositionPlan = FeedCompositionPlan(
            plan: surface.plan,
            // The plan declares no source selection: the enabled set is enforced by what this launch
            // acquires, not by the query. The projections' user-state half is empty because no
            // production read turns `user.sqlite` subjects into canonical stable keys yet — the gap is
            // named in the owner-swap report and belongs to the card-identity slice (rollout §7).
            projections: .empty,
            seed: Self.seed()
        )
        let contextKey = surface.contextKey
        let plans = FeedPlanSource { context in context == contextKey ? compositionPlan : nil }
        let composer = RuntimeFeedSessionComposer(
            database: database,
            repository: repository,
            plans: plans,
            coordinator: coordinator,
            acquisition: acquisition,
            media: media.preparer,
            // One line per composition, always. A publication path that logs nothing is a path nobody
            // can diagnose: a successor loop at seventeen editions a second produced a log with no
            // repeated line at all.
            observe: { event in
                Log.feed.info("runtime-v2 \(event.diagnostic)")
            }
        )
        // A session of its own needs a stamp of its own. `FeedScreenStore.apply` accepts a snapshot by
        // `sessionStamp` first and only breaks ties *inside* one stamp by sequence, and this runtime used
        // to mint its stamp once at construction and hand the same one to every session it started - so a
        // second session's first snapshot (sequence 1) was refused as older than the first session's
        // (sequence 4+). Measured 2026-09-18 (baseline §8.62): a bookmark box's session composed its four
        // cards, published them, and the screen kept the legacy page, because the store never took them.
        // Monotonic even inside one millisecond, which is all the opaque contract asks.
        sessionStamp = SessionStamp(max(
            UInt64(Date().timeIntervalSince1970 * 1000),
            sessionStamp.rawValue + 1
        ))
        let session = FeedSession(
            state: FeedSessionState(
                stamp: sessionStamp,
                context: surface.contextKey,
                historyScope: surface.plan.historyPolicy.scope,
                historyPolicy: surface.plan.historyPolicy,
                renderEnvironment: renderEnvironment
            ),
            repository: repository,
            checkpoints: checkpoints,
            facts: facts,
            composer: composer,
            userActions: userActions,
            clock: monotonicClock,
            editorialClock: editorialClock
        )
        self.session = session
        startConsuming(session, onSnapshot: onSnapshot)
        await session.start()
        startupReport = await session.currentStartupReport()
    }

    private func startConsuming(
        _ session: FeedSession,
        onSnapshot: @escaping @MainActor (
            FeedPresentationSnapshot,
            [PublicationCardID: RenderImage]
        ) -> Void
    ) {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor in
            for await snapshot in await session.snapshots() {
                guard !Task.isCancelled else { return }
                Log.feed.info(
                    "runtime-v2 v2Full snapshot edition=\(snapshot.editionID?.description ?? "none") cards=\(snapshot.cards.count) sequence=\(snapshot.sequence) context=\(snapshot.contextKey)"
                )
                let localMedia = await self.prewarmMedia(for: snapshot)
                guard !Task.isCancelled else { return }
                onSnapshot(snapshot, localMedia)
            }
        }
    }

    /// Resolves the snapshot's published visuals before SwiftUI sees the page.
    ///
    /// Freshly prepared assets normally hit the decoded cache. Warm restore may decode from the
    /// content-addressed store. Neither path can access the network: a missing/corrupt asset is omitted
    /// here and presentation draws the publication's deterministic placeholder.
    private func prewarmMedia(
        for snapshot: FeedPresentationSnapshot
    ) async -> [PublicationCardID: RenderImage] {
        let localIDs = snapshot.cards.compactMap { card -> PublicationCardID? in
            if case .local = card.media { return card.id }
            return nil
        }
        guard !localIDs.isEmpty else { return [:] }

        let repository = self.repository
        let media = self.media
        return await withTaskGroup(of: (PublicationCardID, RenderImage?).self) { group in
            for cardID in localIDs {
                group.addTask {
                    guard let record = try? repository.card(cardID) else {
                        return (cardID, nil)
                    }
                    return (cardID, await media.prewarm(card: record))
                }
            }
            var result: [PublicationCardID: RenderImage] = [:]
            result.reserveCapacity(localIDs.count)
            for await (cardID, image) in group {
                if let image { result[cardID] = image }
            }
            return result
        }
    }

    /// One refresh: the session composes a successor edition, which acquires again through the plan's
    /// own step (ADR-001 D9).
    func refresh() async {
        guard let session else { return }
        await session.send(.refresh)
        await session.drainPendingWork()
    }

    /// One durable bookmark intention on a runtime card, performed by the session (plan §5.2).
    ///
    /// This is the effect the screen's intent selects when this runtime owns the feed: the session reduces
    /// the intent and calls the port the app composed (`RuntimeCardUserActions`), so the bookmark lands in
    /// `user.sqlite` and in the legacy content row a relaunch hydrates. Without a session there is no
    /// reader to confirm against and nothing is written — the intent is refused by doing nothing, never by
    /// writing against a database no one is showing.
    func setBookmarked(cardID: PublicationCardID, wanted: Bool, operationID: String) async {
        guard let session else { return }
        await session.send(.toggleBookmark(cardID: cardID, wanted: wanted, operationID: operationID))
        await session.drainPendingWork()
    }

    /// One durable read intention on a runtime card, performed by the session (plan §5.2, ADR-007 D5/D7).
    ///
    /// This is the effect the screen's open selects when this runtime owns the feed: the session reduces
    /// the intent, calls the app's port (`RuntimeCardUserActions`), adopts the confirmation into the card
    /// it publishes and mirrors the `read` fact into the tracker. Without a session there is no reader
    /// whose state could be confirmed, so the intent is dropped rather than written against a database
    /// no one is showing.
    func markRead(cardID: PublicationCardID, operationID: String) async {
        guard let session else { return }
        await session.send(.opened(cardID: cardID, operationID: operationID))
        await session.drainPendingWork()
    }

    /// One exposure observation from the screen, reduced by the session (ADR-007 D2).
    ///
    /// The view states a bound and an edge and nothing else: the tracker owns coalescing, credited dwell
    /// and every fact that results, and hands the facts to the store in batches, so this path performs no
    /// arithmetic and no I/O. Without a session nothing is showing a card and there is nothing to record
    /// about one, so the observation is dropped by being sent to no one rather than written elsewhere.
    func trackExposure(_ observation: ViewportObservation) async {
        guard let session else { return }
        await session.send(.cardVisibility(observation))
    }

    func currentSnapshot() async -> FeedPresentationSnapshot? {
        await session?.currentSnapshot()
    }

    func currentStatistics() async -> FeedSessionStatistics? {
        await session?.currentStatistics()
    }

    func currentCounters() async -> V2AcquisitionCounters {
        await acquisition.currentCounters()
    }

    func frontierState() async -> String {
        await acquisition.frontierState()
    }

    /// Closes the session: intervals flush, tasks are cancelled and pins are released (plan §11).
    func teardown() async {
        snapshotTask?.cancel()
        snapshotTask = nil
        await session?.teardown()
        session = nil
    }

    /// Per-edition randomness for the plan's exploration weight. A collision-free value is what the
    /// field is for; it is never an identity (ADR-002 D3).
    static func seed() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }
}
