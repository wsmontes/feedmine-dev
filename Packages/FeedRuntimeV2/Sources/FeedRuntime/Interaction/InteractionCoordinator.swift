import Foundation
import FeedDomain

/// The Interaction boundary: a published action handle becomes an executed action here, and nowhere
/// else (ADR-001 D16, plan §19 #38, Technical Architecture I-05).
///
/// The renderer's whole role is to hand back the handle the publication froze. It does not decide
/// what a card does, it does not read the URL to guess the protocol, and it does not execute
/// anything itself: `actionExecutesWithoutProtocolBranchInView` pins that, and this type is the other
/// side of it. Everything protocol-specific — the reader, playback, the conversation, a connector's
/// own action — is resolved behind these ports.
///
/// ## The offer
///
/// Every executable action is addressed by an `ActionOffer`, built once from a published card. Its
/// `ActionID` is *derived*, not allocated and not random: the same card, edition, action kind and
/// reference always produce the same id, so a rerender, a re-publication of the same edition and a
/// relaunch all address the same action. An `ActionID` that changed per render could not be compared
/// with the capability that was granted when the card was presented, and the staleness check below
/// would have nothing to compare.
///
/// ## What rejects an action
///
/// Three checks, in this order, each with its own rejection:
///
/// 1. **Capability.** `ActionCapabilityProvider` states the capability the runtime grants *now* for
///    the offer's kind, including its generation. `nil` — the runtime grants none — is
///    `.capabilityNotGranted`. A *different generation* means the capability this offer was
///    published under no longer holds: a source was disabled, playback was revoked, the connector
///    was unbound. That is `.capabilityRevoked`, and it is the answer to "what rejects an action
///    whose capability no longer holds".
/// 2. **Resource.** `ActionResourceProbe` states whether what the action needs still exists — the
///    card is still in the edition, the published asset's bytes are still local, the conversation
///    still resolves, the location is still one the runtime will open. Missing is
///    `.resourceUnavailable`; the probe's own text says why, because "the asset was evicted" and
///    "the card was purged" need different product answers.
/// 3. **Execution.** `ActionExecuting` performs the effect. A failure it reports is
///    `.refusedByExecutor`, never a silent success.
public struct InteractionCoordinator: Sendable {
    private let capabilities: any ActionCapabilityProvider
    private let resources: any ActionResourceProbe
    private let executor: any ActionExecuting

    public init(
        capabilities: any ActionCapabilityProvider,
        resources: any ActionResourceProbe,
        executor: any ActionExecuting
    ) {
        self.capabilities = capabilities
        self.resources = resources
        self.executor = executor
    }

    /// Validates and performs one offer. Never throws: every failure is a stated rejection, because a
    /// card whose action silently does nothing is indistinguishable from a broken renderer.
    public func perform(_ offer: ActionOffer) async -> ActionOutcome {
        let kind = offer.capability.kind
        guard let current = capabilities.currentCapability(for: kind) else {
            return .rejected(.capabilityNotGranted(kind))
        }
        guard current.generation == offer.capability.generation else {
            return .rejected(.capabilityRevoked(
                kind: kind,
                presented: offer.capability.generation,
                current: current.generation
            ))
        }
        if let resource = offer.resource {
            if case let .unavailable(reason) = resources.availability(of: resource) {
                return .rejected(.resourceUnavailable(resource, reason: reason))
            }
        }
        do {
            return .executed(try await executor.execute(offer))
        } catch {
            return .rejected(.refusedByExecutor("\(error)"))
        }
    }
}

// MARK: - The offer

/// One executable action: the published handle plus the identity it was published under.
public struct ActionOffer: Hashable, Sendable {
    /// Stable id of this offer. Derived from the other fields; never allocated, never random.
    public let id: ActionID
    public let editionID: EditionID
    public let cardID: PublicationCardID
    public let action: FeedPrimaryAction
    /// The capability the card was presented under. The coordinator compares its generation with the
    /// one the provider reports now.
    public let capability: ActionCapability

    public init(
        editionID: EditionID,
        cardID: PublicationCardID,
        action: FeedPrimaryAction,
        capability: ActionCapability
    ) throws {
        guard capability.kind == action.capabilityKind else {
            throw InteractionError.capabilityKindMismatch(
                action: action.kind,
                capability: capability.kind
            )
        }
        self.id = try ActionOffer.deriveID(
            editionID: editionID,
            cardID: cardID,
            action: action,
            capability: capability
        )
        self.editionID = editionID
        self.cardID = cardID
        self.action = action
        self.capability = capability
    }

    /// Builds the offer for a published card, or `nil` when the card publishes no action — which is
    /// valid, and is not a URL synthesized to satisfy a view (ADR-001 D16).
    public static func of(
        card: PublishedCardPayload,
        cardID: PublicationCardID,
        capabilityGeneration: Int
    ) throws -> ActionOffer? {
        guard let action = card.frozen.primaryAction else { return nil }
        return try ActionOffer(
            editionID: card.frozen.editionID,
            cardID: cardID,
            action: action,
            capability: ActionCapability(
                kind: action.capabilityKind,
                generation: capabilityGeneration
            )
        )
    }

