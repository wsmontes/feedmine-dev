import Foundation
import FeedDomain
import FeedStorage

/// The pure session reducer of plan §11.
///
/// `reduce(state:event:) -> (state, effects)` has no I/O, no task, no clock and no database: it decides
/// what the session *is* and what the session *must do next*, and every effect carries the operation
/// that owns it plus the session stamp it belongs to, so a result from another context, epoch or
/// session is discarded instead of applied (ADR-002 D12, ADR-007 D11).
///
/// The state machine answers four questions the rest of the runtime depends on:
///
/// * which composition is still allowed to produce a result (`pending`/`applied`, with `staleResultCount`
///   recording every discard);
/// * what the bounded window holds right now (`FeedWindow`: ≤72 light references, byte-bounded decode);
/// * what the screen sees (a monotonic `FeedPresentationSnapshot` whose `sequence` never goes back);
/// * what is *not* allowed to invalidate any of it — a passive catalog change, a render environment
///   change or a rerender never swaps the visible edition (ADR-002 D7/D9).

/// Identity of one effect. Deterministic: the session stamp plus a monotone ordinal, both allocated by
/// the reducer, so the same event sequence in a test produces the same operation ids.
public struct FeedSessionOperationID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let sessionStamp: SessionStamp
    public let ordinal: UInt64

    public init(sessionStamp: SessionStamp, ordinal: UInt64) {
        self.sessionStamp = sessionStamp
        self.ordinal = ordinal
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sessionStamp != rhs.sessionStamp { return lhs.sessionStamp < rhs.sessionStamp }
        return lhs.ordinal < rhs.ordinal
    }

    public var description: String { "op:\(sessionStamp.rawValue)#\(ordinal)" }
}

public enum FeedSessionAvailability: String, Hashable, Sendable {
    /// Reading the checkpoint and paging the edition locally. No network is involved.
    case restoring
    /// A composition is running. The previous edition stays visible while it does (ADR-002 D9).
    case composing
    /// The window is materialized and the screen has content.
    case presenting
    /// The last attempt failed; the previous edition is kept and the state is recoverable.
    case degraded
    case closed
}

public enum FeedSessionLifecycle: String, Hashable, Sendable {
    case active
    case background
    case closed
}

public enum FeedSessionCompositionReason: String, Hashable, Sendable {
    case cold
    case contextSwitch
    case refresh
    case replenishment
}

/// Why the local restore could not answer, and therefore why a composition is needed at all.
public enum FeedSessionRestoreRefusal: Hashable, Sendable {
    case noCheckpoint
    case noEdition
    case incompatiblePublicationSchema(Int)
    case payloadCorrupted(cardID: PublicationCardID, reason: String)
    case unreadable(String)
}

/// The light facts of one published card, kept only while the window holds its reference.
///
/// The two cost estimates exist to bound memory, not to predict pixels: the byte estimate feeds the
/// window's decoded budget and the height feeds anchor compensation. Both are replaced by measurement
/// in the media work of PR-08, which is exactly why they live beside the card instead of inside it.
public struct FeedCardMaterial: Hashable, Sendable {
    public let editionID: EditionID
    public let cardID: PublicationCardID
    public let absoluteOrdinal: Int
    public let title: String
    public let subtitle: String?
    public let layout: CardPresentation.Layout
    public let mediaDigest: String?
    public let placeholderReason: String?
    /// The instant the revision declared, when it declared one; the observation time is never
    /// substituted for it (ADR-001 D4).
    public let publishedAt: Date?
    /// The frozen source display name, for the line under the title.
    public let sourceTitle: String?
    /// The address the revision's primary action names, when that action is an external URL.
    public let link: URL?
    public let estimatedHeight: Double
    public let decodedByteEstimate: Int

