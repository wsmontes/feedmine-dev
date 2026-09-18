import Foundation
import FeedDomain
import FeedStorage

/// The session that owns the lifecycle of one feed screen (plan §11).
///
/// Its responsibilities are exactly three, and nothing else in the runtime may hold them:
///
/// * **cancellation and teardown** — every long effect runs in a task this session owns, keyed by the
///   operation that produced it, so a superseded composition is cancelled instead of racing the state
///   machine, and `teardown()` cancels what is left, releases the composer's pins and finishes the
///   snapshot streams;
/// * **restore and local paging** — a compatible checkpoint plus a stored edition becomes a snapshot
///   with zero composition, zero Selection and zero network (ADR-002 D8); later pages are read from
///   `published_card` by `absoluteOrdinal`, never fetched;
/// * **exposure flushing** — the tracker is fed small observations and its confirmed facts travel to
///   `exposure_fact` in one transaction per batch, at milestones and at every interval close.
///
/// Two ports carry every external effect the session can start. `FeedSessionComposer` is the whole
/// composition path (Selection, media preparation, publication); `FeedSessionUserActions` is the
/// durable user-state path owned by `user.sqlite`. A test proves the warm path calls neither.
public protocol FeedSessionComposer: Sendable {
    /// Composes or re-composes one context. The result is frozen before it returns; the session never
    /// inspects a connector, a draft or a plan.
    func compose(
        context: ContextKey,
        reason: FeedSessionCompositionReason,
        at: Date
    ) async throws -> FeedSessionComposition

    /// Releases whatever the session held for those editions (draft pins, single-flight entries).
    /// Called on teardown and on a context switch, so abandoning a screen cannot leak a pin.
    func releaseResources(for editions: [EditionID]) async
}

/// One composition result in the terms the session consumes: the edition row plus the cards frozen in
/// it. Both are storage read models, so nothing here re-derives publication state.
public struct FeedSessionComposition: Hashable, Sendable {
    public let edition: EditionSnapshot
    public let cards: [PublishedCardRecord]

    public init(edition: EditionSnapshot, cards: [PublishedCardRecord]) {
        self.edition = edition
        self.cards = cards
    }
}

/// The durable user-action path (ADR-004, plan §5.2). The session never writes `user.sqlite` itself.
public protocol FeedSessionUserActions: Sendable {
    func setBookmarked(
        cardID: PublicationCardID,
        wanted: Bool,
        operationID: String
    ) async throws -> FeedSessionUserState

    /// Marks one card read, durably and idempotently, and answers the state it confirmed.
    ///
    /// Read is absolute the way a bookmark's `wanted` is — there is no toggle to repeat — and the
    /// operation id is what makes a retry safe and what the `read` fact is keyed by (ADR-007 D5/D7).
    /// The card identity is never a runtime id: the app's port maps it onto the subject the durable
    /// stores are keyed by (ADR-004 D7).
    func setRead(
        cardID: PublicationCardID,
        operationID: String
    ) async throws -> FeedSessionUserState
}

/// The confirmed state of one card after a durable action.
public struct FeedSessionUserState: Hashable, Sendable {
    public let cardID: PublicationCardID
    public let bookmarked: Bool
    public let read: Bool
    public let operationID: String

    public init(cardID: PublicationCardID, bookmarked: Bool, read: Bool, operationID: String) {
        self.cardID = cardID
        self.bookmarked = bookmarked
        self.read = read
        self.operationID = operationID
    }
}

/// Counters for observability (plan §16). Counts and sizes only: never content, never a URL.
public struct FeedSessionStatistics: Hashable, Sendable {
    public var snapshotsPublished: Int = 0
    public var restores: Int = 0
    public var restoreRefusals: Int = 0
    public var compositions: Int = 0
    public var compositionFailures: Int = 0
    public var pagesRead: Int = 0
    public var replenishmentsScheduled: Int = 0
    public var checkpointsWritten: Int = 0
    public var exposureFactsPersisted: Int = 0
    public var exposureReplays: Int = 0
    public var exposureFlushes: Int = 0
    public var exposureFlushFailures: Int = 0
    public var exposureFactsDropped: Int = 0
    public var cancelledTasks: Int = 0
    public var pinReleases: Int = 0
    public var staleEffectsDiscarded: Int = 0
}

