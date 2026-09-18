import Foundation

/// The publication log's identity and append contract (ADR-001 D1–D3, D9, ADR-006 D14).
///
/// `PublicationCoordinator` is the only writer of editions, segments, cards and asset references.
/// Everything a commit must validate travels in `PublicationToken` as a *value*: the edition it
/// appends to, the publication epoch, the editorial revision the composition was built under and the
/// tail it expects to find. Nothing here reads a clock, a database or the environment.

/// Identifier of one immutable segment of an edition.
///
/// Allocated by the runtime in the positive `Int64` range with zero reserved (ADR-003 D3): a value
/// outside that range is a corrupted database, never a wrapped identifier.
public struct SegmentID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue > 0 else { throw RuntimeIDError.nonPositiveRowID(Self.self, rawValue) }
        self.rawValue = rawValue
    }

    public var description: String { "segment:\(rawValue)" }
}

/// `PublicationSchemaVersion` and the versions this build can read (ADR-001 D9, INV-13).
///
/// It is independent of `SelectionContract.schemaVersion`, of connector and checkpoint versions and
/// of every editorial revision: a restore that meets a version outside this set fails in a controlled
/// way and asks for a new edition instead of interpreting an unknown payload permissively.
public enum PublicationSchema {
    public static let currentVersion = 1
    public static let supportedVersions: Set<Int> = [1]

    public static func isSupported(_ version: Int) -> Bool {
        supportedVersions.contains(version)
    }
}

/// The tail of an edition: what a commit compares and what it advances (ADR-001 D3).
///
/// `segmentOrdinal` and `absoluteOrdinal` are `-1` while the edition has no segment, which is the
/// state a freshly created draft edition is in. `version` is `feed_edition.version`, the counter the
/// compare-and-swap is written against; it is not derived from the ordinals, so two commits that
/// happen to compute the same ordinals still cannot both win.
public struct EditionTail: Hashable, Sendable, CustomStringConvertible {
    /// The last committed `segment_ordinal`, or `-1`.
    public let segmentOrdinal: Int
    /// The last committed `absolute_ordinal`, or `-1`.
    public let absoluteOrdinal: Int
    /// `feed_edition.version`; `0` for an edition with no segment.
    public let version: Int64

    public static let empty = EditionTail(segmentOrdinal: -1, absoluteOrdinal: -1, version: 0)

    /// The ordinal the next segment must start at.
    public var nextAbsoluteOrdinal: Int { absoluteOrdinal + 1 }

    /// The ordinal the next segment carries.
    public var nextSegmentOrdinal: Int { segmentOrdinal + 1 }

    public init(segmentOrdinal: Int, absoluteOrdinal: Int, version: Int64) {
        self.segmentOrdinal = segmentOrdinal
        self.absoluteOrdinal = absoluteOrdinal
        self.version = version
    }

    public var description: String {
        "tail(segment:\(segmentOrdinal),absolute:\(absoluteOrdinal),version:\(version))"
    }
}

/// What a composition captured before it went to do its long work (ADR-001 D3, ADR-006 D14).
///
/// The token names the exact edition, epoch, editorial revision and tail a commit must still find.
/// It is deliberately a plain value: a recovered process, another coordinator instance or a second
/// context may hold a stale one, and the commit has to reject it rather than renumber it.
public struct PublicationToken: Hashable, Sendable, CustomStringConvertible {
    public let editionID: EditionID
    /// The publication epoch of the edition. A result produced under another epoch is discarded.
    public let epoch: Int64
    /// The editorial revision the composition was built under (ADR-002 D2).
    public let editorialRevision: EditorialRevision
    public let tail: EditionTail

    public init(
        editionID: EditionID,
        epoch: Int64,
        editorialRevision: EditorialRevision,
        tail: EditionTail
    ) {
        self.editionID = editionID
        self.epoch = epoch
        self.editorialRevision = editorialRevision
        self.tail = tail
    }

    /// The segment ordinal the composition will append (ADR-001's `expectedTailSegmentOrdinal`).
    public var expectedTailSegmentOrdinal: Int { tail.segmentOrdinal }

    /// The tail counter the composition was captured at (ADR-001's `expectedEditionVersion`).
    public var expectedEditionVersion: Int64 { tail.version }

    public var description: String {
        "token(\(editionID),epoch:\(epoch),rev:\(editorialRevision.digest.prefix(8)),\(tail))"
    }
}

/// The state an edition can hold (ADR-001's `feed_edition.state`).
///
/// `superseded` is the previous visible edition after a successor took over, and `purged` records
/// that an authorized purge removed its content: neither is ever produced by retention on its own.
public enum EditionState: String, Hashable, Sendable, CaseIterable {
    case draft
    case active
    case superseded
    case purged

    /// Only a `draft` may commit the segment that activates it, and only an `active` edition may
    /// append further segments (ADR-001 D7).
    public var acceptsAppend: Bool { self == .draft || self == .active }
}

/// Why a publication commit was refused (ADR-001's `PublicationFailure`).
///
/// Every case names the invariant that refused it, and none of them is recoverable by retrying the
/// same token: the writer re-reads the tail and recomposes (D3).
public enum PublicationFailure: Error, Equatable, Sendable {
    case editionNotFound(EditionID)
    case editionNotActive(EditionID, state: EditionState)
    /// The token's publication epoch is no longer the edition's (ADR-002 D12: a stale epoch result is
    /// discarded, never applied).
    case staleEpoch(expected: Int64, actual: Int64)
    /// The edition's editorial revision moved under the composition (ADR-002 D11b).
    case editorialRevisionChanged(expected: String, actual: String)
    /// Another commit moved the tail first: at most one writer wins per tail (INV-5).
    case tailMismatch(expected: EditionTail, actual: EditionTail)
    /// A pinned revision lost hard eligibility between composition and commit (ADR-002 D11c).
    case eligibilityRevoked(originRevisionID: OriginRevisionID)
    case assetCommitFailed(String)
    case unsupportedPublicationSchemaVersion(Int)
    /// A composition with no card publishes nothing and activates nothing.
    case emptySequence(EditionID)
    /// The commit did not happen for a reason outside the composition's control — a storage failure,
    /// or a fault the transaction reported — and the transaction wrote nothing. The previous edition
    /// stays visible; the composition is discarded, never renumbered. Retrying is allowed only for a
    /// storage failure, and only after re-reading the tail (ADR-006 D10).
    case storageFailure(String)
    /// The engine refused the composition before touching the database.
    case invalidComposition(String)
}

extension PublicationFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .editionNotFound(edition): return "editionNotFound(\(edition))"
        case let .editionNotActive(edition, state): return "editionNotActive(\(edition),\(state.rawValue))"
        case let .staleEpoch(expected, actual): return "staleEpoch(expected:\(expected),actual:\(actual))"
        case let .editorialRevisionChanged(expected, actual):
            return "editorialRevisionChanged(\(expected.prefix(8))→\(actual.prefix(8)))"
        case let .tailMismatch(expected, actual): return "tailMismatch(\(expected)→\(actual))"
        case let .eligibilityRevoked(revision): return "eligibilityRevoked(\(revision))"
        case let .assetCommitFailed(reason): return "assetCommitFailed(\(reason))"
        case let .unsupportedPublicationSchemaVersion(version):
            return "unsupportedPublicationSchemaVersion(\(version))"
        case let .emptySequence(edition): return "emptySequence(\(edition))"
        case let .storageFailure(reason): return "storageFailure(\(reason))"
        case let .invalidComposition(reason): return "invalidComposition(\(reason))"
        }
    }
}