    /// Materializes one frozen record. Everything here is copied from the payload: no join, no
    /// canonical read and no network is possible (`PublicationCardPayload` is self-sufficient).
    public init(record: PublishedCardRecord, edition: EditionID) {
        let payload = record.payload
        let media = payload.media
        let digest: String?
        if let primary = media.primary {
            digest = primary.contentDigest
        } else if let reference = media.references.first {
            digest = reference.media.contentDigest
        } else {
            digest = nil
        }
        let textBytes = [payload.title, payload.primaryText]
            .compactMap { $0?.utf8.count }
            .reduce(0, +)
        let mediaBytes: Int
        switch payload.renderContract.kind {
        case .hero: mediaBytes = 512 * 1024
        case .thumb: mediaBytes = 128 * 1024
        case .textOnly: mediaBytes = 0
        }
        self.editionID = edition
        self.cardID = payload.cardID
        self.absoluteOrdinal = payload.absoluteOrdinal
        self.title = payload.title ?? ""
        self.subtitle = payload.primaryText
        self.layout = CardPresentation.Layout(payload.renderContract.kind)
        self.mediaDigest = digest
        self.placeholderReason = digest == nil ? "no declared media" : "bytes not materialized"
        self.publishedAt = payload.publishedAt
        self.sourceTitle = payload.origin.sourceDisplayName
        if case .externalURL(let url) = payload.primaryAction {
            self.link = url
        } else {
            self.link = nil
        }
        self.estimatedHeight = Self.estimatedHeight(for: payload.renderContract.kind)
        self.decodedByteEstimate = mediaBytes + textBytes
    }

    private static func estimatedHeight(for kind: RenderKind) -> Double {
        switch kind {
        case .hero: return 240
        case .thumb: return 120
        case .textOnly: return 88
        }
    }

    public var reference: FeedWindowReference {
        FeedWindowReference(
            cardID: cardID,
            absoluteOrdinal: absoluteOrdinal,
            editionID: editionID,
            estimatedHeight: estimatedHeight,
            decodedByteEstimate: decodedByteEstimate
        )
    }
}

/// Everything the session knows. Deliberately a value: the reducer returns a new one, and nothing here
/// holds a task, a closure or a database handle.
public struct FeedSessionState: Sendable, Equatable {
    public var stamp: SessionStamp
    public var sequence: UInt64
    public var nextOperationOrdinal: UInt64
    public var lifecycle: FeedSessionLifecycle
    public var context: ContextKey
    public var historyScope: HistoryScope
    public var historyPolicy: HistoryPolicy
    public var renderEnvironment: RenderEnvironmentRevision
    public var editorialRevision: EditorialRevision?
    public var visibleEdition: EditionID?
    public var availability: FeedSessionAvailability
    public var window: FeedWindow
    public var materials: [PublicationCardID: FeedCardMaterial]
    public var bookmarked: Set<PublicationCardID>
    public var read: Set<PublicationCardID>
    public var pending: [ContextKey: FeedSessionOperationID]
    /// The page request in flight per context. Deliberately separate from `pending`: a replenishment
    /// must never supersede the composition that is still allowed to paint (ADR-006 D14 single-flight).
    public var pendingPage: [ContextKey: FeedSessionOperationID]
    public var applied: [ContextKey: FeedSessionOperationID]
    /// The tail ordinal whose next page was already requested, per context. One request per page.
    public var replenishment: [ContextKey: Int]
    public var staleResultCount: Int
    public var passiveChangeCount: Int
    public var closedConsumer: Bool
    /// How close to the materialized tail a viewport must be before a page is requested.
    public let replenishmentDistance: Int

    public init(
        stamp: SessionStamp,
        context: ContextKey,
        historyScope: HistoryScope,
        historyPolicy: HistoryPolicy,
        renderEnvironment: RenderEnvironmentRevision,
        windowConfiguration: FeedWindowConfiguration = .baseline,
        replenishmentDistance: Int = 8
    ) {
        self.stamp = stamp
        self.sequence = 0
        self.nextOperationOrdinal = 0
        self.lifecycle = .active
        self.context = context
        self.historyScope = historyScope
        self.historyPolicy = historyPolicy
        self.renderEnvironment = renderEnvironment
        self.editorialRevision = nil
        self.visibleEdition = nil
        self.availability = .restoring
        self.window = FeedWindow(configuration: windowConfiguration)
        self.materials = [:]
        self.bookmarked = []
        self.read = []
        self.pending = [:]
        self.pendingPage = [:]
        self.applied = [:]
        self.replenishment = [:]
        self.staleResultCount = 0
        self.passiveChangeCount = 0
        self.closedConsumer = false
        self.replenishmentDistance = max(0, replenishmentDistance)
    }

