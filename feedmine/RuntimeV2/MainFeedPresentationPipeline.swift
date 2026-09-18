import Foundation
import Observation
import UIKit
import FeedDomain
import FeedUIBridge

/// One row of the Main Feed as the renderer receives it.
///
/// The V2 card is the data contract: identity, ordinal, media decision, layout and chrome. `item` is
/// the explicit debt the plan names for PR-13 — the snapshot has no publication date, no source line
/// and no section yet, so the screen still reads those from the item. Moving them into the snapshot is
/// PR-14's job; until then the item is text and placement only, never a decision.
struct MainFeedRow: Identifiable {
    let card: CardPresentation
    let mediaSlot: CardMediaSlot
    let item: FeedItem

    var id: String { item.id }
}

struct MainFeedSection: Identifiable {
    let id: String
    let title: String
    let showsHeader: Bool
    let rows: [MainFeedRow]
}

/// The legacy page this pipeline is given to turn into a snapshot.
///
/// It is a value rather than a read of `FeedLoader` so the transformation can be exercised without
/// driving a publication: publishing a page writes the process-wide page cache
/// (`docs/runtime-v2/baseline.md` §8.3), and a test that only wants to state "this page" must not
/// leave one behind.
struct MainFeedPage {
    let sections: [FeedLoader.DateSection]
    let cards: [FeedCardPresentation]
    let band: FeedLoader.FeedLayout
    let contextKey: String

    /// The page as the loader is currently publishing it. Read on the main actor: the page is
    /// published there by `FeedDisplayState`.
    @MainActor
    init(loader: FeedLoader, contexts: SurfaceContextAdapters) {
        self.sections = loader.dateSections
        self.cards = loader.cards
        self.band = loader.layout
        self.contextKey = MainFeedPresentation.contextKey(for: loader, contexts: contexts)
    }

    init(
        sections: [FeedLoader.DateSection],
        cards: [FeedCardPresentation],
        band: FeedLoader.FeedLayout,
        contextKey: String
    ) {
        self.sections = sections
        self.cards = cards
        self.band = band
        self.contextKey = contextKey
    }
}

/// Which page the presentation is drawing, and where it came from.
///
/// The row contract is the same in every case; what changes is the source of truth the rows came from,
/// which is what the screen's phase, emptiness and empty-state variant must follow.
enum MainFeedPageSource: Equatable {
    /// Nothing has been materialized yet: the screen is at its first render, before its runtime attached.
    case none
    /// The rows were mapped from the legacy loader's published page for the selection the screen is on.
    case legacyPage
    /// The rows are the runtime session's own snapshot, for the surface its plan was built for.
    case sessionSnapshot

    var diagnostic: String {
        switch self {
        case .none: return "none"
        case .legacyPage: return "legacy-page"
        case .sessionSnapshot: return "session-snapshot"
        }
    }
}

/// Turns the legacy published page into the Main Feed's presentation (plan §14 PR-13).
///
/// The direction is the point of this slice: acquisition stays legacy, so the page that exists is the
/// legacy one, and this type states it in the presentation vocabulary the runtime will produce
/// natively once it owns publication (PR-14/PR-15). It is the only place the page becomes
/// presentation, so no view ever sees `FeedItem`'s protocol inference.
///
/// The mapping is the same in both modes; what the mode decides is whether a `FeedScreenStore` is in
/// the path. With one, every page is published as a `FeedPresentationSnapshot` — stamp, sequence,
/// context and rejection counting included — and the screen routes its observations through it. Without
/// one (legacy), the page is mapped for display and the legacy path stays the only owner, which is
/// what the mode table says legacy means.
@MainActor
@Observable
final class MainFeedPresentation {
    /// The V2 transport, non-nil exactly when this launch's mode puts V2 presentation in front of the
    /// user. The screen renders `sections` from here and sends its intents here.
    let store: FeedScreenStore?
    /// The last snapshot applied to the store. Nil in legacy mode, where no snapshot is published.
    private(set) var snapshot: FeedPresentationSnapshot?
    private(set) var sections: [MainFeedSection] = []
    /// Which source the rows on screen came from. The screen's phase, emptiness and empty-state variant
    /// follow this, not the mode string: a page can only state where it came from.
    private(set) var pageSource: MainFeedPageSource = .none
    /// The context key the session's plan was built for, when this launch has a session. Nil in every
    /// other launch, and then every selection's page is the legacy one.
    ///
    /// It exists because a launch's session owns **one selection**, not the whole screen: the context
    /// key is the preset and the bookmark box (`SurfaceContextAdapters.mainFeedInputs`), so a reader who
    /// taps a bookmark box, a Smart Feed or a collection moves to a selection the session's plan was not
    /// built for. Those surfaces keep drawing their own legacy page — which the store still holds, since
    /// `LegacyAcquisitionGate` refuses fetches and not local reads — and no surface ever draws another
    /// surface's content.
    private(set) var sessionContextKey: String?
    /// The context key of the last page the legacy loader published, which is the selection the screen
    /// is on as the loader states it.
    private(set) var selectionContextKey: String?

