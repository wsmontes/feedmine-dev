import Foundation

/// Opaque runtime identifiers.
///
/// Deliberately distinct from the app target's existing `SourceID: UInt32`
/// (`feedmine/FeedEngine/Identities.swift`), which is a truncated SHA-256 of the canonical URL.
/// Bridges must alias that type explicitly (`CatalogSourceID`) instead of converting values
/// positionally (plan §5.1, ADR-003).
///
/// All runtime identifiers are allocated locally and persisted. They are never derived from
/// external identity, and they never encode an ordering that a caller may rely on.

/// Identifier of an editorial source. Durable within one runtime database.
public struct SourceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    /// Fails for the reserved zero value so "no source" cannot be confused with a real one.
    public init(_ rawValue: UInt64) throws {
        guard rawValue != 0 else { throw RuntimeIDError.reservedZero(Self.self) }
        self.rawValue = rawValue
    }

    public var description: String { "source:\(rawValue)" }
}

/// Identifier of a provider/attribution entity. Distinct from `SourceID` by decision D3 of
/// ADR-003: one source can carry several providers, and one provider can appear in sources it
/// does not own.
public struct ProviderID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) throws {
        guard rawValue != 0 else { throw RuntimeIDError.reservedZero(Self.self) }
        self.rawValue = rawValue
    }

    public var description: String { "provider:\(rawValue)" }
}

/// Identifier of the canonical logical object (one external object, whichever revision).
public struct OriginRecordID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue > 0 else { throw RuntimeIDError.nonPositiveRowID(Self.self, rawValue) }
        self.rawValue = rawValue
    }

    public var description: String { "origin:\(rawValue)" }
}

/// Identifier of one immutable representation of an `OriginRecordID`.
public struct OriginRevisionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue > 0 else { throw RuntimeIDError.nonPositiveRowID(Self.self, rawValue) }
        self.rawValue = rawValue
    }

    public var description: String { "revision:\(rawValue)" }
}

/// Identifier of a published occurrence. This is the SwiftUI identity of a card (ADR-001);
/// it is not the canonical content identity and not a bookmark key.
public struct PublicationCardID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue > 0 else { throw RuntimeIDError.nonPositiveRowID(Self.self, rawValue) }
        self.rawValue = rawValue
    }

    public var description: String { "card:\(rawValue)" }
}

/// Identifier of a published edition (one immutable composition for one context).
public struct EditionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue > 0 else { throw RuntimeIDError.nonPositiveRowID(Self.self, rawValue) }
        self.rawValue = rawValue
    }

    public var description: String { "edition:\(rawValue)" }
}

public enum RuntimeIDError: Error, Equatable, Sendable {
    case reservedZero(Any.Type)
    case nonPositiveRowID(Any.Type, Int64)
    /// A runtime identifier space is exhausted. Wrapping would hand out `0`, which is reserved, or a
    /// reused identity, so allocation fails instead (ADR-003 D3).
    case identifierSpaceExhausted(Int64)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.reservedZero(l), .reservedZero(r)):
            return ObjectIdentifier(l) == ObjectIdentifier(r)
        case let (.nonPositiveRowID(l1, l2), .nonPositiveRowID(r1, r2)):
            return ObjectIdentifier(l1) == ObjectIdentifier(r1) && l2 == r2
        case let (.identifierSpaceExhausted(l), .identifierSpaceExhausted(r)):
            return l == r
        default:
            return false
        }
    }
}

/// Checked conversion from a SQLite `Int64` column into the runtime's row-identifier range.
///
/// The runtime allocates in the positive `Int64` range with zero reserved (ADR-003 D3). A value
/// outside that range is a corrupted database or a foreign key from another store, and both must
/// surface as an error rather than as a wrapped identifier.
public enum RuntimeRowID {
    public static let reserved: Int64 = 0

    public static func checked(_ raw: Int64) throws -> Int64 {
        guard raw > reserved else { throw RuntimeIDError.nonPositiveRowID(Int64.self, raw) }
        return raw
    }
}