    /// Cards currently materialized: bounded by the window's reference limit.
    public var materialCount: Int { materials.count }

    public var materialBytes: Int { materials.values.reduce(0) { $0 + $1.decodedByteEstimate } }
}

public enum FeedSessionEvent: Sendable, Equatable {
    case opened
    case restored(
        operation: FeedSessionOperationID,
        context: ContextKey,
        edition: EditionSnapshot,
        cards: [PublishedCardRecord],
        checkpoint: FeedWindowAnchor?
    )
    case restoreUnavailable(
        operation: FeedSessionOperationID,
        context: ContextKey,
        reason: FeedSessionRestoreRefusal
    )
    case composed(
        operation: FeedSessionOperationID,
        context: ContextKey,
        edition: EditionSnapshot,
        cards: [PublishedCardRecord]
    )
    /// A later page of the same edition, read locally by ordinal (plan §11).
    case pageLoaded(
        operation: FeedSessionOperationID,
        context: ContextKey,
        edition: EditionID,
        cards: [PublishedCardRecord],
        fromOrdinal: Int
    )
    case compositionFailed(
        operation: FeedSessionOperationID,
        context: ContextKey,
        reason: String
    )
    case intent(FeedSessionIntent)
    /// A Dynamic Type, rotation or locale change: materialization only (ADR-002 D7).
    case renderEnvironmentChanged(RenderEnvironmentRevision)
    case userStateChanged(
        cardID: PublicationCardID,
        bookmarked: Bool,
        read: Bool,
        operationID: String
    )
    /// A passive catalog/binding/endpoint change: it never swaps the visible edition (ADR-002 D9).
    case passiveCatalogChange
    case lifecycle(FeedSessionLifecycle)
    case consumerClosed
}

public struct FeedSessionEffect: Hashable, Sendable {
    public let operation: FeedSessionOperationID
    public let sessionStamp: SessionStamp
    public let kind: Kind

    public enum Kind: Hashable, Sendable {
        /// Read the local checkpoint and the stored edition. No composition, no network.
        case restore(context: ContextKey)
        case compose(context: ContextKey, reason: FeedSessionCompositionReason, fromOrdinal: Int?)
        case emitSnapshot(FeedPresentationSnapshot)
        case persistCheckpoint(SessionCheckpoint)
        case closeExposureIntervals(edition: EditionID?, reason: ExposureCloseReason)
        case trackViewport(ViewportObservation)
        case trackCenterCrossed(cardID: PublicationCardID, direction: Int)
        case trackOpened(cardID: PublicationCardID)
        /// Presentation objects were evicted: an open interval closes as `windowEvicted` (ADR-007 D4).
        case trackEvictions([PublicationCardID])
        case recordBookmark(operationID: String, cardID: PublicationCardID, wanted: Bool)
        /// One durable read intention, owned by the user-state port and mirrored as a `read` fact
        /// (ADR-007 D5/D7). It carries the operation id the port confirms with.
        case recordRead(operationID: String, cardID: PublicationCardID)
        case replenish(context: ContextKey, fromOrdinal: Int)
        case releasePins(editions: [EditionID])
    }

    /// Whether this effect still belongs to the session that produced it.
    public func isStale(against stamp: SessionStamp) -> Bool {
        sessionStamp != stamp
    }
}