    private var sessionStamp: SessionStamp
    private var sequence: UInt64 = 0
    /// The edition of the composition currently published, allocated by the surface-context owner
    /// (`SurfaceContextAdapters`) and read from it here. Allocation is ephemeral while the runtime
    /// database is not composed — monotonic inside this launch — and the runtime owns a durable
    /// allocation once it owns publication (PR-15).
    private(set) var currentEdition: EditionID?
    /// The per-surface plans and materialization identities, owned by `MainFeedRuntime`.
    let contexts: SurfaceContextAdapters

    /// Item id → published ordinal. The viewport observation reports the ordinals of the cards the
    /// renderer can see, and replenishment is defined in the page's own index space.
    private(set) var ordinalByItemID: [String: Int] = [:]
    private(set) var ordinalCount: Int = 0
    /// The newest card for one item, so an intent can name the card it acts on.
    private(set) var cardByItemID: [String: CardPresentation] = [:]
    /// The reverse of `cardByItemID`: an intent that carries a card identity is resolved back to the
    /// legacy item the effect still needs.
    private(set) var itemIDByCardID: [PublicationCardID: String] = [:]
    /// The item at one published ordinal, for the center-crossing observation.
    private(set) var itemIDByOrdinal: [Int: String] = [:]
    /// The published ordinal of one card, for the direction of a center crossing.
    private(set) var ordinalByCardID: [PublicationCardID: Int] = [:]
    /// Rejected snapshots, as the store counted them. Zero in legacy mode, where nothing is published.
    var rejectedSnapshotCount: Int { store?.rejectedSnapshotCount ?? 0 }

    private weak var loader: FeedLoader?
    private var isAttached = false

    init(
        store: FeedScreenStore?,
        sessionStamp: SessionStamp = SessionStamp(UInt64(Date().timeIntervalSince1970 * 1000)),
        contexts: SurfaceContextAdapters = SurfaceContextAdapters()
    ) {
        self.store = store
        self.sessionStamp = sessionStamp
        self.contexts = contexts
    }

    // MARK: - Lifetime

    /// Starts following one loader's published page.
    ///
    /// The observation is `withObservationTracking` rather than a poll: the page is published on the
    /// main actor by `FeedDisplayState`, and a copy taken on a timer would be a second truth. The
    /// tracked read is re-armed after every change; the tracking callback fires on the write and the
    /// rebuild runs one main-actor turn later, so it reads what the write produced.
    ///
    /// The selectors that compose the context key are tracked with the page: a reader moving to another
    /// preset or bookmark box moves to another selection, and the page for it has to be followed (or
    /// declined) at that moment, not at the next page mutation.
    func attach(_ loader: FeedLoader) {
        self.loader = loader
        isAttached = true
        followLegacyPage(loader)
        armObservation()
    }

    func detach() {
        isAttached = false
        loader = nil
    }

