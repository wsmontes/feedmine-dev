import XCTest
import Foundation
import os
@testable import FeedDomain
@testable import FeedRuntime
@testable import FeedStorage

/// Shared doubles and fixtures for the PR-07 session, window and exposure tests.
///
/// Time is injected everywhere (ADR-007 D15) and nothing here sleeps: a test states the instant it
/// wants the tracker to see. The mutable doubles use the same lock box as the media spies, so they are
/// `Sendable` without an escape hatch.

/// A monotonic clock a test advances by hand.
final class TestMonotonicClock: MonotonicClock, Sendable {
    struct State: Sendable {
        var millis: Int64
        var bootSessionID: String
    }

    private let state: OSAllocatedUnfairLock<State>

    init(startMillis: Int64 = 0, bootSessionID: String = "boot-1") {
        self.state = OSAllocatedUnfairLock(initialState: State(millis: startMillis, bootSessionID: bootSessionID))
    }

    func nowMillis() -> Int64 { state.withLock { $0.millis } }
    var bootSessionID: String { state.withLock { $0.bootSessionID } }

    /// Moves the clock forward and returns the new instant.
    @discardableResult
    func advance(_ milliseconds: Int64) -> Int64 {
        state.withLock {
            $0.millis += milliseconds
            return $0.millis
        }
    }

    /// Simulates a device reboot: the boot session changes, the reading resets.
    func reboot(to bootSessionID: String, atMillis millis: Int64 = 0) {
        state.withLock {
            $0.bootSessionID = bootSessionID
            $0.millis = millis
        }
    }
}

/// A fixed wall clock, used only for the diagnostic `wall_clock_ms` column.
struct TestEditorialClock: EditorialClock {
    let now: Date
}

enum SessionFixture {
    static let instant = Date(timeIntervalSince1970: 1_700_000_000)

    static func revision(_ tag: String) throws -> EditorialRevision {
        let hex = tag.utf8.map { String(format: "%02x", $0) }.joined()
        return try EditorialRevision(
            schemeVersion: EditorialRevision.currentSchemeVersion,
            digest: String((hex + String(repeating: "0", count: 64)).prefix(64))
        )
    }

    static func context(_ scopeKey: String = "main") throws -> ContextKey {
        try ContextKey(surface: .main, scopeKey: scopeKey, planIdentity: "MainFeedPlan")
    }

    static func renderEnvironment(
        dynamicType: String = "large",
        widthClass: String = "compact",
        scale: Int = 3
    ) throws -> RenderEnvironmentRevision {
        try RenderEnvironmentRevision(
            layoutWidthClass: widthClass,
            dynamicTypeSize: dynamicType,
            localeIdentifier: "pt_BR",
            textDirection: "ltr",
            displayScale: scale
        )
    }

    /// An edition value with no database behind it: the reducer is pure, so its inputs are values.
    static func edition(
        id: Int64,
        context: ContextKey,
        revisionTag: String = "revision-a",
        epoch: Int64 = 1,
        state: EditionState = .active
    ) throws -> EditionSnapshot {
        EditionSnapshot(
            editionID: try EditionID(id),
            contextKey: context.canonicalSerialization,
            editorialRevision: try revision(revisionTag),
            publicationSchemaVersion: PublicationSchema.currentVersion,
            epoch: epoch,
            seed: Data("seed-\(id)".utf8),
            state: state,
            successorOfEditionID: nil,
            tail: EditionTail(segmentOrdinal: 0, absoluteOrdinal: 0, version: 1),
            createdAt: instant,
            activatedAt: instant
        )
    }

    /// `count` frozen cards for one edition, ordinals starting at `firstOrdinal`.
    static func cards(
        edition: EditionSnapshot,
        count: Int,
        firstOrdinal: Int = 0,
        media: PublishedMediaSet = .none,
        titlePrefix: String = "Card"
    ) throws -> [PublishedCardRecord] {
        try (0..<count).map { index in
            let ordinal = firstOrdinal + index
            let cardID = try PublicationCardID(Int64(ordinal + 1000))
            let frozen = PublishedCardPayload.Frozen(
                editionID: edition.editionID,
                segmentOrdinal: 0,
                absoluteOrdinal: ordinal,
                origin: PublishedOrigin(
                    originRecordID: try OriginRecordID(Int64(ordinal + 1)),
                    originRevisionID: try OriginRevisionID(Int64(ordinal + 1)),
                    sourceID: nil,
                    providerID: nil,
                    sourceDisplayName: "Source",
                    providerDisplayName: nil
                ),
                title: "\(titlePrefix) \(ordinal)",
                primaryText: "Excerpt \(ordinal)",
                publishedAt: instant,
                publishedAtKind: .authored,
                observationAt: instant,
                media: media,
                primaryAction: nil,
                interactionSummary: nil,
                renderContract: RenderContract.resolved(media: media),
                editorialRevision: edition.editorialRevision,
                publicationSchemaVersion: edition.publicationSchemaVersion
            )
            let payload = PublishedCardPayload(cardID: cardID, frozen: frozen)
            return PublishedCardRecord(
                payload: payload,
                segmentID: try SegmentID(1),
                payloadDigest: payload.frozenDigest()
            )
        }
    }