public enum FeedSessionReducer {
    /// The only entry point: state in, state plus the work to do next, no side effects.
    public static func reduce(
        state: FeedSessionState,
        event: FeedSessionEvent
    ) -> (state: FeedSessionState, effects: [FeedSessionEffect]) {
        guard !state.closedConsumer else { return (state, []) }

        var state = state
        var effects: [FeedSessionEffect] = []

        switch event {
        case .opened:
            state.availability = .restoring
            let operation = allocate(&state)
            state.pending[state.context] = operation
            effects.append(makeEffect(.restore(context: state.context), operation: operation, state: state))

        case let .restored(operation, context, edition, cards, checkpoint):
            guard isCurrent(operation, for: context, in: state) else {
                state.staleResultCount += 1
                return (state, [])
            }
            state.pending[context] = nil
            state.applied[context] = operation
            let previousEdition = state.visibleEdition
            state.editorialRevision = edition.editorialRevision
            state.visibleEdition = edition.editionID
            state.availability = .presenting
            materialize(
                &state,
                cards: cards,
                edition: edition.editionID,
                viewportOrdinal: checkpoint?.absoluteOrdinal ?? cards.first?.payload.absoluteOrdinal ?? 0,
                anchor: checkpoint
            )
            // A stored edition with no cards is not a page, so restoring it is not "something compatible
            // to show": `FeedSession.start` composes only when there is nothing to show, and a successor
            // composition that kept no card (a repetition exclusion whose selection is the reader's own
            // saved set, measured on a bookmark box 2026-09-18, baseline §8.62) leaves exactly this - an
            // edition that restores to nothing and short-circuits every later composition. The composition
            // is asked for the same way an unavailable restore asks for it.
            if cards.isEmpty {
                state.availability = .composing
                let composeOperation = allocate(&state)
                state.pending[context] = composeOperation
                effects.append(makeEffect(
                    .compose(context: context, reason: .cold, fromOrdinal: nil),
                    operation: composeOperation,
                    state: state
                ))
            }
            if let previousEdition, previousEdition != edition.editionID {
                effects.append(makeEffect(
                    .closeExposureIntervals(edition: previousEdition, reason: .editionSwap),
                    operation: operation,
                    state: state
                ))
            }
            effects.append(contentsOf: snapshotEffects(&state, operation: operation))

        case let .restoreUnavailable(operation, context, reason):
            guard isCurrent(operation, for: context, in: state) else {
                state.staleResultCount += 1
                return (state, [])
            }
            state.pending[context] = nil
            state.availability = .composing
            let composeOperation = allocate(&state)
            state.pending[context] = composeOperation
            let compositionReason: FeedSessionCompositionReason
            if case .incompatiblePublicationSchema = reason {
                compositionReason = .cold
            } else {
                compositionReason = state.applied[context] == nil ? .cold : .refresh
            }
            effects.append(makeEffect(
                .compose(context: context, reason: compositionReason, fromOrdinal: nil),
                operation: composeOperation,
                state: state
            ))

        case let .composed(operation, context, edition, cards):
            guard isCurrent(operation, for: context, in: state) else {
                state.staleResultCount += 1
                return (state, [])
            }
            state.pending[context] = nil
            state.applied[context] = operation
            let previousEdition = state.visibleEdition
            state.editorialRevision = edition.editorialRevision
            state.visibleEdition = edition.editionID
            state.availability = .presenting
            let firstOrdinal = cards.first?.payload.absoluteOrdinal ?? 0
            materialize(&state, cards: cards, edition: edition.editionID, viewportOrdinal: firstOrdinal, anchor: nil)
            if let previousEdition, previousEdition != edition.editionID {
                effects.append(makeEffect(
                    .closeExposureIntervals(edition: previousEdition, reason: .editionSwap),
                    operation: operation,
                    state: state
                ))
            }
            if let checkpoint = checkpointForFirstCard(of: state) {
                effects.append(makeEffect(.persistCheckpoint(checkpoint), operation: operation, state: state))
            }
            effects.append(contentsOf: snapshotEffects(&state, operation: operation))

        case let .pageLoaded(operation, context, edition, cards, fromOrdinal):
            guard operation.sessionStamp == state.stamp,
                  context == state.context,
                  state.pendingPage[context] == operation,
                  state.visibleEdition == edition,
                  let viewport = state.window.viewport
            else {
                state.staleResultCount += 1
                return (state, [])
            }
            state.pendingPage[context] = nil
            state.replenishment[context] = nil
            let materials = cards.map { FeedCardMaterial(record: $0, edition: edition) }
            let adjustment = state.window.shift(to: viewport, inserting: materials.map(\.reference))
            retain(&state, materials: materials)
            if !adjustment.evictedCardIDs.isEmpty {
                effects.append(makeEffect(
                    .trackEvictions(adjustment.evictedCardIDs),
                    operation: allocate(&state),
                    state: state
                ))
            }
            if adjustment.materializationChanged {
                effects.append(contentsOf: snapshotEffects(&state, operation: operation))
            }

        case let .compositionFailed(operation, context, reason):
            guard isCurrent(operation, for: context, in: state) else {
                state.staleResultCount += 1
                return (state, [])
            }
            state.pending[context] = nil
            // A failed refresh keeps the previous edition: the screen never goes blank by construction
            // (ADR-002 D9).
            state.availability = state.visibleEdition == nil ? .degraded : .presenting
            _ = reason

        case let .intent(intent):
            reduce(intent: intent, state: &state, effects: &effects)

        case let .userStateChanged(cardID, bookmarked, read, _):
            if bookmarked {
                state.bookmarked.insert(cardID)
            } else {
                state.bookmarked.remove(cardID)
            }
            if read {
                state.read.insert(cardID)
            } else {
                state.read.remove(cardID)
            }
            if state.window.contains(cardID: cardID) {
                effects.append(contentsOf: snapshotEffects(&state, operation: allocate(&state)))
            }

        case let .renderEnvironmentChanged(environment):
            // Materialization only (ADR-002 D7): the same edition and the same cards, a new snapshot.
            // No composition, no editorial revision change and no exposure fact.
            state.renderEnvironment = environment
            effects.append(contentsOf: snapshotEffects(&state, operation: allocate(&state)))

        case .passiveCatalogChange:
            // Counted, and deliberately nothing else: no swap, no snapshot, no composition.
            state.passiveChangeCount += 1

        case let .lifecycle(lifecycle):
            state.lifecycle = lifecycle
            switch lifecycle {
            case .background:
                effects.append(makeEffect(
                    .closeExposureIntervals(edition: state.visibleEdition, reason: .background),
                    operation: allocate(&state),
                    state: state
                ))
            case .active, .closed:
                break
            }

        case .consumerClosed:
            state.closedConsumer = true
            state.lifecycle = .closed
            state.availability = .closed
            let edition = state.visibleEdition
            state.window.releaseMaterializedContent()
            state.materials.removeAll()
            state.pending.removeAll()
            state.pendingPage.removeAll()
            state.replenishment.removeAll()
            effects.append(makeEffect(
                .closeExposureIntervals(edition: edition, reason: .sessionEnd),
                operation: allocate(&state),
                state: state
            ))
            effects.append(makeEffect(
                .releasePins(editions: edition.map { [$0] } ?? []),
                operation: FeedSessionOperationID(sessionStamp: state.stamp, ordinal: state.nextOperationOrdinal),
                state: state
            ))
        }

        return (state, effects)
    }