    /// Declares the selection this launch's session owns.
    ///
    /// It is called before the legacy page is followed: the session's plan is built from the loader's
    /// selectors, so the key it owns is known before the catalogue arrives, and claiming it first is
    /// what keeps the cached legacy page from being drawn for a surface the session is about to own.
    /// The store is told the key it must expect, which is the statement `expectContext` used to make.
    func beginSession(contextKey: String, drawingLegacyUntilSnapshot: Bool = false) {
        store?.expect(contextKey: contextKey)
        sessionContextKey = contextKey
        selectionContextKey = contextKey
        drawsLegacyUntilSnapshot = drawingLegacyUntilSnapshot
        // A selection the runtime adopts gets a session of its own, and a session of its own gets a
        // stamp of its own: the store accepts a snapshot only when its stamp is newer than the last
        // one's, and the sequence only breaks ties *inside* one stamp. Without this, an adopted
        // selection's first snapshot (sequence 1) was refused as older than the selection the reader
        // left (sequence 4+), so the session composed its page and the screen never drew it — measured
        // 2026-09-18 (baseline §8.62): a bookmark box's session composed one card, the store rejected it,
        // and the box kept its legacy page. The stamp is opaque and monotonic here, which is all the
        // contract asks: the wall clock, or one past the current stamp when two sessions start inside
        // the same millisecond.
        sessionStamp = SessionStamp(max(
            UInt64(Date().timeIntervalSince1970 * 1000),
            sessionStamp.rawValue + 1
        ))
        snapshot = nil
        restoreSessionPage()
    }

    /// Whether a selection the session has claimed but not yet served keeps drawing its legacy page.
    ///
    /// At launch it does not: the session's own surface shows "not yet" rather than the cached legacy
    /// page it is about to replace, which is what claiming before the catalogue arrives is for. On a
    /// selection the *reader* moved to it does: that selection's legacy page is the screen the reader
    /// already had, and taking it away before the session can replace it shows them nothing. Measured
    /// on 2026-09-18 (baseline §8.62): a bookmark box opened while the session could not start (no
    /// catalogue within the session's own bound) drew zero cards, already blanked, and stayed blank.
    private var drawsLegacyUntilSnapshot = false