    /// `action:<hex>`, the lowercase hex SHA-256 of the offer's canonical text.
    ///
    /// The text names the parts in a fixed order, so two offers are the same action exactly when all
    /// four parts are the same. The reference is hashed rather than embedded: an id that contains the
    /// URL is an id a renderer could read a protocol out of, which is the branch this boundary exists
    /// to remove.
    static func deriveID(
        editionID: EditionID,
        cardID: PublicationCardID,
        action: FeedPrimaryAction,
        capability: ActionCapability
    ) throws -> ActionID {
        let material = [
            "edition:\(editionID.rawValue)",
            "card:\(cardID.rawValue)",
            "kind:\(action.kind.rawValue)",
            "capability:\(capability.kind.rawValue)@\(capability.generation)",
            "reference:\(action.reference)",
        ].joined(separator: "|")
        return try ActionID(EditorialSHA256.hex(of: Data(material.utf8)))
    }
}

// MARK: - Capability

/// The capability the runtime grants for one kind of action, and the generation it was granted under.
///
/// A generation is not a revision of the card: it changes when the *grant* changes — a capability
/// revoked and re-issued, a connector rebound — so an offer presented under generation N is stale
/// once the runtime reports N+1, and is rejected before anything is executed.
public struct ActionCapability: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// Open a published external location.
        case reader
        /// Show the card the edition itself holds.
        case localCardDetail
        /// Play bytes the publication already committed.
        case mediaPlayback
        /// Open a conversation the runtime knows.
        case thread
        /// Run an action a connector offered.
        case connectorAction
    }

    public let kind: Kind
    public let generation: Int

    public init(kind: Kind, generation: Int) {
        self.kind = kind
        self.generation = generation
    }
}

public protocol ActionCapabilityProvider: Sendable {
    /// The capability granted for `kind` right now. `nil` when the runtime grants none.
    func currentCapability(for kind: ActionCapability.Kind) -> ActionCapability?
}

extension FeedPrimaryAction {
    /// The capability one published action kind requires. The vocabulary is closed on both sides, so
    /// a new action kind cannot reach the boundary without stating the capability it needs.
    public var capabilityKind: ActionCapability.Kind {
        switch self {
        case .externalURL: return .reader
        case .localContentDetail: return .localCardDetail
        case .mediaPlayback: return .mediaPlayback
        case .thread: return .thread
        case .connectorAction: return .connectorAction
        }
    }
}

// MARK: - Resource

/// Durable or reconstructible state an action needs, named so a probe can answer for it.
public enum ActionResource: Hashable, Sendable {
    /// The card is still part of the edition this offer was published under.
    case publishedCard(EditionID, PublicationCardID)
    /// The published asset — named by its reference text, never by a URL — still has local bytes.
    case publishedMedia(String)
    /// The conversation handle still resolves.
    case conversation(InteractionHandle)
    /// The location is still one the runtime will open.
    case externalLocation(URL)
}

/// Whether a resource survives right now. `unavailable` carries the reason because "the asset was
/// evicted", "the card was purged" and "the source was disabled" are different product answers.
public enum ActionResourceAvailability: Hashable, Sendable {
    case available
    case unavailable(reason: String)
}

public protocol ActionResourceProbe: Sendable {
    func availability(of resource: ActionResource) -> ActionResourceAvailability
}

extension FeedPrimaryAction {
    /// What this action needs to still exist, or `nil` for an action that needs no local resource.
    public var localResource: ActionResource? {
        switch self {
        case .externalURL(let url): return .externalLocation(url)
        case .localContentDetail: return nil
        case .mediaPlayback(let assetReference): return .publishedMedia(assetReference)
        case .thread(let handle): return .conversation(handle)
        case .connectorAction: return nil
        }
    }
}

// MARK: - Execution

public struct ActionReceipt: Hashable, Sendable {
    public let id: ActionID
    /// What the executor reports it did. Free text: the runtime does not interpret an execution.
    public let detail: String

    public init(id: ActionID, detail: String) {
        self.id = id
        self.detail = detail
    }
}

public protocol ActionExecuting: Sendable {
    func execute(_ offer: ActionOffer) async throws -> ActionReceipt
}

public enum ActionOutcome: Hashable, Sendable {
    case executed(ActionReceipt)
    case rejected(ActionRejection)

    public var receipt: ActionReceipt? {
        if case .executed(let receipt) = self { return receipt }
        return nil
    }

    public var rejection: ActionRejection? {
        if case .rejected(let rejection) = self { return rejection }
        return nil
    }
}

public enum ActionRejection: Hashable, Sendable {
    case capabilityNotGranted(ActionCapability.Kind)
    case capabilityRevoked(kind: ActionCapability.Kind, presented: Int, current: Int)
    case resourceUnavailable(ActionResource, reason: String)
    case refusedByExecutor(String)
}

public enum InteractionError: Error, Equatable, Sendable {
    case capabilityKindMismatch(action: FeedPrimaryAction.Kind, capability: ActionCapability.Kind)
}

// MARK: - The resource for a card the edition itself holds

extension FeedPrimaryAction {
    /// The card-local resource for `.localContentDetail` needs the edition, which the action alone
    /// does not carry. The coordinator resolves it from the offer instead, so the case above returns
    /// `nil` and this function answers for both.
    static func localResource(
        of action: FeedPrimaryAction,
        editionID: EditionID,
        cardID: PublicationCardID
    ) -> ActionResource? {
        if case .localContentDetail(let target) = action, target == cardID {
            return .publishedCard(editionID, target)
        }
        return action.localResource
    }
}

extension ActionOffer {
    /// What this offer needs to still exist, including the card-local case the action alone cannot
    /// name.
    public var resource: ActionResource? {
        FeedPrimaryAction.localResource(
            of: action,
            editionID: editionID,
            cardID: cardID
        )
    }
}