    // MARK: - Intents

    private static func reduce(
        intent: FeedSessionIntent,
        state: inout FeedSessionState,
        effects: inout [FeedSessionEffect]
    ) {
        switch intent {
        case let .viewportChanged(firstVisibleOrdinal, lastVisibleOrdinal, anchor):
            if let anchor { state.window.setAnchor(anchor) }
            let adjustment = state.window.shift(to: FeedWindow.Viewport(
                firstVisibleOrdinal: firstVisibleOrdinal,
                lastVisibleOrdinal: lastVisibleOrdinal
            ))
            if !adjustment.evictedCardIDs.isEmpty {
                effects.append(makeEffect(
                    .trackEvictions(adjustment.evictedCardIDs),
                    operation: allocate(&state),
                    state: state
                ))
            }
            if adjustment.materializationChanged {
                effects.append(contentsOf: snapshotEffects(&state, operation: allocate(&state)))
            }
            // A scroll only *schedules* replenishment, and it coalesces: one page request per tail
            // ordinal, so a fling cannot queue a fetch per frame (plan §11, I-20).
            if shouldReplenish(state), let tail = state.window.tailOrdinal,
               state.replenishment[state.context] != tail {
                state.replenishment[state.context] = tail
                let operation = allocate(&state)
                state.pendingPage[state.context] = operation
                effects.append(makeEffect(
                    .replenish(context: state.context, fromOrdinal: tail + 1),
                    operation: operation,
                    state: state
                ))
            }

        case let .cardVisibility(observation):
            effects.append(makeEffect(
                .trackViewport(observation),
                operation: allocate(&state),
                state: state
            ))

        case let .centerCrossed(cardID, direction):
            effects.append(makeEffect(
                .trackCenterCrossed(cardID: cardID, direction: direction),
                operation: allocate(&state),
                state: state
            ))

        case let .opened(cardID, operationID):
            // Two facts from one action, and neither is inferred from the other (ADR-007 D5): `opened`
            // is the primary-action fact the tracker coalesces, `read` is the durable one the port owns
            // and D7 keys by the operation id.
            effects.append(makeEffect(
                .trackOpened(cardID: cardID),
                operation: allocate(&state),
                state: state
            ))
            effects.append(makeEffect(
                .recordRead(operationID: operationID, cardID: cardID),
                operation: allocate(&state),
                state: state
            ))

        case let .toggleBookmark(cardID, wanted, operationID):
            effects.append(makeEffect(
                .recordBookmark(operationID: operationID, cardID: cardID, wanted: wanted),
                operation: allocate(&state),
                state: state
            ))

        case .refresh:
            // A refresh is explicit and coalesced: while a composition for this context is pending,
            // another intent adds no work.
            guard state.pending[state.context] == nil else { return }
            let operation = allocate(&state)
            state.pending[state.context] = operation
            effects.append(makeEffect(
                .compose(context: state.context, reason: .refresh, fromOrdinal: nil),
                operation: operation,
                state: state
            ))

        case let .switchContext(context):
            guard context != state.context else { return }
            if let edition = state.visibleEdition, let anchor = state.window.anchor {
                effects.append(makeEffect(
                    .persistCheckpoint(SessionCheckpoint(
                        context: state.context,
                        editionID: edition,
                        anchor: anchor,
                        renderEnvironmentRevision: state.renderEnvironment,
                        policyVersion: state.historyPolicy.version.description,
                        updatedAtMs: 0
                    )),
                    operation: allocate(&state),
                    state: state
                ))
            }
            if let edition = state.visibleEdition {
                effects.append(makeEffect(
                    .closeExposureIntervals(edition: edition, reason: .editionSwap),
                    operation: allocate(&state),
                    state: state
                ))
            }
            state.context = context
            state.visibleEdition = nil
            state.editorialRevision = nil
            state.availability = .restoring
            state.materials.removeAll()
            state.bookmarked = []
            state.read = []
            state.pending.removeAll()
            state.pendingPage.removeAll()
            state.replenishment.removeAll()
            state.window = FeedWindow(configuration: state.window.configuration)
            let operation = allocate(&state)
            state.pending[context] = operation
            effects.append(makeEffect(.restore(context: context), operation: operation, state: state))
            effects.append(contentsOf: snapshotEffects(&state, operation: operation))
        }
    }