    /// A card with one committed primary asset: the layout that needs bytes, and therefore the one
    /// whose decoded byte estimate is not just its text.
    static func heroMedia() -> PublishedMediaSet {
        PublishedMediaSet(
            primary: PublishedMediaRef(
                contentDigest: String(repeating: "a", count: 64),
                recipeVersion: 1,
                pixelWidth: 1200,
                pixelHeight: 800,
                mimeType: "image/jpeg"
            ),
            alternates: [],
            placeholder: nil
        )
    }

    /// The presentation of one frozen card, as a material the window can hold.
    static func reference(
        of record: PublishedCardRecord,
        height: Double = 100,
        bytes: Int = 1000
    ) -> FeedWindowReference {
        FeedWindowReference(
            cardID: record.payload.cardID,
            absoluteOrdinal: record.payload.absoluteOrdinal,
            editionID: record.payload.editionID,
            estimatedHeight: height,
            decodedByteEstimate: bytes
        )
    }

    static func observation(
        _ cardID: PublicationCardID,
        fraction: Double,
        edge: ViewportObservation.Edge,
        direction: Int = 0
    ) throws -> ViewportObservation {
        try ViewportObservation(
            cardID: cardID,
            visibleFraction: fraction,
            edge: edge,
            direction: direction
        )
    }
}

/// Records the composition path. Every call is part of the proof that a warm restore does not select.
final class SpySessionComposer: FeedSessionComposer, Sendable {
    struct Log: Sendable {
        var composeCalls: [ContextKey] = []
        var reasons: [FeedSessionCompositionReason] = []
        var releaseCalls: [[EditionID]] = []
    }

    private let log = OSAllocatedUnfairLock(initialState: Log())
    private let compositions: OSAllocatedUnfairLock<[FeedSessionComposition]>

    init(compositions: [FeedSessionComposition] = []) {
        self.compositions = OSAllocatedUnfairLock(initialState: compositions)
    }

    /// Adds one more composition to the script, so a test can build the second answer after the first
    /// one was already consumed.
    func script(_ composition: FeedSessionComposition) {
        compositions.withLock { $0.append(composition) }
    }

    var composeCallCount: Int { log.withLock { $0.composeCalls.count } }
    var composeCalls: [ContextKey] { log.withLock { $0.composeCalls } }
    var reasons: [FeedSessionCompositionReason] { log.withLock { $0.reasons } }
    var releaseCalls: [[EditionID]] { log.withLock { $0.releaseCalls } }
    var totalCallCount: Int { log.withLock { $0.composeCalls.count + $0.releaseCalls.count } }

    func compose(
        context: ContextKey,
        reason: FeedSessionCompositionReason,
        at: Date
    ) async throws -> FeedSessionComposition {
        let next = compositions.withLock { script -> FeedSessionComposition? in
            guard script.count > 1 else { return script.first }
            return script.removeFirst()
        }
        log.withLock {
            $0.composeCalls.append(context)
            $0.reasons.append(reason)
        }
        guard let next else { throw FeedSessionComposerSpyError.noScriptedComposition }
        return next
    }

    func releaseResources(for editions: [EditionID]) async {
        log.withLock { $0.releaseCalls.append(editions) }
    }
}

enum FeedSessionComposerSpyError: Error, Equatable, Sendable {
    case noScriptedComposition
}

/// Records the durable user-state path.
final class SpyUserActions: FeedSessionUserActions, Sendable {
    struct Log: Sendable {
        var calls: [(cardID: PublicationCardID, wanted: Bool, operationID: String)] = []
    }

    struct ReadCall: Equatable, Sendable {
        let cardID: PublicationCardID
        let operationID: String
    }

    private let log = OSAllocatedUnfairLock(initialState: Log())
    private let readLog = OSAllocatedUnfairLock(initialState: [ReadCall]())
    private let readState: Bool
    private let bookmarkState: Bool

    /// - Parameter read: what the bookmark path is told the legacy row says, which is the answer a
    ///   bookmark confirmation carries back. The read path confirms `true` for what it was asked to set:
    ///   there is nothing else this port could honestly answer for an absolute mark.
    /// - Parameter bookmarked: what a read confirmation carries back for the card's bookmark state.
    init(read: Bool = false, bookmarked: Bool = false) {
        self.readState = read
        self.bookmarkState = bookmarked
    }

    var callCount: Int { log.withLock { $0.calls.count } }

    var readCalls: [ReadCall] { readLog.withLock { $0 } }

    func setBookmarked(
        cardID: PublicationCardID,
        wanted: Bool,
        operationID: String
    ) async throws -> FeedSessionUserState {
        log.withLock { $0.calls.append((cardID, wanted, operationID)) }
        return FeedSessionUserState(
            cardID: cardID,
            bookmarked: wanted,
            read: readState,
            operationID: operationID
        )
    }

    func setRead(
        cardID: PublicationCardID,
        operationID: String
    ) async throws -> FeedSessionUserState {
        readLog.withLock { $0.append(ReadCall(cardID: cardID, operationID: operationID)) }
        return FeedSessionUserState(
            cardID: cardID,
            bookmarked: bookmarkState,
            read: true,
            operationID: operationID
        )
    }
}
