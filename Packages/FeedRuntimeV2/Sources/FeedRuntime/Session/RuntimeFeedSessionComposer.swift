import Foundation
import FeedDomain
import FeedStorage

/// What one composition needs that only the composition root knows (plan §11, ADR-002 D6).
///
/// The runtime can read canonical supply, but it cannot invent *which* plan a screen is showing: the
/// plan's source selection, its filters and its editorial revision come from the app's own selectors
/// (`FeedSurfaceCatalog.Inputs`), and the projections the revision is computed from come from the
/// catalogue and the reader's user state. The composition root therefore states them once per context,
/// and the composer only checks that what it was handed agrees with the context it was asked for.
public struct FeedCompositionPlan: Sendable {
    public let plan: ResolvedFeedPlan
    /// The projections the plan's `editorialRevision` was computed from. The composer passes them back
    /// to Selection unchanged, so the engine can prove the revision is reproducible (ADR-002 D6).
    public let projections: PlanProjections
    /// Per-edition randomness for the plan's declared exploration weight.
    public let seed: Data

    public init(plan: ResolvedFeedPlan, projections: PlanProjections, seed: Data) {
        self.plan = plan
        self.projections = projections
        self.seed = seed
    }
}

/// Resolves the plan a context composes under. `nil` means the context is not one this composition can
/// serve, which is a refusal rather than an empty composition.
public struct FeedPlanSource: Sendable {
    private let provide: @Sendable (ContextKey) -> FeedCompositionPlan?

    public init(_ provide: @escaping @Sendable (ContextKey) -> FeedCompositionPlan?) {
        self.provide = provide
    }

    public func compositionPlan(for context: ContextKey) -> FeedCompositionPlan? { provide(context) }
}

/// What a composition does before it selects: it acquires (plan §14, ADR-005 D6/D8).
///
/// Acquisition is a step of composition and not a side effect beside it. A launch that composes without
/// acquiring selects against an empty supply and publishes nothing, which is exactly the failure
/// `v2Full` would ship if the two were separate.
public protocol FeedCompositionAcquiring: Sendable {
    /// Runs one bounded episode for the plan's context and returns what it did, or `nil` when this
    /// composition needs no acquisition (a plan whose supply is already local and fresh).
    func acquire(
        for plan: ResolvedFeedPlan,
        reason: FeedSessionCompositionReason,
        at: Date
    ) async -> AcquisitionRunSummary?
}

/// Prepares the selected sequence for publication without exposing media/network implementation to
/// FeedRuntime. The app composition root is the only place that can see FeedStorage and FeedMedia
/// together, so it implements this port and returns protocol-free publication plans.
///
/// A failed candidate is represented by a placeholder/no-media entry in its returned plan; media
/// failure never erases otherwise publishable text.
public protocol FeedCompositionMediaPreparing: Sendable {
    func prepareMedia(
        for sequence: EditorialSequence,
        at: Date
    ) async -> [PublishedCardMediaPlan]
}

public enum FeedSessionComposerError: Error, Equatable, Sendable {
    /// The composition root has no plan for this context. Composing would mean selecting under a plan
    /// nobody declared.
    case planUnavailable(ContextKey)
    /// The plan handed back is for another context: composing it would publish the wrong surface's feed.
    case planContextMismatch(expected: ContextKey, provided: ContextKey)
    /// The editorial revision the plan carries is not one this build's resolver can reproduce.
    case revisionNotReproducible(String)
    /// The edition could not be opened or read.
    case editionUnavailable(EditionID)
    /// The append failed. The previous edition stays visible (ADR-002 D9).
    case publicationFailed(String)
    /// A composition for this edition is already running here.
    case alreadyInFlight(EditionID)
}

/// The production `FeedSessionComposer`: plan → acquire → select → sequence → publish → read back.
///
/// It is the whole composition path the session's port describes, and it owns no state of its own: the
/// single-flight, the draft pins and the tail compare-and-swap live in `PublicationCoordinator`, the
/// canonical reads in `SelectionSupplyRepository`, and the plan comes from the composition root. Every
/// step that can be slow (acquisition, selection, the append) happens before a transaction opens, and
/// the edition the snapshot names is read back after the commit, so the session is never handed a
/// composition that was not durable.
///
/// Media is prepared through an injected port before publication. FeedRuntime never imports FeedMedia:
/// the composition root performs that boundary crossing and returns protocol-free media plans. A
/// candidate that cannot be prepared still becomes a deterministic placeholder, so media failure never
/// makes text disappear and the renderer remains network-free.
/// One composition decision, reported so a publication path is never silent.
///
/// An episode that appends an edition is the most consequential thing the runtime does, and until this
/// existed nothing said it had happened: a launch was observed running a successor-edition loop at
/// seventeen editions a second with the whole app log showing twelve distinct lines and no repeats.
public struct FeedCompositionEvent: Sendable {
    public enum Decision: String, Sendable {
        /// A segment was appended.
        case published
        /// Nothing had been admitted since the last composition: the visible edition already says
        /// everything canonical supply can say, so nothing was appended.
        case unchanged
        /// The acquisition ran and selection found nothing to publish.
        case empty
    }