    // MARK: - Helpers

    private static func allocate(_ state: inout FeedSessionState) -> FeedSessionOperationID {
        let operation = FeedSessionOperationID(sessionStamp: state.stamp, ordinal: state.nextOperationOrdinal)
        state.nextOperationOrdinal += 1
        return operation
    }

    private static func makeEffect(
        _ kind: FeedSessionEffect.Kind,
        operation: FeedSessionOperationID,
        state: FeedSessionState
    ) -> FeedSessionEffect {
        FeedSessionEffect(operation: operation, sessionStamp: state.stamp, kind: kind)
    }

    private static func isCurrent(
        _ operation: FeedSessionOperationID,
        for context: ContextKey,
        in state: FeedSessionState
    ) -> Bool {
        guard operation.sessionStamp == state.stamp else { return false }
        guard context == state.context else { return false }
        return state.pending[context] == operation
    }

    private static func shouldReplenish(_ state: FeedSessionState) -> Bool {
        guard let viewport = state.window.viewport, let tail = state.window.tailOrdinal else { return false }
        return viewport.lastVisibleOrdinal >= tail - state.replenishmentDistance
    }

    /// Replaces the window content for a new edition and bounds the materialized cards by the window.
    private static func materialize(
        _ state: inout FeedSessionState,
        cards: [PublishedCardRecord],
        edition: EditionID,
        viewportOrdinal: Int,
        anchor: FeedWindowAnchor?
    ) {
        let materials = cards.map { FeedCardMaterial(record: $0, edition: edition) }
        state.window.materialize(
            materials.map(\.reference),
            viewport: FeedWindow.Viewport(
                firstVisibleOrdinal: viewportOrdinal,
                lastVisibleOrdinal: viewportOrdinal
            ),
            anchor: anchor
        )
        retain(&state, materials: materials)
    }