public actor FeedSession {
    private var state: FeedSessionState
    private let repository: PublicationRepository
    private let checkpoints: SessionCheckpointStore
    private let facts: ExposureFactStore
    private let composer: any FeedSessionComposer
    private let userActions: any FeedSessionUserActions
    private let clock: any MonotonicClock
    private let editorialClock: any EditorialClock
    private let exposureConfiguration: ExposureTracker.Configuration
    private let pageSize: Int
    private let unconfirmedFactLimit: Int
    /// Where a refused restore writes the failing input it can name. `nil` in a composition with no
    /// diagnostic directory, which is every test and the shadow lane.
    private let failureCapture: (any FailureSeedCapturing)?

    private var started = false
    private var closed = false
    private var latest: FeedPresentationSnapshot?
    private var continuations: [UUID: AsyncStream<FeedPresentationSnapshot>.Continuation] = [:]
    private var tasks: [FeedSessionOperationID: Task<Void, Never>] = [:]
    private var tracker: ExposureTracker?
    private var unconfirmed: [ExposureFact] = []
    private var unconfirmedPolicy: ExposurePolicy?
    /// The editions this session has presented. A flush may name the edition the interval happened in,
    /// so a successor taking over must not invalidate the *closing* facts of the edition it replaced
    /// (ADR-007 D11 rejects a foreign edition, not the one this session was showing a moment ago).
    private var presentedEditions: Set<EditionID> = []
    private var statistics = FeedSessionStatistics()
    /// How this launch started, recorded by the first restore of the session (plan §16).
    private var startup: StartupReport?

    public init(
        state: FeedSessionState,
        repository: PublicationRepository,
        checkpoints: SessionCheckpointStore,
        facts: ExposureFactStore,
        composer: any FeedSessionComposer,
        userActions: any FeedSessionUserActions,
        clock: any MonotonicClock,
        editorialClock: any EditorialClock,
        exposureConfiguration: ExposureTracker.Configuration = .baseline,
        pageSize: Int = 24,
        failureCapture: (any FailureSeedCapturing)? = nil
    ) {
        self.state = state
        self.repository = repository
        self.checkpoints = checkpoints
        self.facts = facts
        self.composer = composer
        self.userActions = userActions
        self.clock = clock
        self.editorialClock = editorialClock
        self.exposureConfiguration = exposureConfiguration
        self.pageSize = max(1, pageSize)
        self.unconfirmedFactLimit = max(1, exposureConfiguration.policy.flushFactCount) * 4
        self.failureCapture = failureCapture
    }

    // MARK: - Lifecycle

    /// Opens the session: it restores the local checkpoint and the stored edition, and only asks for a
    /// composition when there is nothing compatible to show.
    @discardableResult
    public func start() async -> FeedPresentationSnapshot? {
        guard !started, !closed else { return latest }
        started = true
        await dispatch(.opened, awaitingWork: true)
        return latest
    }

    /// Ends the session: intervals close, unconfirmed facts are flushed, tasks are cancelled, pins are
    /// released and the snapshot streams finish (plan §11).
    public func teardown() async {
        guard !closed else { return }
        await dispatch(.consumerClosed, awaitingWork: true)
        closed = true
        for task in tasks.values {
            task.cancel()
            statistics.cancelledTasks += 1
        }
        tasks.removeAll()
        forceTrackerFlush()
        forceUnconfirmedFlush()
        tracker = nil
        finishStreams()
    }

    // MARK: - Intents and events

    public func send(_ intent: FeedSessionIntent) async {
        guard !closed else { return }
        await dispatch(.intent(intent), awaitingWork: false)
    }

    /// A Dynamic Type, rotation or locale change: materialization only (ADR-002 D7).
    public func renderEnvironmentChanged(_ environment: RenderEnvironmentRevision) async {
        guard !closed else { return }
        await dispatch(.renderEnvironmentChanged(environment), awaitingWork: false)
    }

    /// A passive catalog, binding or endpoint change. It never swaps the visible edition.
    public func catalogChangedPassively() async {
        guard !closed else { return }
        await dispatch(.passiveCatalogChange, awaitingWork: false)
    }

    public func lifecycleChanged(_ lifecycle: FeedSessionLifecycle) async {
        guard !closed else { return }
        await dispatch(.lifecycle(lifecycle), awaitingWork: false)
    }

    /// Waits for the work this session spawned, so a caller (or a test) can observe a settled state
    /// without sleeping. Bounded: each pass awaits the tasks that existed when it started.
    public func drainPendingWork(passes: Int = 8) async {
        for _ in 0..<max(1, passes) {
            let pending = Array(tasks.values)
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }

    // MARK: - Observation

    public func currentSnapshot() -> FeedPresentationSnapshot? { latest }

    public func currentState() -> FeedSessionState { state }

    public func currentStatistics() -> FeedSessionStatistics { statistics }

    /// How this launch started, or `nil` before the session opened.
    ///
    /// This is the classification §16 requires: a run with no compatible edition is `.coldRecovery`,
    /// never a member of the warm-start distribution.
    public func currentStartupReport() -> StartupReport? { startup }

    /// The snapshot stream: a bounded latest-state buffer, never a queue. Durable intents travel on
    /// their own path (`send`), which is why dropping an intermediate snapshot cannot lose an action.
    public func snapshots() -> AsyncStream<FeedPresentationSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            if let latest { continuation.yield(latest) }
            guard !closed else {
                continuation.finish()
                return
            }
            let token = UUID()
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    private func removeContinuation(_ token: UUID) {
        continuations[token] = nil
    }

    private func finishStreams() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    // MARK: - Reduction

    private func dispatch(_ event: FeedSessionEvent, awaitingWork: Bool) async {
        let (next, effects) = FeedSessionReducer.reduce(state: state, event: event)
        state = next
        if let edition = state.visibleEdition { presentedEditions.insert(edition) }
        for effect in effects {
            guard !effect.isStale(against: state.stamp) else {
                statistics.staleEffectsDiscarded += 1
                continue
            }
            await apply(effect, awaitingWork: awaitingWork)
        }
    }

    private func apply(_ effect: FeedSessionEffect, awaitingWork: Bool) async {
        switch effect.kind {
        case let .restore(context):
            await performRestore(context: context, operation: effect.operation)

        case let .compose(context, reason, _):
            if awaitingWork {
                await performCompose(context: context, reason: reason, operation: effect.operation)
            } else {
                spawn(effect.operation) { await self.performCompose(context: context, reason: reason, operation: effect.operation) }
            }

        case let .emitSnapshot(snapshot):
            publish(snapshot)

        case let .persistCheckpoint(checkpoint):
            persist(checkpoint)

        // The effect's edition is the one that was visible; the tracker closes the intervals it owns
        // and a successor edition swaps in when the next observation arrives, so it is not re-stated.
        case let .closeExposureIntervals(_, reason):
            closeIntervals(reason: reason)

        case let .trackViewport(observation):
            mutateTracker { $0.submitViewport(observation) }

        case let .trackCenterCrossed(cardID, direction):
            mutateTracker { $0.centerCrossed(cardID: cardID, direction: direction) }

        case let .trackOpened(cardID):
            mutateTracker { $0.opened(cardID: cardID) }

        case let .trackEvictions(cardIDs):
            mutateTracker { $0.cardsEvicted(cardIDs) }

        case let .recordBookmark(operationID, cardID, wanted):
            if awaitingWork {
                await performBookmark(cardID: cardID, wanted: wanted, operationID: operationID)
            } else {
                spawn(effect.operation) { await self.performBookmark(cardID: cardID, wanted: wanted, operationID: operationID) }
            }

        case let .recordRead(operationID, cardID):
            if awaitingWork {
                await performRead(cardID: cardID, operationID: operationID)
            } else {
                spawn(effect.operation) { await self.performRead(cardID: cardID, operationID: operationID) }
            }

        case let .replenish(context, fromOrdinal):
            statistics.replenishmentsScheduled += 1
            if awaitingWork {
                await performPage(context: context, fromOrdinal: fromOrdinal, operation: effect.operation)
            } else {
                spawn(effect.operation) { await self.performPage(context: context, fromOrdinal: fromOrdinal, operation: effect.operation) }
            }

        case let .releasePins(editions):
            guard !editions.isEmpty else { return }
            statistics.pinReleases += 1
            if awaitingWork {
                await composer.releaseResources(for: editions)
            } else {
                let composer = self.composer
                spawn(effect.operation) { await composer.releaseResources(for: editions) }
            }
        }
    }

    /// Runs one effect in a task the session owns and forgets it when it settles.
    ///
    /// Cancellation is an optimisation, not the guarantee: the reducer still validates the stamp and
    /// the operation id, because a cancelled task may already be inside its effect (ADR-006 D14).
    private func spawn(
        _ operation: FeedSessionOperationID,
        _ body: @escaping @Sendable () async -> Void
    ) {
        tasks[operation]?.cancel()
        let task = Task { [weak self] in
            await body()
            await self?.forget(operation)
        }
        tasks[operation] = task
    }

    private func forget(_ operation: FeedSessionOperationID) {
        tasks[operation] = nil
    }

    // MARK: - Effects

    private func performRestore(context: ContextKey, operation: FeedSessionOperationID) async {
        let checkpoint = try? checkpoints.load(context: context)
        do {
            switch try repository.restore(context: context) {
            case let .restored(edition, cards):
                statistics.restores += 1
                startup = .warm(edition: edition, cardCount: cards.count)
                let anchor = checkpoint?.anchor
                await dispatch(
                    .restored(
                        operation: operation,
                        context: context,
                        edition: edition,
                        cards: bounded(cards, around: anchor?.absoluteOrdinal),
                        checkpoint: anchor?.editionID == edition.editionID ? anchor : nil
                    ),
                    awaitingWork: true
                )
            case .noEdition:
                statistics.restoreRefusals += 1
                startup = .cold("no compatible edition is stored for this context")
                await dispatch(
                    .restoreUnavailable(operation: operation, context: context, reason: .noEdition),
                    awaitingWork: true
                )
            case let .unsupportedPublicationSchemaVersion(version):
                statistics.restoreRefusals += 1
                startup = .cold(
                    "the stored edition's publication schema \(version) is outside this build's "
                        + "supported set"
                )
                // The refused edition is the active one for this context, and its seed is what its
                // composition ran under: the artifact names both, so the refusal can be re-run.
                captureRestoreRefusal(
                    context: context,
                    editionID: (try? repository.activeEdition(for: context))?.editionID,
                    cardIdentities: [],
                    observed: FailureSeedReplay.kind(of: .unsupportedPublicationSchemaVersion(version)),
                    detail: "the stored edition's publication schema \(version) is outside this build's "
                        + "supported set \(PublicationSchema.supportedVersions.sorted())"
                )
                await dispatch(
                    .restoreUnavailable(
                        operation: operation,
                        context: context,
                        reason: .incompatiblePublicationSchema(version)
                    ),
                    awaitingWork: true
                )
            case let .payloadCorrupted(cardID, reason):
                statistics.restoreRefusals += 1
                startup = .cold("the stored edition's payload no longer recomputes: \(reason)")
                captureRestoreRefusal(
                    context: context,
                    editionID: (try? repository.card(cardID))?.payload.editionID,
                    cardIdentities: ["\(cardID.rawValue)"],
                    observed: FailureSeedReplay.kind(of: .payloadCorrupted(cardID: cardID, reason: reason)),
                    detail: reason
                )
                await dispatch(
                    .restoreUnavailable(
                        operation: operation,
                        context: context,
                        reason: .payloadCorrupted(cardID: cardID, reason: reason)
                    ),
                    awaitingWork: true
                )
            }
        } catch {
            statistics.restoreRefusals += 1
            startup = .cold("the stored edition could not be read: \(error)")
            await dispatch(
                .restoreUnavailable(operation: operation, context: context, reason: .unreadable("\(error)")),
                awaitingWork: true
            )
        }
    }

    /// Writes the failing input of a refused restore, so the refusal can be re-run instead of
    /// reconstructed by hand (plan §15.1's property/replay class; baseline §8.11 records that the seed
    /// existed and nothing captured it).
    ///
    /// Recording is best effort on purpose: a diagnostic that turned a refusal into a thrown error
    /// would report the wrong failure, so a capture that cannot be written is dropped rather than
    /// propagated. The refusal itself travels to the caller unchanged.
    private func captureRestoreRefusal(
        context: ContextKey,
        editionID: EditionID?,
        cardIdentities: [String],
        observed: String,
        detail: String
    ) {
        guard let failureCapture, let editionID,
              let edition = try? repository.edition(editionID)
        else { return }
        let failure = CapturedFailure(
            check: .editionRestoreIsReproducible,
            observedAtMilliseconds: Int64((editorialClock.now.timeIntervalSince1970 * 1000).rounded()),
            databasePath: repository.location.directory.path,
            surface: context.surface.rawValue,
            scopeKey: context.scopeKey,
            planIdentity: context.planIdentity,
            editionID: editionID.rawValue,
            epoch: edition.epoch,
            seed: edition.seed,
            editorialRevision: edition.editorialRevision.digest,
            publicationSchemaVersion: edition.publicationSchemaVersion,
            cardIdentities: cardIdentities,
            expected: "restored",
            observed: observed,
            detail: detail
        )
        _ = try? failureCapture.capture(failure)
    }

    private func performCompose(
        context: ContextKey,
        reason: FeedSessionCompositionReason,
        operation: FeedSessionOperationID
    ) async {
        statistics.compositions += 1
        do {
            let composition = try await composer.compose(
                context: context,
                reason: reason,
                at: editorialClock.now
            )
            await dispatch(
                .composed(
                    operation: operation,
                    context: context,
                    edition: composition.edition,
                    cards: bounded(composition.cards, around: nil)
                ),
                awaitingWork: true
            )
        } catch {
            statistics.compositionFailures += 1
            await dispatch(
                .compositionFailed(operation: operation, context: context, reason: "\(error)"),
                awaitingWork: true
            )
        }
    }

    private func performPage(
        context: ContextKey,
        fromOrdinal: Int,
        operation: FeedSessionOperationID
    ) async {
        guard let edition = state.visibleEdition else { return }
        do {
            let cards = try repository.cards(in: edition)
                .filter { $0.payload.absoluteOrdinal >= fromOrdinal }
                .prefix(pageSize)
            statistics.pagesRead += 1
            await dispatch(
                .pageLoaded(
                    operation: operation,
                    context: context,
                    edition: edition,
                    cards: Array(cards),
                    fromOrdinal: fromOrdinal
                ),
                awaitingWork: true
            )
        } catch {
            // A local page that cannot be read leaves the window as it is; the next scroll retries.
            statistics.compositionFailures += 1
        }
    }

    private func performBookmark(
        cardID: PublicationCardID,
        wanted: Bool,
        operationID: String
    ) async {
        do {
            let confirmed = try await userActions.setBookmarked(
                cardID: cardID,
                wanted: wanted,
                operationID: operationID
            )
            await dispatch(
                .userStateChanged(
                    cardID: confirmed.cardID,
                    bookmarked: confirmed.bookmarked,
                    read: confirmed.read,
                    operationID: confirmed.operationID
                ),
                awaitingWork: true
            )
            mutateTracker { tracker in
                tracker.bookmarked(
                    cardID: confirmed.cardID,
                    wanted: confirmed.bookmarked,
                    operationID: confirmed.operationID
                )
            }
        } catch {
            // The durable intent stays unconfirmed: the UI keeps the previous state instead of
            // pretending success (plan §5.2).
            statistics.compositionFailures += 1
        }
    }

    /// One durable read intention, on the same path a bookmark takes (plan §5.2, ADR-007 D5/D7).
    ///
    /// The order is the bookmark's: the port writes the durable state and answers what it confirmed,
    /// the session adopts the confirmation and only then mirrors the fact into the tracker. A port that
    /// could not make it durable throws, and the session keeps the state it was showing and writes no
    /// fact — a `read` fact without a durable operation behind it would be exactly the invented history
    /// D7 forbids.
    private func performRead(
        cardID: PublicationCardID,
        operationID: String
    ) async {
        do {
            let confirmed = try await userActions.setRead(
                cardID: cardID,
                operationID: operationID
            )
            await dispatch(
                .userStateChanged(
                    cardID: confirmed.cardID,
                    bookmarked: confirmed.bookmarked,
                    read: confirmed.read,
                    operationID: confirmed.operationID
                ),
                awaitingWork: true
            )
            mutateTracker { tracker in
                tracker.read(cardID: confirmed.cardID, operationID: confirmed.operationID)
            }
        } catch {
            statistics.compositionFailures += 1
        }
    }

    private func publish(_ snapshot: FeedPresentationSnapshot) {
        guard snapshot.sessionStamp == state.stamp else { return }
        let alreadyPublished = latest.map {
            $0.sessionStamp == snapshot.sessionStamp && $0.sequence >= snapshot.sequence
        } ?? false
        guard !alreadyPublished else { return }
        latest = snapshot
        statistics.snapshotsPublished += 1
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func persist(_ checkpoint: SessionCheckpoint) {
        let stamped = SessionCheckpoint(
            context: checkpoint.context,
            editionID: checkpoint.editionID,
            anchor: checkpoint.anchor,
            renderEnvironmentRevision: checkpoint.renderEnvironmentRevision,
            policyVersion: checkpoint.policyVersion,
            updatedAtMs: clock.nowMillis()
        )
        do {
            if try checkpoints.save(stamped) {
                statistics.checkpointsWritten += 1
            }
        } catch {
            statistics.exposureFlushFailures += 1
        }
    }

    // MARK: - Exposure

    /// Mutates the tracker of the visible edition and flushes what the policy owes.
    ///
    /// The tracker is a value type, so the mutation has to happen on the stored property: reading it
    /// into a local and mutating the copy would silently discard every observation.
    private func mutateTracker(_ body: (inout ExposureTracker) -> Void) {
        guard let edition = state.visibleEdition else { return }
        var current = tracker ?? ExposureTracker(
            edition: edition,
            scope: state.historyScope,
            clock: clock,
            configuration: exposureConfiguration
        )
        if current.editionID != edition {
            current.swapEdition(to: edition)
            collect(&current, force: true)
        }
        body(&current)
        tracker = current
        collect(&current, force: false)
        tracker = current
    }

    private func closeIntervals(reason: ExposureCloseReason) {
        guard var current = tracker else { return }
        current.endIntervals(reason: reason)
        collect(&current, force: true)
        tracker = reason == .sessionEnd ? nil : current
    }

    private func forceTrackerFlush() {
        guard var current = tracker else { return }
        collect(&current, force: true)
        tracker = current
    }

    /// Moves the batch the tracker owes into the unconfirmed buffer, then tries to write it.
    private func collect(_ tracker: inout ExposureTracker, force: Bool) {
        let batch = force ? tracker.drain() : tracker.drainAtMilestone()
        guard !batch.isEmpty else { return }
        unconfirmedPolicy = tracker.policy
        unconfirmed.append(contentsOf: batch)
        if unconfirmed.count > unconfirmedFactLimit {
            let overflow = unconfirmed.count - unconfirmedFactLimit
            unconfirmed.removeFirst(overflow)
            statistics.exposureFactsDropped += overflow
        }
        attemptFlush()
    }

    private func forceUnconfirmedFlush() {
        attemptFlush()
    }

    /// Writes every unconfirmed fact in one transaction.
    ///
    /// A failed write keeps the facts for the next attempt instead of losing them, bounded by four
    /// flush cycles: past that the oldest are dropped and counted, because unbounded retention of
    /// unconfirmed facts is the memory leak this policy exists to prevent (ADR-007 D9).
    private func attemptFlush() {
        guard !unconfirmed.isEmpty, let policy = unconfirmedPolicy else { return }
        let guardContext = ExposureFlushGuard(
            sessionStamp: state.stamp,
            currentSessionStamp: state.stamp,
            acceptedEditions: presentedEditions
        )
        do {
            let receipt = try facts.append(
                unconfirmed,
                policy: policy,
                wallClockMs: PublishedCardPayload.milliseconds(editorialClock.now),
                guard: guardContext
            )
            statistics.exposureFlushes += 1
            statistics.exposureFactsPersisted += receipt.insertedCount
            statistics.exposureReplays += receipt.replayCount
            if receipt.isRejected {
                statistics.exposureFactsDropped += unconfirmed.count
            }
            unconfirmed.removeAll()
            if unconfirmed.isEmpty { unconfirmedPolicy = nil }
        } catch {
            statistics.exposureFlushFailures += 1
        }
    }

    // MARK: - Bounds

    /// The cards a restore or a composition hands to the reducer: the anchor's neighbourhood, never the
    /// whole edition.
    ///
    /// The window can only retain `maximumReferences` rows and fills by distance from the anchor, so an
    /// ordinal slice twice that wide is sufficient — and it keeps a large edition from allocating
    /// thousands of materials that the window would throw away immediately.
    private func bounded(_ cards: [PublishedCardRecord], around ordinal: Int?) -> [PublishedCardRecord] {
        let limit = state.window.configuration.maximumReferences * 2
        guard cards.count > limit else { return cards }
        let center = ordinal ?? cards.first?.payload.absoluteOrdinal ?? 0
        return Array(
            cards
                .sorted {
                    let left = abs($0.payload.absoluteOrdinal - center)
                    let right = abs($1.payload.absoluteOrdinal - center)
                    if left != right { return left < right }
                    return $0.payload.absoluteOrdinal < $1.payload.absoluteOrdinal
                }
                .prefix(limit)
                .sorted { $0.payload.absoluteOrdinal < $1.payload.absoluteOrdinal }
        )
    }
}