    public let context: String
    public let reason: FeedSessionCompositionReason
    public let decision: Decision
    public let editionID: String
    public let publishedCards: Int

    public init(
        context: String,
        reason: FeedSessionCompositionReason,
        decision: Decision,
        editionID: String,
        publishedCards: Int
    ) {
        self.context = context
        self.reason = reason
        self.decision = decision
        self.editionID = editionID
        self.publishedCards = publishedCards
    }

    /// One line, no content and no URL (plan §16).
    public var diagnostic: String {
        "composition context=\(context) reason=\(reason.rawValue) decision=\(decision.rawValue) "
            + "edition=\(editionID) cards=\(publishedCards)"
    }
}

/// What the last composition of each context admitted, so a refresh can tell "supply moved" from "the
/// reader's viewport moved" (ADR-002 D4: a `SupplyGeneration` increment never invalidates a plan, and
/// an increment that did not happen cannot justify a new edition).
private actor CompositionLedger {
    private var generation: [String: UInt64] = [:]
    private var edition: [String: EditionID] = [:]

    func record(context: String, supplyGeneration: UInt64, editionID: EditionID) {
        generation[context] = supplyGeneration
        edition[context] = editionID
    }

    func lastSupplyGeneration(context: String) -> UInt64? { generation[context] }
    func lastEdition(context: String) -> EditionID? { edition[context] }
}

public struct RuntimeFeedSessionComposer: FeedSessionComposer {
    private let database: RuntimeDatabase
    private let repository: PublicationRepository
    private let plans: FeedPlanSource
    private let acquisition: (any FeedCompositionAcquiring)?
    private let media: (any FeedCompositionMediaPreparing)?
    private let engine: SelectionEngine
    private let sequencer: EditorialSequencer
    private let coordinator: PublicationCoordinator
    private let supply: SelectionSupplyRepository
    private let ledger = CompositionLedger()
    /// Where a composition reports itself. `nil` in a composition with no diagnostics.
    private let observe: (@Sendable (FeedCompositionEvent) -> Void)?

    public init(
        database: RuntimeDatabase,
        repository: PublicationRepository,
        plans: FeedPlanSource,
        coordinator: PublicationCoordinator,
        acquisition: (any FeedCompositionAcquiring)? = nil,
        media: (any FeedCompositionMediaPreparing)? = nil,
        engine: SelectionEngine = SelectionEngine(),
        sequencer: EditorialSequencer = EditorialSequencer(),
        observe: (@Sendable (FeedCompositionEvent) -> Void)? = nil
    ) {
        self.database = database
        self.repository = repository
        self.plans = plans
        self.coordinator = coordinator
        self.acquisition = acquisition
        self.media = media
        self.engine = engine
        self.sequencer = sequencer
        self.supply = SelectionSupplyRepository()
        self.observe = observe
    }

