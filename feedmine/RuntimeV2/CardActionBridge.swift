import Foundation
import FeedDomain
import FeedRuntime

/// The app's side of the Interaction boundary (plan §14 PR-14 item 4, ADR-001 D16).
///
/// A card's tap used to be decided and executed inside the view: the view read
/// `card.affordances.tap`, and the branch called the reader or the player directly. The affordance
/// decision already left the view in PR-13 (it arrives in the `CardPresentation`), but the *action*
/// still had no identity and no validation: a card presented before a filter change executed against
/// the surface the app had moved on to.
///
/// This bridge closes that: every tap becomes an `ActionOffer` with a stable `ActionID`, and the
/// coordinator validates the capability and the resource before anything happens. The view supplies
/// only two effects — open the reader, play the audio — and never looks at the URL to decide which
/// one applies.
enum CardActionBridge {

    /// The offer for one card, or `nil` when the card publishes no action at all.
    ///
    /// The mapping is from the *published* affordance, never from the item: an item whose legacy
    /// protocol flags contradict its presentation produces exactly the same offer as one whose flags
    /// agree, which is what `actionExecutesWithoutProtocolBranchInView` pins.
    static func offer(
        item: FeedItem,
        card: CardPresentation,
        editionID: EditionID,
        capabilityGeneration: Int
    ) throws -> ActionOffer? {
        guard let action = action(for: item, affordance: card.affordances.tap, cardID: card.id) else {
            return nil
        }
        return try ActionOffer(
            editionID: editionID,
            cardID: card.id,
            action: action,
            capability: ActionCapability(
                kind: action.capabilityKind,
                generation: capabilityGeneration
            )
        )
    }

    /// The published action one affordance means.
    ///
    /// `mediaPlayback` is named by the card's own identity, never by a URL: the executor resolves it
    /// from the item it already holds, so no location enters the frozen handle.
    private static func action(
        for item: FeedItem,
        affordance: CardPresentation.Affordances.Tap,
        cardID: PublicationCardID
    ) -> FeedPrimaryAction? {
        switch affordance {
        case .playAudio:
            return .mediaPlayback(item.id)
        case .openReaderOrPlayAudioFromMedia:
            // The media slot plays; the text area opens. Both are published: playback of the card's
            // own enclosure, and the card's own detail when there is no openable location.
            return hasPlayableEnclosure(item)
                ? .mediaPlayback(item.id)
                : openableLocation(item).map(FeedPrimaryAction.externalURL) ?? .localContentDetail(cardID)
        case .openReader:
            return openableLocation(item).map(FeedPrimaryAction.externalURL) ?? .localContentDetail(cardID)
        }
    }

    /// Whether the item has playback material at all. This is data, not protocol: an item with no
    /// enclosure and no direct audio link has nothing to play, whatever the source is.
    private static func hasPlayableEnclosure(_ item: FeedItem) -> Bool {
        item.audioPlaybackURL != nil
    }

    private static func openableLocation(_ item: FeedItem) -> URL? {
        guard let url = URL(string: item.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Validates the offer and, when it holds, performs it.
    ///
    /// The effect is the view's; the decision is not. A refusal is returned to the caller so the
    /// screen can log it — a tap that silently does nothing is indistinguishable from a broken
    /// renderer.
    @MainActor
    static func perform(
        _ offer: ActionOffer,
        capabilities: CardActionCapabilities,
        resources: CardActionResources,
        effect: @escaping @MainActor (FeedPrimaryAction) -> String
    ) async -> ActionOutcome {
        let coordinator = InteractionCoordinator(
            capabilities: capabilities,
            resources: resources,
            executor: CardActionExecutor(effect: effect)
        )
        return await coordinator.perform(offer)
    }
}

/// The capabilities this build of the app grants, and the generation they were granted under.
///
/// The generation is the *materialization* identity of the surface the card was presented on: a card
/// whose surface has moved on (a filter, a preset, a context switch) is stale, and its action is
/// refused with `.capabilityRevoked` instead of executing against the surface the user is now on.
///
/// What is not granted is stated rather than faked: the legacy path publishes no conversation handle
/// and no connector action, so both are `.capabilityNotGranted` — the coordinator's answer, not the
/// view's.
struct CardActionCapabilities: ActionCapabilityProvider {
    let generation: Int

    func currentCapability(for kind: ActionCapability.Kind) -> ActionCapability? {
        switch kind {
        case .reader, .localCardDetail, .mediaPlayback:
            return ActionCapability(kind: kind, generation: generation)
        case .thread, .connectorAction:
            return nil
        }
    }
}

/// What an action needs to still exist, answered from the state the renderer holds.
///
/// `mediaPlayback` is a capability, not an asset: the legacy pipeline owns no published asset
/// registry, so the honest statement is whether this card has an enclosure the player can take at
/// all. A published-asset probe replaces this when the runtime owns publication (PR-15).
struct CardActionResources: ActionResourceProbe {
    let hasPlaybackMaterial: Bool

    func availability(of resource: ActionResource) -> ActionResourceAvailability {
        switch resource {
        case .externalLocation(let url):
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return .unavailable(reason: "the published location is not an openable web address")
            }
            return .available
        case .publishedMedia:
            return hasPlaybackMaterial
                ? .available
                : .unavailable(reason: "the card has no enclosure the player can take")
        case .publishedCard:
            return .available
        case .conversation:
            return .unavailable(reason: "this build composes no conversation surface")
        }
    }
}

/// The executor port, backed by the view's effects.
///
/// `@MainActor` because the effects touch view state; the protocol requirement is `async`, so an
/// isolated witness is allowed and the coordinator awaits it like any other executor.
@MainActor
final class CardActionExecutor: ActionExecuting {
    private let effect: @MainActor (FeedPrimaryAction) -> String

    init(effect: @escaping @MainActor (FeedPrimaryAction) -> String) {
        self.effect = effect
    }

    func execute(_ offer: ActionOffer) async throws -> ActionReceipt {
        ActionReceipt(id: offer.id, detail: effect(offer.action))
    }
}