    /// Keeps only the materials the window still references: this is the memory bound in action.
    private static func retain(_ state: inout FeedSessionState, materials: [FeedCardMaterial]) {
        let allowed = Set(state.window.references.map(\.cardID))
        var retained: [PublicationCardID: FeedCardMaterial] = [:]
        for material in materials where allowed.contains(material.cardID) {
            retained[material.cardID] = material
        }
        for (cardID, material) in state.materials where allowed.contains(cardID) {
            retained[cardID] = material
        }
        state.materials = retained
    }

    private static func checkpointForFirstCard(of state: FeedSessionState) -> SessionCheckpoint? {
        guard let edition = state.visibleEdition,
              let first = state.window.references.first
        else { return nil }
        return SessionCheckpoint(
            context: state.context,
            editionID: edition,
            anchor: FeedWindowAnchor.top(
                of: first.cardID,
                ordinal: first.absoluteOrdinal,
                editionID: edition
            ),
            renderEnvironmentRevision: state.renderEnvironment,
            policyVersion: state.historyPolicy.version.description,
            updatedAtMs: 0
        )
    }

    private static func snapshotEffects(
        _ state: inout FeedSessionState,
        operation: FeedSessionOperationID
    ) -> [FeedSessionEffect] {
        state.sequence += 1
        // The decoded subset is decided once per snapshot: recomputing it per card would sort the
        // window 72 times for one snapshot, and the byte budget is the same for every card.
        let decoded = Set(state.window.materializedCardIDs)
        let snapshot = FeedPresentationSnapshot(
            sessionStamp: state.stamp,
            sequence: state.sequence,
            contextKey: state.context.canonicalSerialization,
            editionID: state.visibleEdition,
            editorialRevision: state.editorialRevision,
            renderEnvironment: state.renderEnvironment,
            cards: state.window.references.map { presentation(of: $0, state: state, decoded: decoded) }
        )
        return [makeEffect(.emitSnapshot(snapshot), operation: operation, state: state)]
    }

    private static func presentation(
        of reference: FeedWindowReference,
        state: FeedSessionState,
        decoded: Set<PublicationCardID>
    ) -> CardPresentation {
        guard let material = state.materials[reference.cardID] else {
            return CardPresentation(
                id: reference.cardID,
                absoluteOrdinal: reference.absoluteOrdinal,
                title: "",
                subtitle: nil,
                media: .placeholder(reason: "not materialized"),
                layout: .textOnly,
                isBookmarked: state.bookmarked.contains(reference.cardID),
                isRead: state.read.contains(reference.cardID)
            )
        }
        let media: CardPresentation.Media
        if decoded.contains(reference.cardID), let digest = material.mediaDigest {
            media = .local(assetDigest: digest)
        } else {
            media = .placeholder(reason: material.placeholderReason ?? "not materialized")
        }
        return CardPresentation(
            id: reference.cardID,
            absoluteOrdinal: reference.absoluteOrdinal,
            title: material.title,
            subtitle: material.subtitle,
            media: media,
            layout: material.layout,
            isBookmarked: state.bookmarked.contains(reference.cardID),
            isRead: state.read.contains(reference.cardID),
            publishedAt: material.publishedAt,
            sourceTitle: material.sourceTitle,
            link: material.link
        )
    }
}