    public func compose(
        context: ContextKey,
        reason: FeedSessionCompositionReason,
        at: Date
    ) async throws -> FeedSessionComposition {
        guard let input = plans.compositionPlan(for: context) else {
            throw FeedSessionComposerError.planUnavailable(context)
        }
        guard input.plan.context == context else {
            throw FeedSessionComposerError.planContextMismatch(
                expected: context,
                provided: input.plan.context
            )
        }

        // 1. Acquire. The result is deliberately not interpreted here: what was fetched is what
        //    Admission admitted, and Selection reads the canonical projection rather than a count.
        if let acquisition {
            _ = await acquisition.acquire(for: input.plan, reason: reason, at: at)
        }

        // 2. The guard that makes an idle launch reach a steady state.
        //
        //    A refresh is driven by the viewport, and a snapshot re-materializes the screen, which can
        //    produce another viewport observation. Without this, each lap legitimately appended a
        //    successor edition — one in-flight composition per *edition* never engages, because the lap
        //    creates a new edition each time — and a launch was observed appending seventeen editions a
        //    second with no user input, indefinitely.
        //
        //    Canonical supply is what a composition can add something *from*: if it has not moved since
        //    the last composition of this context, the visible edition already says everything it can
        //    say, and the honest answer to a refresh is that edition. A first composition, a context
        //    switch and a plan whose supply actually changed all pass the guard.
        let supplyGeneration = (try? supply.supplyGeneration(in: database)) ?? 0
        let opensAnEdition = reason == .cold || reason == .contextSwitch
        if !opensAnEdition,
           let active = try? repository.activeEdition(for: context),
           let lastGeneration = await ledger.lastSupplyGeneration(context: contextKey(context)),
           lastGeneration == supplyGeneration {
            let cards = (try? repository.cards(in: active.editionID)) ?? []
            observe?(FeedCompositionEvent(
                context: context.canonicalSerialization,
                reason: reason,
                decision: .unchanged,
                editionID: active.editionID.description,
                publishedCards: cards.count
            ))
            return FeedSessionComposition(edition: active, cards: cards)
        }

        // 3. Open the edition this composition appends to. A refresh builds a successor so the segment
        //    that is visible keeps the ordinal space it was published under (ADR-001 D9).
        let opening = Self.opening(for: reason)
        let opened: EditionOpeningResult
        do {
            opened = try coordinator.openEdition(opening, plan: input.plan, seed: input.seed, at: at)
        } catch let failure as PublicationFailure {
            throw FeedSessionComposerError.publicationFailed(failure.description)
        }

        // 3. The token is read *before* selection, so the CAS expectation names the tail the
        //    composition actually started from (ADR-002 D11b).
        let token: PublicationToken
        do {
            token = try coordinator.token(for: opened.edition.editionID)
        } catch let failure as PublicationFailure {
            throw FeedSessionComposerError.publicationFailed(failure.description)
        } catch {
            throw FeedSessionComposerError.editionUnavailable(opened.edition.editionID)
        }

        // 4. Select. A revision the engine cannot reproduce is a refusal, never a composition under
        //    inputs the revision does not name (ADR-002 D6).
        let draft: SelectionDraft
        do {
            draft = try engine.draft(
                plan: input.plan,
                projections: input.projections,
                seed: input.seed,
                in: database
            )
        } catch let error as SelectionError {
            throw FeedSessionComposerError.revisionNotReproducible("\(error)")
        }

        // 5. Sequence against what this context already published, so the repetition window is real
        //    and a refresh does not recur the page the reader is looking at (ADR-007 D13).
        //
        //    A plan whose cards are the reader's own saved subjects is exempt. A box's content *is* that
        //    set, so sequencing it against its own history suppresses the whole page — measured
        //    2026-09-18 (baseline §8.62): a box's session restored 3 cards, the screen drew the session's
        //    page (`page-source=session-snapshot`), the viewport's refresh composed a successor, and that
        //    successor published `decision=empty` because every card it selected had just been published
        //    by this same context. ADR-007 D12 already states this for `seen` — a bookmark scope may not
        //    exclude — and one box's membership is the same kind of fact.
        let history = input.plan.subjectSelection == nil
            ? (try? repository.publishedOccurrences(
                for: context,
                editions: max(1, input.plan.repetitionPolicy.window)
            ))
            : nil
        let sequence = sequencer.sequence(draft: draft, plan: input.plan, history: history ?? .empty)

        // 6. Prepare media outside the publication transaction. The port returns one plan per selected
        //    revision; failed candidates stay explicit placeholders rather than becoming renderer work.
        let mediaPlans = await media?.prepareMedia(for: sequence, at: at) ?? []

        // 7. Append. `nothingToPublish` is not a failure: an edition whose supply is short publishes
        //    the segment it can and reports the shortfall.
        let outcome = await coordinator.publish(PublicationRequest(
            plan: input.plan,
            sequence: sequence,
            token: token,
            media: mediaPlans,
            activation: opened.activation
        ))
        switch outcome {
        case .published, .nothingToPublish:
            break
        case .alreadyInFlight(let edition):
            throw FeedSessionComposerError.alreadyInFlight(edition)
        case .failed(let failure):
            throw FeedSessionComposerError.publicationFailed(failure.description)
        }

        // 8. Read back what is now durable: the edition row after the commit and the cards of that
        //    edition. The session's window is materialized from these rows and nothing else.
        guard let edition = try repository.edition(opened.edition.editionID) else {
            throw FeedSessionComposerError.editionUnavailable(opened.edition.editionID)
        }
        let cards = try repository.cards(in: edition.editionID)
        await ledger.record(
            context: contextKey(context),
            supplyGeneration: supplyGeneration,
            editionID: edition.editionID
        )
        observe?(FeedCompositionEvent(
            context: context.canonicalSerialization,
            reason: reason,
            decision: cards.isEmpty ? .empty : .published,
            editionID: edition.editionID.description,
            publishedCards: cards.count
        ))
        return FeedSessionComposition(edition: edition, cards: cards)
    }

    /// The ledger's key. A `ContextKey` is already canonical, so its serialization is its identity here.
    private func contextKey(_ context: ContextKey) -> String { context.canonicalSerialization }

    public func releaseResources(for editions: [EditionID]) async {
        // The only per-composition resource this composer holds is the coordinator's draft pins, and
        // `PublicationCoordinator` releases them on every exit path of `publish`. There is nothing
        // here to release, and pretending otherwise would double-release someone else's state.
    }

    /// Which edition a composition appends to. A cold open or a context switch builds the first
    /// edition of a context; a refresh or a replenishment builds a successor.
    static func opening(for reason: FeedSessionCompositionReason) -> EditionOpening {
        switch reason {
        case .cold, .contextSwitch: return .first(epoch: 1)
        case .refresh, .replenishment: return .successor
        }
    }
}
