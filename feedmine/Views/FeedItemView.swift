import SwiftUI
import FeedDomain
import FeedRuntime

/// Wraps a single feed item with all its modifiers,
/// extracted from FeedScreen to reduce type-checking complexity.
///
/// What a tap does and what the media slot holds arrive as presentation (PR-13): `card.affordances.tap`
/// and `mediaSlot`. The item is text — title, source, category, date and the identity a link is copied
/// from — never a source of decisions.
struct FeedItemView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(MainFeedRuntime.self) private var runtime
    let item: FeedItem
    /// The V2 presentation of this card.
    var card: CardPresentation
    /// The media slot the band currently drawn reserves for it.
    var mediaSlot: CardMediaSlot = .none
    var onOpen: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onPlaybackFailed: (() -> Void)? = nil
    var onViewSource: (() -> Void)? = nil
    var onAddSourceToCollection: (() -> Void)? = nil
    /// The surface this card is rendered on, and the durable scope of that surface.
    ///
    /// The Main Feed is the default; the source and collection sheets state their own, so a card's
    /// published action carries the identity of the surface it was presented on (PR-14, item 4).
    var actionSurface: FeedSurface = .main
    var actionScopeKey: String = ""

    /// Whether the media slot itself plays audio on a tap, which is the one case where the slot is a
    /// control rather than decoration.
    private var mediaSlotPlaysAudio: Bool {
        card.affordances.tap == .openReaderOrPlayAudioFromMedia
    }

    var body: some View {
        Group {
            if loader.layout == .card {
                FeedItemCardView(
                    item: item,
                    isRead: card.isRead,
                    isBookmarked: card.isBookmarked,
                    mediaSlot: mediaSlot,
                    affordances: card.affordances,
                    onBookmark: { runtime.toggleBookmark(itemID: item.id) },
                    onViewSource: onViewSource,
                    onAddSourceToCollection: onAddSourceToCollection,
                    onCopy: onCopy,
                    onImageTap: mediaSlotPlaysAudio ? { Task { await performCardAction(presentedAction) } } : nil,
                    isInBookmarkBox: loader.selectedBookmarkListID != nil
                )
                .padding(.horizontal, 12)
            } else {
                // Row layout owns its context menu here. The card layout renders
                // FeedItemCardView's own menu instead — attaching both menus to
                // the same area makes the inner (card) one win and the outer one
                // unreachable, so the menu must not apply to the card branch.
                FeedItemRowView(
                    item: item,
                    isRead: card.isRead,
                    isBookmarked: card.isBookmarked,
                    mediaSlot: mediaSlot,
                    affordances: card.affordances,
                    onImageTap: mediaSlotPlaysAudio ? { Task { await performCardAction(presentedAction) } } : nil
                )
                .contextMenu { contextMenuContent }
                Divider()
            }
        }
        .onTapGesture {
            // Diagnostic for the release review's ignored-tap class: this line is what separates "the synthesized tap
            // never reached the app's gesture" from "the app got the tap and the reader did not open". The observation
            // that costs the least to answer — the 20 s miss of 2026-09-17 could not be attributed without it, because
            // the device log for that window had already rotated away.
            Log.ui.info("card tap id=\(item.id) lang=\(item.language ?? "und") action=\(String(describing: card.affordances.tap)) read=\(card.isRead)")
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            Task { await performCardAction(presentedAction) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed-item-\(item.language ?? "und")-\(item.id)")
        .accessibilityLabel("\(item.title) from \(item.sourceTitle)")
    }

    /// Row-layout context menu, functionally equivalent to the card's own menu.
    /// Cards use FeedItemCardView.cardContextMenu instead; an outer menu on the
    /// shared area would be shadowed by the inner one (see the row-branch note).
    @ViewBuilder
    private var contextMenuContent: some View {
        BookmarkBoxContextMenu(itemID: item.id)

        if let onViewSource {
            Button(action: onViewSource) {
                Label("View Source", systemImage: "rectangle.stack")
            }
        }

        if let onAddSourceToCollection {
            Button(action: onAddSourceToCollection) {
                Label("Add Source to Collection", systemImage: "rectangle.stack.badge.plus")
            }
        }

        Button {
            UIPasteboard.general.url = URL(string: item.url)
            onCopy?()
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }
        Button {
            if let image = renderCardAsImage(item: item) {
                let av = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = windowScene.windows.first?.rootViewController {
                    root.present(av, animated: true)
                }
            }
        } label: {
            Label("Share as Image", systemImage: "photo.artframe")
        }

        ShareLink(item: URL(string: item.url) ?? URL(string: "https://feedmine.app")!) {
            Label("Share Link", systemImage: "link")
        }
    }

    /// The card's published action, built once per render (ADR-001 D16: the handle is frozen at
    /// publication and the renderer holds it).
    ///
    /// Built here rather than at tap time on purpose: the capability the offer carries is the one the
    /// surface granted when this card was rendered, and the tap compares it with what the surface
    /// grants *then*. A card whose surface moved on in between is refused instead of executing against
    /// the surface the reader is now on.
    private var presentedAction: ActionOffer? {
        guard let edition = actionEdition else { return nil }
        return try? CardActionBridge.offer(
            item: item,
            card: card,
            editionID: edition,
            capabilityGeneration: Int(edition.rawValue)
        )
    }

    /// The identity of the surface this card is drawn on. The Main Feed's is the edition of the page
    /// it came from; a surface with no runtime publication is given one per (surface, scope).
    private var actionEdition: EditionID? {
        if actionSurface == .main, actionScopeKey.isEmpty {
            return runtime.presentation.currentEdition
        }
        return runtime.surfaceContexts.materializationEdition(
            surface: actionSurface,
            scopeKey: effectiveActionScopeKey
        )
    }

    private var effectiveActionScopeKey: String {
        actionScopeKey.isEmpty
            ? runtime.surfaceContexts.mainFeedInputs(loader: loader).scopeKey
            : actionScopeKey
    }

    /// Performs the card's published action through the Interaction boundary (plan §14 PR-14 item 4).
    ///
    /// This view decides nothing: the offer arrives from `presentedAction`, the coordinator validates
    /// the capability and the resource, and the two effects below are all this view owns. A refusal is
    /// logged — a tap that silently does nothing is indistinguishable from a broken renderer.
    private func performCardAction(_ offer: ActionOffer?) async {
        guard let offer else {
            Log.ui.info("card tap has no published action id=\(item.id) affordance=\(String(describing: card.affordances.tap))")
            return
        }
        let capabilities = CardActionCapabilities(generation: Int((actionEdition ?? offer.editionID).rawValue))
        let outcome = await CardActionBridge.perform(
            offer,
            capabilities: capabilities,
            resources: CardActionResources(hasPlaybackMaterial: item.audioPlaybackURL != nil),
            effect: { action in
                switch action {
                case .mediaPlayback:
                    playPodcastAudio()
                    return "audio"
                case .externalURL, .localContentDetail:
                    // `.openReaderOrPlayAudioFromMedia` plays audio from the media slot and opens the
                    // reader from the text area; the published action for that affordance is the
                    // playback when the card has an enclosure, and this branch otherwise.
                    runtime.opened(itemID: item.id)
                    onOpen?()
                    return "reader"
                case .thread, .connectorAction:
                    return "unhandled"
                }
            }
        )
        if let rejection = outcome.rejection {
            Log.ui.error("card action rejected id=\(item.id) reason=\(String(describing: rejection))")
            // A refused playback keeps the signal the legacy path gave the reader: the card said it
            // plays and there is nothing the player can take, so the honest outcome is the same toast
            // the failed `playPodcastAudio()` produced, not silence.
            if case .resourceUnavailable(.publishedMedia, _) = rejection, offer.action.kind == .mediaPlayback {
                onPlaybackFailed?()
            }
        }
    }

    private func playPodcastAudio() {
        if AudioPlayerManager.shared.play(item: item) {
            runtime.opened(itemID: item.id)
        } else {
            onPlaybackFailed?()
        }
    }
}