    private func armObservation() {
        guard let loader else { return }
        withObservationTracking {
            _ = loader.items
            _ = loader.cards
            _ = loader.dateSections
            _ = loader.feedDisplayPhase
            _ = loader.layout
            _ = loader.activePreset
            _ = loader.selectedBookmarkListID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isAttached, let loader = self.loader else { return }
                self.followLegacyPage(loader)
                self.armObservation()
            }
        }
    }

    /// The selection the screen has moved to, when it is not the one the session owns.
    ///
    /// The presentation is the only thing that sees the page's own key, so it reports the change and the
    /// runtime decides whether it can serve it — a selection whose cards are legacy rows keeps its own
    /// page, and only the runtime knows which those are (`MainFeedRuntime.adoptSelectionIfNeeded`).
    var onSelectionChanged: ((String) -> Void)?

    /// Follows the loader's page for the selection the screen is on.
    ///
    /// The selection is stated by the page itself — `MainFeedPage.contextKey` is the preset and the
    /// bookmark box — and it is what decides between the two sources: the session's snapshot for the
    /// surface its plan was built for, the legacy page for every other selection, in every mode. The
    /// legacy store still holds those other selections in a launch whose runtime owns acquisition,
    /// because the gate refuses fetches and not local reads.
    ///
    /// A selection the session does not own is reported before the legacy page is published, so the
    /// runtime can consider adopting it; the page the reader sees in the meantime is the legacy one,
    /// which is what every selection but the session's own draws.
    private func followLegacyPage(_ loader: FeedLoader) {
        let page = MainFeedPage(loader: loader, contexts: contexts)
        selectionContextKey = page.contextKey
        if let sessionContextKey, page.contextKey == sessionContextKey {
            // A session that has claimed this selection but has no page for it yet falls back to the
            // selection's own legacy page — the only case a claim does not blank the screen. Without
            // this, a box opened while the session cannot start (the catalogue gate) showed nothing at
            // all, because the legacy page for a claimed selection is never drawn by the branch above.
            if snapshot == nil, drawsLegacyUntilSnapshot {
                publish(page)
                return
            }
            restoreSessionPage()
            return
        }
        // The screen moved off the session's selection. Reporting it is not the same as drawing the
        // legacy page for it: this call happens first and does not block the fallback below, which is
        // what the reader sees while the session for the new selection is being built.
        onSelectionChanged?(page.contextKey)
        publish(page)
    }

    /// Draws the session's own page, for the selection the session's plan was built for.
    ///
    /// With no snapshot published yet the surface is empty rather than the previous selection's rows:
    /// what the screen draws is never another surface's page, and the empty surface is the session
    /// saying "not yet" (`MainFeedSessionSurface.preparing`).
    ///
    /// It draws nothing when the screen is already drawing the session's page, for the same reason
    /// `applySnapshot` refuses an unchanged statement: writing `sections` re-renders the screen, a
    /// re-render re-fires the scroll surface's visibility observation, and that observation drives the
    /// next composition. This is the path that runs on every legacy page mutation in the acquiring mode,
    /// so an unconditional rebuild here would be the successor-edition loop again.
    private func restoreSessionPage() {
        guard sessionContextKey != nil else { return }
        guard let snapshot else {
            if pageSource != .sessionSnapshot {
                apply(rows: [], sections: [], from: .sessionSnapshot)
            }
            return
        }
        guard pageSource != .sessionSnapshot else { return }
        materialize(snapshot)
    }

    // MARK: - Publication

    /// States one page in the V2 vocabulary and materializes it as the rows the screen draws.
    ///
    /// In a launch whose runtime owns acquisition this is reached only for a selection the session does
    /// not own (`followLegacyPage`), and the page is *not* published to the store: the store carries one
    /// session's stream whose sequence space this page does not share, and a page consumed there could
    /// refuse the session's next snapshot as older than the applied one.
    @discardableResult
    func publish(_ page: MainFeedPage) -> FeedPresentationSnapshot {
        let published = Dictionary(
            page.cards.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var cards: [CardPresentation] = []
        var sections: [MainFeedSection] = []
        var ordinal = 0

        for section in page.sections {
            var rows: [MainFeedRow] = []
            rows.reserveCapacity(section.items.count)
            for item in section.items {
                let value = MainFeedCardBridge.value(
                    item: item,
                    ordinal: ordinal,
                    presentation: published[item.id],
                    band: page.band
                )
                rows.append(MainFeedRow(card: value.card, mediaSlot: value.mediaSlot, item: item))
                cards.append(value.card)
                ordinal += 1
            }
            sections.append(MainFeedSection(
                id: section.id,
                title: section.title,
                showsHeader: section.showsHeader,
                rows: rows
            ))
        }

        let edition = contexts.materializationEdition(surface: .main, scopeKey: page.contextKey)
        currentEdition = edition
        apply(rows: sections.flatMap(\.rows), sections: sections, from: .legacyPage)

        sequence += 1
        let next = FeedPresentationSnapshot(
            sessionStamp: sessionStamp,
            sequence: sequence,
            contextKey: page.contextKey,
            editionID: edition,
            editorialRevision: nil,
            renderEnvironment: Self.renderEnvironment(),
            cards: cards
        )
        guard sessionContextKey == nil else { return next }
        store?.expect(contextKey: page.contextKey)
        if let store, store.apply(next) {
            snapshot = next
        }
        return next
    }

    // MARK: - Snapshot publication

    /// States one runtime snapshot as the page the screen draws.
    ///
    /// This is the other direction of the same boundary `publish(_ page:)` crosses: there the legacy
    /// page becomes a snapshot, here the runtime's snapshot becomes rows. Which of the two draws is
    /// decided per selection, not per mode: a snapshot is materialized as the rows only while the screen
    /// is on the surface the session's plan was built for, and is otherwise retained — the reader may be
    /// on a bookmark box or a Smart Feed whose own legacy page is on screen, and no surface draws
    /// another surface's page — until the reader comes back to it (`restoreSessionPage`).
    ///
    /// The `FeedItem` in each row is the text and placement the views still read (`rollout.md` §2.1:
    /// the snapshot carries no section yet, and the views take excerpt, date, source line and address
    /// from the item). It is built from the snapshot's own fields — never from `feedmine.sqlite`, which
    /// does not hold runtime-acquired content — and it is display-only: every intent a row can emit is
    /// routed through the store by card identity, never by this item's id.
    ///
    /// The rows are drawn as one headerless list because the snapshot carries no sectioning: the
    /// runtime states publication order, and inventing "Today"/"This Week" headers here would be a
    /// second grouping rule beside `FeedLoader`'s.
    @discardableResult
    func applySnapshot(_ snapshot: FeedPresentationSnapshot) -> FeedPresentationSnapshot? {
        store?.expect(contextKey: snapshot.contextKey)
        guard let store, store.apply(snapshot) else { return nil }
        // A snapshot that says exactly what the last one said materializes nothing *while it is already
        // the page*. This is not an optimization: writing `sections` re-renders the screen, a re-render
        // re-fires the scroll surface's visibility observation, and that observation drives the next
        // composition — the feedback that turned a legitimate refresh into a successor-edition loop.
        // When the cards and the edition are the same, the rows already say this, so nothing is written
        // and the lap ends here. A bookmark, a read state or a new edition all change `cards` and pass
        // through. A page that is *not* the session's has to be rebuilt even from an unchanged snapshot:
        // those rows belong to another selection.
        let alreadySaysThis = pageSource == .sessionSnapshot
            && self.snapshot?.cards == snapshot.cards
            && self.snapshot?.editionID == snapshot.editionID
        self.snapshot = snapshot
        currentEdition = snapshot.editionID
        guard selectionContextKey == snapshot.contextKey else { return snapshot }
        if alreadySaysThis {
            return snapshot
        }
        materialize(snapshot)
        return snapshot
    }

    /// Draws one statement of the session's page: the rows, and the ordinal maps the intents resolve
    /// through.
    private func materialize(_ snapshot: FeedPresentationSnapshot) {
        var rows: [MainFeedRow] = []
        rows.reserveCapacity(snapshot.cards.count)
        for card in snapshot.cards {
            rows.append(MainFeedRow(
                card: card,
                mediaSlot: Self.mediaSlot(for: card),
                item: Self.displayItem(for: card)
            ))
        }
        let sections = rows.isEmpty
            ? []
            : [MainFeedSection(id: "runtime-snapshot", title: "", showsHeader: false, rows: rows)]
        apply(rows: rows, sections: sections, from: .sessionSnapshot)
    }

    /// Writes one page as the rows the screen draws, and re-derives every lookup the intents use.
    ///
    /// Both sources state a page the same way: rows in publication order, each carrying the card it
    /// draws and the item the views read. Everything else — the ordinals, the card lookup, the reverse
    /// aliases — is a function of those rows, so it is derived here rather than built twice.
    private func apply(rows: [MainFeedRow], sections: [MainFeedSection], from source: MainFeedPageSource) {
        var ordinals: [String: Int] = [:]
        var byItemID: [String: CardPresentation] = [:]
        var byCardID: [PublicationCardID: String] = [:]
        var byOrdinal: [Int: String] = [:]
        var ordinalByCard: [PublicationCardID: Int] = [:]
        ordinals.reserveCapacity(rows.count)
        byItemID.reserveCapacity(rows.count)
        byCardID.reserveCapacity(rows.count)
        byOrdinal.reserveCapacity(rows.count)
        ordinalByCard.reserveCapacity(rows.count)
        for row in rows {
            ordinals[row.item.id] = row.card.absoluteOrdinal
            byItemID[row.item.id] = row.card
            byCardID[row.card.id] = row.item.id
            byOrdinal[row.card.absoluteOrdinal] = row.item.id
            ordinalByCard[row.card.id] = row.card.absoluteOrdinal
        }

        self.sections = sections
        ordinalByItemID = ordinals
        ordinalCount = rows.count
        cardByItemID = byItemID
        itemIDByCardID = byCardID
        itemIDByOrdinal = byOrdinal
        ordinalByCardID = ordinalByCard
        if pageSource != source {
            pageSource = source
            // The mode line is logged once, at launch, when nothing has been attached yet. This is the
            // line that says which page the screen ended up drawing from, and it is emitted when that
            // changes rather than on every page mutation.
            let selection = selectionContextKey ?? "none"
            Log.feed.info("runtime-v2 page-source=\(source.diagnostic) selection=\(selection)")
        }
    }

    /// The text one runtime card draws, in the shape the views already read.
    ///
    /// Everything here comes from the card: the title, the excerpt, the declared date, the source's
    /// display name and the address the card opens. What a legacy item carries and a runtime card does
    /// not — an audio stream URL, an image URL — stays absent rather than being synthesized, and the
    /// card's own affordances decide what the renderer does without them (a placeholder slot and a
    /// neutral chrome).
    static func displayItem(for card: CardPresentation) -> FeedItem {
        FeedItem(
            id: "card:\(card.id)",
            sourceTitle: card.sourceTitle ?? "",
            sourceURL: "",
            category: "",
            title: card.title,
            excerpt: FeedTextSanitizer.displayExcerpt(card.subtitle ?? ""),
            url: card.link?.absoluteString ?? "",
            imageURL: nil,
            publishedAt: card.publishedAt ?? Date(timeIntervalSince1970: 0),
            isRead: card.isRead,
            isBookmarked: card.isBookmarked
        )
    }

    /// The media slot a snapshot card draws.
    ///
    /// The runtime's decision is final here: a placeholder slot draws the placeholder kind the card's
    /// affordances name, and a card with no slot collapses to text. `.local(assetDigest:)` means the
    /// bytes are published and pinned — resolving a digest to an image is the media slice's job
    /// (plan §10) and is not wired in this build, so the frame is reserved and left empty rather than
    /// filled with a stand-in.
    static func mediaSlot(for card: CardPresentation) -> CardMediaSlot {
        switch card.media {
        case .none:
            return .none
        case .placeholder:
            return .placeholder(MainFeedCardBridge.placeholderKind(card.affordances.placeholder))
        case .local:
            return .empty
        }
    }

    /// Sends one intent on the V2 path, if this mode has one. Returns `false` in legacy mode, where
    /// the caller performs the legacy action itself.
    @discardableResult
    func send(_ intent: FeedSessionIntent) -> Bool {
        guard let store else { return false }
        store.send(intent)
        return true
    }

    /// Reports the viewport through the store's cheap observation channel.
    @discardableResult
    func sendViewport(
        firstVisibleOrdinal: Int,
        lastVisibleOrdinal: Int,
        anchor: FeedWindowAnchor?
    ) -> Bool {
        guard let store else { return false }
        store.sendViewport(
            firstVisibleOrdinal: firstVisibleOrdinal,
            lastVisibleOrdinal: lastVisibleOrdinal,
            anchor: anchor
        )
        return true
    }

    /// The composition key of the screen: what has to change before the visible edition is a new one.
    /// It is the preset and the bookmark box — the two selectors the feed switches on — and nothing
    /// about how the current page happens to be materialized.
    ///
    /// Since PR-14 this is the surface-context adapter's `ContextKey` for the Main Feed, serialized:
    /// the screen and the runtime's plans used to carry two identities for the same thing.
    static func contextKey(for loader: FeedLoader, contexts: SurfaceContextAdapters) -> String {
        contexts.mainFeed(loader: loader).contextKeyText
    }

    // MARK: - Viewport

    /// One viewport observation, in the vocabulary the session reduces.
    func viewportAnchor(firstVisibleItemID: String?) -> FeedWindowAnchor? {
        guard let firstVisibleItemID,
              let ordinal = ordinalByItemID[firstVisibleItemID],
              let card = cardByItemID[firstVisibleItemID],
              let edition = currentEdition
        else { return nil }
        return FeedWindowAnchor.top(of: card.id, ordinal: ordinal, editionID: edition)
    }

    /// The render environment of this process, read once per publication.
    ///
    /// A revision that cannot be read is stated as unspecified instead of being invented: the value is
    /// identity for re-materialization (ADR-002 D7), so a wrong one is worse than an absent one.
    static func renderEnvironment() -> RenderEnvironmentRevision {
        let traits = UITraitCollection.current
        let widthClass = traits.horizontalSizeClass == .regular ? "regular" : "compact"
        let direction = traits.layoutDirection == .rightToLeft ? "rtl" : "ltr"
        let scale = traits.displayScale > 0 ? Int(traits.displayScale) : 0
        return (try? RenderEnvironmentRevision(
            layoutWidthClass: widthClass,
            dynamicTypeSize: traits.preferredContentSizeCategory.rawValue,
            localeIdentifier: Locale.current.identifier,
            textDirection: direction,
            displayScale: scale
        )) ?? .unspecified
    }
}
