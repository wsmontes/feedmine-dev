import Foundation
import FeedDomain
import FeedStorage

/// Publication: the only append path into the published log (plan §9, ADR-001 D1–D3, ADR-006 D14).
///
/// The coordinator owns two things the repository cannot: *single-flight* per edition and *draft pins*.
/// Neither is the guarantee. The guarantee is the tail compare-and-swap and the schema's uniqueness
/// inside the commit transaction, which hold when two coordinator instances, or a crash-restarted one,
/// race for the same tail — which is exactly why single-flight is described as an optimisation and not
/// as correctness (ADR-006 D14, INV-5).
///
/// All long work happens outside the isolated state and outside the transaction: canonical content is
/// read, media bytes are made durable through the injected port, and only then does the commit open a
/// transaction that validates the token, re-checks eligibility and appends segment, cards and
/// references together (ADR-001 D10, D11).

// MARK: - Single-flight

/// One in-flight composition per edition.
///
/// Shared across instances only when a caller injects one: two independent coordinators each keep their
/// own map and the tail CAS is what keeps the log consistent.
public actor PublicationSingleFlight {
    private var inFlight: Set<EditionID> = []

    public init() {}

    /// Reserves the edition. Returns `false` when a composition for it is already running here.
    func begin(_ edition: EditionID) -> Bool {
        guard !inFlight.contains(edition) else { return false }
        inFlight.insert(edition)
        return true
    }

    func end(_ edition: EditionID) {
        inFlight.remove(edition)
    }

    /// The editions with a composition in flight, for diagnostics and for tests.
    public func inFlightEditions() -> [EditionID] {
        inFlight.sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - Draft pins

/// The revisions a composition pinned while it prepared media and payloads (ADR-002 D11).
///
/// A draft pins the exact `OriginRevisionID`s it selected, so eviction and GC can see them as roots
/// until the commit lands or the composition is discarded. Every exit path releases its own pins:
/// success, a refusal and a thrown failure all release before returning.
public actor DraftPins {
    private var assignments: [String: [OriginRevisionID]] = [:]

    public init() {}

    func hold(_ compositionID: String, revisions: [OriginRevisionID]) {
        assignments[compositionID] = Self.canonical(revisions)
    }

    func release(_ compositionID: String) {
        assignments[compositionID] = nil
    }

    /// Every revision currently pinned by a draft, deduplicated and sorted.
    public func pinnedRevisions() -> [OriginRevisionID] {
        Self.canonical(assignments.values.flatMap { $0 })
    }

    public func pinnedCount() -> Int {
        pinnedRevisions().count
    }

    public func isPinned(_ revision: OriginRevisionID) -> Bool {
        assignments.values.contains { $0.contains(revision) }
    }

    static func canonical(_ revisions: [OriginRevisionID]) -> [OriginRevisionID] {
        var seen = Set<Int64>()
        return revisions
            .filter { seen.insert($0.rawValue).inserted }
            .sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - Requests and outcomes

/// Which edition an append targets, stated explicitly (ADR-001 D9: only an explicit refresh, context
/// change or lifecycle boundary replaces the visible edition).
public enum EditionOpening: Hashable, Sendable {
    /// Append to the edition that is already visible. Refuses when its editorial revision moved.
    case visible
    /// Build a successor: reuse the uncommitted draft successor, or create one one epoch ahead.
    case successor
    /// Create the first edition for a context that has none.
    case first(epoch: Int64)
}

public struct EditionOpeningResult: Hashable, Sendable {
    public let edition: EditionSnapshot
    /// `append` for a visible edition, `activate` for a first or successor edition (ADR-001 D7).
    public let activation: SegmentActivation
    /// True when this call created the draft; false when it reused one.
    public let created: Bool
}

/// One publication request: the resolved plan, the editorial sequence to freeze, the token captured
/// before the long work, and what each card's media is.
public struct PublicationRequest: Sendable {
    public let plan: ResolvedFeedPlan
    public let sequence: EditorialSequence
    /// The token captured when the composition started. `nil` captures the tail at call time, which is
    /// only correct when nothing long happens in between.
    public let token: PublicationToken?
    public let media: [PublishedCardMediaPlan]
    /// How the committed segment relates to the visible edition. `nil` follows the edition's state:
    /// `activate` for a draft, `append` for an active edition.
    public let activation: SegmentActivation?

    public init(
        plan: ResolvedFeedPlan,
        sequence: EditorialSequence,
        token: PublicationToken? = nil,
        media: [PublishedCardMediaPlan] = [],
        activation: SegmentActivation? = nil
    ) {
        self.plan = plan
        self.sequence = sequence
        self.token = token
        self.media = media
        self.activation = activation
    }
}

/// What one append produced.
public struct PublicationReceipt: Hashable, Sendable {
    public let editionID: EditionID
    public let segmentID: SegmentID
    public let segmentOrdinal: Int
    public let absoluteOrdinalStart: Int
    public let absoluteOrdinalEnd: Int
    public let cardIDs: [PublicationCardID]
    public let tail: EditionTail
    public let activated: Bool
    /// How many commit attempts the append took: more than one means a storage failure was retried.
    public let attempts: Int
}

public enum PublicationOutcome: Equatable, Sendable {
    case published(PublicationReceipt)
    /// A composition for this edition is already running in this coordinator.
    case alreadyInFlight(EditionID)
    /// The sequence has no card: nothing is published and nothing is activated.
    case nothingToPublish(EditionID)
    case failed(PublicationFailure)

    public var receipt: PublicationReceipt? {
        if case let .published(receipt) = self { return receipt }
        return nil
    }

    public var failure: PublicationFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }
}

// MARK: - The coordinator

public struct PublicationCoordinator: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// How many times a commit whose *storage* failed may be retried with the same token. A tail
        /// conflict is never retried here: it invalidates the composition, and recomposing means
        /// selecting again, which is the caller's job (ADR-002 D11d).
        public let commitRetryLimit: Int

        public init(commitRetryLimit: Int = 2) {
            self.commitRetryLimit = commitRetryLimit
        }
    }

    private let repository: PublicationRepository
    private let clock: EditorialClock
    private let assets: (any PublishedAssetCommitting)?
    private let configuration: Configuration
    public let singleFlight: PublicationSingleFlight
    public let draftPins: DraftPins

    public init(
        repository: PublicationRepository,
        clock: EditorialClock,
        assets: (any PublishedAssetCommitting)? = nil,
        configuration: Configuration = Configuration(),
        singleFlight: PublicationSingleFlight = PublicationSingleFlight(),
        draftPins: DraftPins = DraftPins()
    ) {
        self.repository = repository
        self.clock = clock
        self.assets = assets
        self.configuration = configuration
        self.singleFlight = singleFlight
        self.draftPins = draftPins
    }

    // MARK: Opening an edition

    /// Resolves the edition an append goes into, creating a draft when the intent says so.
    ///
    /// A passive catalog, binding or endpoint change never swaps the visible edition: this call returns
    /// the active edition unless the caller explicitly asks for a successor (ADR-002 D9, INV-15).
    public func openEdition(
        _ opening: EditionOpening,
        plan: ResolvedFeedPlan,
        seed: Data,
        at: Date? = nil
    ) throws -> EditionOpeningResult {
        let now = at ?? clock.now
        switch opening {
        case .visible:
            guard let active = try repository.activeEdition(for: plan.context) else {
                throw PublicationFailure.invalidComposition(
                    "the context has no visible edition; open .first"
                )
            }
            guard active.editorialRevision == plan.editorialRevision else {
                throw PublicationFailure.editorialRevisionChanged(
                    expected: active.editorialRevision.digest,
                    actual: plan.editorialRevision.digest
                )
            }
            return EditionOpeningResult(edition: active, activation: .append, created: false)

        case .successor:
            let active = try repository.activeEdition(for: plan.context)
            if let draft = try reusableDraft(for: plan) {
                return EditionOpeningResult(
                    edition: draft,
                    activation: .activate(successorOf: active?.editionID),
                    created: false
                )
            }
            let epoch = (active?.epoch ?? 0) + 1
            let created = try repository.beginEdition(
                context: plan.context,
                editorialRevision: plan.editorialRevision,
                epoch: epoch,
                seed: seed,
                successorOf: active?.editionID,
                at: now
            )
            return EditionOpeningResult(
                edition: created,
                activation: .activate(successorOf: active?.editionID),
                created: true
            )

        case let .first(epoch):
            if let active = try repository.activeEdition(for: plan.context) {
                throw PublicationFailure.invalidComposition(
                    "the context already has a visible edition (\(active.editionID))"
                )
            }
            if let draft = try reusableDraft(for: plan) {
                return EditionOpeningResult(
                    edition: draft,
                    activation: .activate(successorOf: nil),
                    created: false
                )
            }
            let created = try repository.beginEdition(
                context: plan.context,
                editorialRevision: plan.editorialRevision,
                epoch: epoch,
                seed: seed,
                successorOf: nil,
                at: now
            )
            return EditionOpeningResult(edition: created, activation: .activate(successorOf: nil), created: true)
        }
    }

    /// The token a commitment must present. Read before the long work, never after.
    public func token(for edition: EditionID) throws -> PublicationToken {
        try repository.token(for: edition)
    }

    /// Removes a draft successor that never committed a segment. Refuses when it has history.
    @discardableResult
    public func abandonUncommittedEdition(_ edition: EditionID) throws -> Bool {
        try repository.discardUncommittedEdition(edition)
    }

    // MARK: The append

    /// Publishes one segment. This is the only public API in the runtime that appends to the published
    /// log (I-10, INV-4).
    public func publish(_ request: PublicationRequest) async -> PublicationOutcome {
        guard request.sequence.editorialRevision == request.plan.editorialRevision else {
            return .failed(.invalidComposition("the sequence was composed under another editorial revision"))
        }
        let editionID: EditionID
        do {
            if let named = request.token?.editionID {
                editionID = named
            } else if let visible = try repository.activeEdition(for: request.plan.context) {
                editionID = visible.editionID
            } else {
                return .failed(
                    .invalidComposition("the context has no visible edition; open one before publishing")
                )
            }
        } catch let failure as PublicationFailure {
            return .failed(failure)
        } catch {
            return .failed(.invalidComposition("\(error)"))
        }

        guard await singleFlight.begin(editionID) else {
            return .alreadyInFlight(editionID)
        }

        // The composition id keys the draft pins for this one call. It is never persisted, so a
        // collision-free random value is the right identity here.
        let compositionID = UUID().uuidString
        let outcome = await composeAndCommit(request, editionID: editionID, compositionID: compositionID)
        await draftPins.release(compositionID)
        await singleFlight.end(editionID)
        return outcome
    }

    private func composeAndCommit(
        _ request: PublicationRequest,
        editionID: EditionID,
        compositionID: String
    ) async -> PublicationOutcome {
        guard !request.sequence.cards.isEmpty else {
            return .nothingToPublish(editionID)
        }

        let token: PublicationToken
        let edition: EditionSnapshot
        do {
            token = try request.token ?? repository.token(for: editionID)
            guard let snapshot = try repository.edition(editionID) else {
                return .failed(.editionNotFound(editionID))
            }
            edition = snapshot
        } catch let failure as PublicationFailure {
            return .failed(failure)
        } catch {
            return .failed(.invalidComposition("\(error)"))
        }

        // The pins are held from here to the end of the commit: eviction must not be able to remove a
        // revision this composition is about to freeze (ADR-002 D11).
        let pinned = request.sequence.cards.map(\.choice.originRevisionID)
        await draftPins.hold(compositionID, revisions: pinned)

        let activation = request.activation ?? defaultActivation(for: edition)
        let composed: ComposedSegment
        do {
            composed = try await compose(
                request,
                token: token,
                edition: edition,
                activation: activation
            )
        } catch let failure as PublicationFailure {
            return .failed(failure)
        } catch let error as PublishedAssetCommitError {
            return .failed(.assetCommitFailed("\(error)"))
        } catch {
            // A storage failure while reading canonical content, or anything else the composition threw:
            // nothing is published and the previous edition stays visible.
            return .failed(.storageFailure("\(error)"))
        }

        return commit(composed, token: token)
    }

    /// The commit, with the bounded retry that is only legitimate for a storage failure: the
    /// transaction wrote nothing, so the same token is still the right one — and it is re-checked
    /// first, so a tail that moved is reported instead of silently renumbered.
    private func commit(_ composed: ComposedSegment, token: PublicationToken) -> PublicationOutcome {
        var attempt = 1
        while true {
            do {
                let receipt = try repository.commit(composed.request, attempt: attempt)
                return .published(
                    PublicationReceipt(
                        editionID: receipt.editionID,
                        segmentID: receipt.segmentID,
                        segmentOrdinal: receipt.segmentOrdinal,
                        absoluteOrdinalStart: receipt.absoluteOrdinalStart,
                        absoluteOrdinalEnd: receipt.absoluteOrdinalEnd,
                        cardIDs: receipt.cardIDs,
                        tail: receipt.tail,
                        activated: receipt.activated,
                        attempts: attempt
                    )
                )
            } catch let failure as PublicationFailure {
                return .failed(failure)
            } catch let error as RuntimeDatabaseError {
                // The only retryable outcome: the storage layer failed, so the transaction wrote
                // nothing and the same token is still the right one. The tail is re-read first, so a
                // commit that another writer landed in the meantime is reported instead of retried.
                guard attempt <= configuration.commitRetryLimit else {
                    return .failed(.storageFailure("\(error)"))
                }
                guard let current = try? repository.token(for: token.editionID) else {
                    return .failed(.editionNotFound(token.editionID))
                }
                guard current == token else {
                    return .failed(.tailMismatch(expected: token.tail, actual: current.tail))
                }
                attempt += 1
            } catch {
                // Any other failure is not a storage failure: retrying it would repeat a refusal, so the
                // composition is discarded and the previous edition stays visible (ADR-006 D10).
                return .failed(.storageFailure("\(error)"))
            }
        }
    }

    private func defaultActivation(for edition: EditionSnapshot) -> SegmentActivation {
        switch edition.state {
        case .draft: return .activate(successorOf: edition.successorOfEditionID)
        case .active, .superseded, .purged: return .append
        }
    }

    private func reusableDraft(for plan: ResolvedFeedPlan) throws -> EditionSnapshot? {
        guard let draft = try repository.latestEdition(for: plan.context), draft.state == .draft else {
            return nil
        }
        guard draft.editorialRevision == plan.editorialRevision else {
            // An uncommitted draft under a different revision is not history: discard it and build the
            // successor this plan asks for (ADR-001 D9).
            try repository.discardUncommittedEdition(draft.editionID)
            return nil
        }
        return draft
    }

    // MARK: Composition

    private struct ComposedSegment {
        let request: SegmentCommitRequest
    }

    /// Everything the commit needs, built outside the transaction: content read from canonical state,
    /// bytes made durable through the media port, payloads frozen from both.
    private func compose(
        _ request: PublicationRequest,
        token: PublicationToken,
        edition: EditionSnapshot,
        activation: SegmentActivation
    ) async throws -> ComposedSegment {
        let plans = Dictionary(
            request.media.map { ($0.originRevisionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var cards: [CardInsertRecord] = []
        var assetVersions: [AssetIdentity: AssetVersionRecord] = [:]
        var preparations: [MediaPreparationRecord] = []

        for (offset, card) in request.sequence.cards.enumerated() {
            guard card.ordinal == offset else {
                throw PublicationFailure.invalidComposition("sequence ordinals are not contiguous from zero")
            }
            let revisionID = card.choice.originRevisionID
            guard let content = try repository.cardContent(originRevisionID: revisionID) else {
                throw PublicationFailure.eligibilityRevoked(originRevisionID: revisionID)
            }
            let plan = plans[revisionID] ?? PublishedCardMediaPlan.unprepared(content)
            let composed = try await composeCard(
                content: content,
                plan: plan,
                edition: edition,
                absoluteOrdinal: token.tail.nextAbsoluteOrdinal + offset,
                segmentOrdinal: token.tail.nextSegmentOrdinal,
                editorialRevision: token.editorialRevision
            )
            cards.append(composed.card)
            for asset in composed.assets {
                assetVersions[
                    AssetIdentity(digest: asset.commit.contentDigest, recipeVersion: asset.commit.recipeVersion)
                ] = asset
            }
            preparations.append(contentsOf: composed.preparations)
        }

        let segmentRequest = SegmentCommitRequest(
            token: token,
            segmentOrdinal: token.tail.nextSegmentOrdinal,
            absoluteOrdinalStart: token.tail.nextAbsoluteOrdinal,
            segmentSeed: request.sequence.seed,
            policyRevision: token.editorialRevision.digest,
            committedAt: clock.now,
            activation: activation,
            cards: cards,
            assets: assetVersions.values.sorted {
                $0.commit.contentDigest == $1.commit.contentDigest
                    ? $0.commit.recipeVersion < $1.commit.recipeVersion
                    : $0.commit.contentDigest < $1.commit.contentDigest
            },
            mediaPreparations: preparations,
            pinnedRevisions: request.sequence.cards.map(\.choice.originRevisionID)
        )
        return ComposedSegment(request: segmentRequest)
    }

    private struct AssetIdentity: Hashable {
        let digest: String
        let recipeVersion: Int
    }

    private struct ComposedCard {
        let card: CardInsertRecord
        let assets: [AssetVersionRecord]
        let preparations: [MediaPreparationRecord]
    }

    /// One card's payload and media, composed outside the transaction.
    ///
    /// Media bytes are committed here, before the publication transaction exists: a reference to bytes
    /// that were never durably written is impossible by construction (ADR-001 D11, INV-7). A declared
    /// slot with no prepared bytes keeps its geometry through the deterministic placeholder, and a card
    /// whose revision declares nothing renderable is text only, which is the offline path of plan §10.
    private func composeCard(
        content: PublicationCardContent,
        plan: PublishedCardMediaPlan,
        edition: EditionSnapshot,
        absoluteOrdinal: Int,
        segmentOrdinal: Int,
        editorialRevision: EditorialRevision
    ) async throws -> ComposedCard {
        var primary: PublishedMediaRef?
        var mediaReferences: [PublishedAssetReference] = []
        var assetReferences: [PublishedAssetRefRecord] = []
        var committed: [AssetVersionRecord] = []
        var preparations: [MediaPreparationRecord] = []
        var declaredSlot: (slot: MediaSlot, aspectRatio: Double?)?

        for entry in plan.entries {
            switch entry {
            case let .prepared(assetRequest):
                guard let assets else {
                    throw PublicationFailure.assetCommitFailed(
                        "no asset committer is composed, so prepared media cannot be made durable"
                    )
                }
                let commit = try await assets.commit(assetRequest)
                guard let slot = PublishedMediaPlacement.assetSlot(for: assetRequest.role),
                      let renderSlot = PublishedMediaPlacement.renderSlot(for: assetRequest.role)
                else {
                    // Integral media is never referenced by a published card: the card renders its text
                    // and whatever still image the revision declares (ADR-001 D10). No `asset_version`
                    // row claims those bytes are published either — they stay orphan cache under quota,
                    // which is exactly the residue ADR-004 D13 permits (plan §10).
                    preparations.append(
                        preparation(
                            for: content,
                            assetRequest: assetRequest,
                            state: .noMedia,
                            edition: edition
                        )
                    )
                    continue
                }
                committed.append(try AssetVersionRecord(commit: commit, createdAt: clock.now))
                let media = commit.mediaReference
                mediaReferences.append(
                    PublishedAssetReference(
                        slot: slot,
                        role: assetRequest.role,
                        renderSlot: renderSlot,
                        media: media
                    )
                )
                assetReferences.append(
                    PublishedAssetRefRecord(
                        slot: slot,
                        role: assetRequest.role,
                        renderSlot: renderSlot,
                        contentDigest: media.contentDigest,
                        recipeVersion: media.recipeVersion,
                        aspectRatio: media.aspectRatio
                    )
                )
                if slot == .primary { primary = media }
                preparations.append(
                    preparation(
                        for: content,
                        assetRequest: assetRequest,
                        state: .prepared,
                        edition: edition
                    )
                )

            case let .placeholder(candidateKey, role, declaredAspectRatio):
                if let renderSlot = PublishedMediaPlacement.renderSlot(for: role) {
                    declaredSlot = better(declaredSlot, slot: renderSlot, aspectRatio: declaredAspectRatio)
                }
                preparations.append(
                    MediaPreparationRecord(
                        originRevisionID: content.originRevisionID,
                        candidateKey: candidateKey,
                        role: role,
                        state: .placeholder,
                        placeholderRecipe: Self.placeholderRecipe(role),
                        decisionRevision: edition.epoch,
                        updatedAt: clock.now
                    )
                )

            case let .noMedia(candidateKey, role):
                preparations.append(
                    MediaPreparationRecord(
                        originRevisionID: content.originRevisionID,
                        candidateKey: candidateKey,
                        role: role,
                        state: .noMedia,
                        decisionRevision: edition.epoch,
                        updatedAt: clock.now
                    )
                )
            }
        }

        let placeholder: PublishedPlaceholder?
        if primary == nil, assetReferences.isEmpty, let declaredSlot {
            placeholder = PublishedPlaceholder(
                originRevisionID: content.originRevisionID,
                slot: declaredSlot.slot,
                aspectRatio: declaredSlot.aspectRatio
            )
        } else {
            placeholder = nil
        }
        let mediaSet = PublishedMediaSet(
            primary: primary,
            alternates: mediaReferences.filter { $0.slot != .primary },
            placeholder: placeholder
        )
        let timestamp = content.declaredTimestamp
        let frozen = PublishedCardPayload.Frozen(
            editionID: edition.editionID,
            segmentOrdinal: segmentOrdinal,
            absoluteOrdinal: absoluteOrdinal,
            origin: content.publishedOrigin,
            title: content.cardTitle,
            primaryText: content.cardPrimaryText,
            publishedAt: timestamp.date,
            publishedAtKind: timestamp.kind,
            observationAt: content.observedAt,
            media: mediaSet,
            primaryAction: try content.primaryAction(),
            interactionSummary: content.interactionSummary,
            renderContract: RenderContract.resolved(media: mediaSet),
            editorialRevision: editorialRevision,
            publicationSchemaVersion: edition.publicationSchemaVersion
        )
        return ComposedCard(
            card: CardInsertRecord(frozen: frozen, assetReferences: assetReferences),
            assets: committed,
            preparations: preparations
        )
    }

    /// The placeholder recipe token stored beside a candidate that was never prepared.
    static func placeholderRecipe(_ role: MediaRole) -> String {
        "placeholder-v\(PublishedPlaceholder.currentRecipeVersion)-\(role.rawValue)"
    }

    private func preparation(
        for content: PublicationCardContent,
        assetRequest: PublishedAssetRequest,
        state: MediaPreparationRecord.State,
        edition: EditionSnapshot
    ) -> MediaPreparationRecord {
        MediaPreparationRecord(
            originRevisionID: content.originRevisionID,
            candidateKey: assetRequest.candidateKey,
            role: assetRequest.role,
            state: state,
            contentDigest: state == .prepared ? assetRequest.contentDigest : nil,
            recipeVersion: state == .prepared ? assetRequest.recipeVersion : nil,
            decisionRevision: edition.epoch,
            updatedAt: clock.now
        )
    }

    /// The sharper declaration wins: primary beats poster beats thumbnail beats waveform.
    private func better(
        _ current: (slot: MediaSlot, aspectRatio: Double?)?,
        slot: MediaSlot,
        aspectRatio: Double?
    ) -> (slot: MediaSlot, aspectRatio: Double?) {
        guard let current else { return (slot, aspectRatio) }
        if Self.rank(slot) < Self.rank(current.slot) { return (slot, aspectRatio) }
        if Self.rank(slot) == Self.rank(current.slot), current.aspectRatio == nil {
            return (current.slot, aspectRatio)
        }
        return current
    }

    private static func rank(_ slot: MediaSlot) -> Int {
        switch slot {
        case .primary: return 0
        case .poster: return 1
        case .thumbnail: return 2
        case .waveform: return 3
        case .none: return 4
        }
    }
}
