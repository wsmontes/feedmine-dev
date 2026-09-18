import Foundation

/// External identity: opaque, scoped and compared in full (ADR-003 D8–D10, D16).
///
/// The core never interprets an external key. A key lives in the space
/// `(connectorNamespace, scopeKey, keyKind)` and uniqueness is decided on that space plus the
/// **full** key bytes. The 128-bit digest exists to prune an index and never decides identity
/// (D8, invariant 9).

/// Which key space a scoped key belongs to. Mirrors `external_identity.key_kind` (D8).
public enum ExternalKeyKind: String, Hashable, Sendable, Codable, CaseIterable {
    case object
    case version
}

/// Namespace of the connector that declared a key. Opaque to the core: which values are legal is a
/// connector-registry decision, still open in ADR-003 (owner ADR-005).
public struct ConnectorNamespace: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The origin/account/feed scope a connector declares for its keys. The core never merges two
/// scopes, even when they spell the same thing (D8).
public struct ExternalScopeKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let namespace: ConnectorNamespace
    public let scopeKey: String

    public init(namespace: ConnectorNamespace, scopeKey: String) {
        self.namespace = namespace
        self.scopeKey = scopeKey
    }

    public var description: String { "\(namespace.rawValue):\(scopeKey)" }
}

public enum ExternalIdentityError: Error, Equatable, Sendable {
    /// A key without bytes is not an identity (`CHECK (length(external_key) > 0)`).
    case emptyKeyBytes
    /// A fallback scheme version is a positive persisted value (D16).
    case nonPositiveFallbackSchemeVersion(Int)
    /// A low-confidence identity always names the fallback scheme that produced it (D16).
    case lowConfidenceWithoutFallbackScheme
}

/// Identity of one external object: `(connector namespace, scopeKey, kind: object)` plus the full
/// key bytes. Equality compares every one of those parts; a digest is never consulted (D8).
public struct ExternalObjectKey: Hashable, Sendable, CustomStringConvertible {
    public let scope: ExternalScopeKey
    /// Byte-identical to what the connector supplied: no scheme rewrite, no parameter stripping,
    /// no host merging, no relative resolution (D10, invariant 19).
    public let bytes: Data

    public init(scope: ExternalScopeKey, bytes: Data) throws {
        guard !bytes.isEmpty else { throw ExternalIdentityError.emptyKeyBytes }
        self.scope = scope
        self.bytes = bytes
    }

    /// Convenience for the common case where the connector spells its key as text. The text is
    /// stored as its UTF-8 bytes and is not normalized in any way (D10).
    public init(scope: ExternalScopeKey, text: String) throws {
        try self.init(scope: scope, bytes: Data(text.utf8))
    }

    public var keyKind: ExternalKeyKind { .object }

    public var description: String {
        "\(keyKind.rawValue):\(scope.description):\(bytes.count)B"
    }
}

/// Identity of one representation of an external object. Opaque and **unordered**: two version
/// keys have no intrinsic order, and no code may sort, compare or count on them. Ordering inside
/// Runtime V2 comes only from the connector's explicit precedence instruction, applied at
/// Admission (D9, Blueprint §30/§63).
public struct ExternalVersionKey: Hashable, Sendable, CustomStringConvertible {
    public let scope: ExternalScopeKey
    /// Byte-identical to what the connector supplied (D10).
    public let bytes: Data

    public init(scope: ExternalScopeKey, bytes: Data) throws {
        guard !bytes.isEmpty else { throw ExternalIdentityError.emptyKeyBytes }
        self.scope = scope
        self.bytes = bytes
    }

    public init(scope: ExternalScopeKey, text: String) throws {
        try self.init(scope: scope, bytes: Data(text.utf8))
    }

    public var keyKind: ExternalKeyKind { .version }

    /// Deliberately not derived from the bytes: printing a version key must not suggest that its
    /// text ordering means anything (D9).
    public var description: String {
        "\(keyKind.rawValue):\(scope.description):\(bytes.count)B"
    }
}

/// 128-bit auxiliary index value for an external key.
///
/// It exists so a store can prune candidates cheaply. It is never an identity: equality decisions
/// compare the complete key bytes, a digest match alone never joins two records, and the digest is
/// never the only stored form of a key (D8, invariant 9).
public struct ExternalKeyDigest: Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public static func of(_ key: ExternalObjectKey) -> ExternalKeyDigest {
        ExternalKeyDigest(bytes: Fingerprint128.of(
            DigestEncoding.scopedKey(scope: key.scope, kind: key.keyKind, bytes: key.bytes)
        ))
    }

    public static func of(_ key: ExternalVersionKey) -> ExternalKeyDigest {
        ExternalKeyDigest(bytes: Fingerprint128.of(
            DigestEncoding.scopedKey(scope: key.scope, kind: key.keyKind, bytes: key.bytes)
        ))
    }
}

/// How much is known about a mapped key. Confidence travels with the key and is never silently
/// upgraded or dropped (D16).
public enum IdentityConfidence: String, Hashable, Sendable, Codable, CaseIterable {
    case high
    case low
}

/// The identity a record is known by: the key plus the confidence and fallback scheme version that
/// were declared with it. A low-confidence identity always names its scheme (D16).
public struct ExternalIdentityRef: Hashable, Sendable {
    public let key: ExternalObjectKey
    public let confidence: IdentityConfidence
    /// Non-nil exactly when `confidence` is `.low`.
    public let fallbackSchemeVersion: Int?

    public init(
        key: ExternalObjectKey,
        confidence: IdentityConfidence,
        fallbackSchemeVersion: Int?
    ) throws {
        guard confidence == .high || fallbackSchemeVersion != nil else {
            throw ExternalIdentityError.lowConfidenceWithoutFallbackScheme
        }
        self.key = key
        self.confidence = confidence
        self.fallbackSchemeVersion = fallbackSchemeVersion
    }
}

/// D16: the connector's declared fallback scheme, used when no GUID/Atom id and no usable primary
/// link exist.
///
/// The scheme is versioned, the version is stored with the low-confidence identity, and the version
/// is part of the derived bytes: changing how fallback keys are derived cannot silently rewrite an
/// existing identity. Two pieces of content that share title and date must not share a key by
/// accident, so the connector supplies a disambiguator; when a collision happens anyway, it never
/// deletes, overwrites or discards content (D16, invariant 14).
public struct FallbackIdentityScheme: Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int

    public init(version: Int = FallbackIdentityScheme.currentVersion) throws {
        guard version > 0 else {
            throw ExternalIdentityError.nonPositiveFallbackSchemeVersion(version)
        }
        self.version = version
    }

    /// Builds the low-confidence object key from opaque material the connector declares. The core
    /// never parses the material; it only compares it (D8).
    public func key(scope: ExternalScopeKey, material: Data) throws -> ExternalObjectKey {
        try ExternalObjectKey(scope: scope, bytes: schemeScoped(material))
    }

    /// Convenience for the connector material the plan names explicitly: title, authored date and a
    /// connector-owned disambiguator (D16).
    public func key(
        scope: ExternalScopeKey,
        title: String?,
        authoredAt: Date?,
        disambiguator: String
    ) throws -> ExternalObjectKey {
        var material = Data()
        material.append(DigestEncoding.optionalString(title))
        material.append(DigestEncoding.optionalDate(authoredAt))
        material.append(DigestEncoding.string(disambiguator))
        return try ExternalObjectKey(scope: scope, bytes: schemeScoped(material))
    }

    private func schemeScoped(_ material: Data) -> Data {
        var data = DigestEncoding.number(Int64(version))
        data.append(DigestEncoding.lengthPrefixed(material))
        return data
    }
}

/// The digests the identity layer compares. Injected so a store can choose its index, and so a test
/// can hand over a degenerate digest and prove that digest equality alone never joins two records
/// (invariant 9).
public protocol IdentityDigestPolicy: Sendable {
    func digest(of key: ExternalObjectKey) -> ExternalKeyDigest
    func digest(of key: ExternalVersionKey) -> ExternalKeyDigest
    func digest(of payload: ObservationPayload) -> PayloadDigest
}

/// The default index: a deterministic, non-cryptographic 128-bit fingerprint. Deterministic is the
/// requirement (a per-process seed would make an index unreachable across launches); cryptographic
/// strength is not, because the digest decides nothing (D8).
public struct StandardIdentityDigest: IdentityDigestPolicy {
    public init() {}

    public func digest(of key: ExternalObjectKey) -> ExternalKeyDigest { ExternalKeyDigest.of(key) }

    public func digest(of key: ExternalVersionKey) -> ExternalKeyDigest { ExternalKeyDigest.of(key) }

    public func digest(of payload: ObservationPayload) -> PayloadDigest { PayloadDigest.of(payload) }
}

/// Non-cryptographic 128-bit FNV-1a. Used only to build index values (see `ExternalKeyDigest`).
enum Fingerprint128 {
    private static let offsetBasis: (high: UInt64, low: UInt64) =
        (0x6c62_272e_07bb_0142, 0x62b8_2175_6295_c58d)
    private static let prime: (high: UInt64, low: UInt64) =
        (0x0000_0000_0100_0000, 0x0000_0000_0000_013b)

    static func of(_ bytes: Data) -> Data {
        var hash = offsetBasis
        for byte in bytes {
            hash.low ^= UInt64(byte)
            // Truncating 128x128 multiply: wrapping is the definition of the fingerprint, not an
            // unintended overflow.
            let (carry, low) = hash.low.multipliedFullWidth(by: prime.low)
            hash.high = hash.high &* prime.low &+ hash.low &* prime.high &+ carry
            hash.low = low
        }
        var digest = Data(capacity: 16)
        digest.append(DigestEncoding.bigEndian(hash.high))
        digest.append(DigestEncoding.bigEndian(hash.low))
        return digest
    }
}

/// Deterministic byte encoding used only to feed `Fingerprint128`. Every field is length- or
/// presence-prefixed so two different values never encode to the same bytes.
enum DigestEncoding {
    static func scopedKey(scope: ExternalScopeKey, kind: ExternalKeyKind, bytes: Data) -> Data {
        var data = Data()
        data.append(string(scope.namespace.rawValue))
        data.append(string(scope.scopeKey))
        data.append(string(kind.rawValue))
        data.append(lengthPrefixed(bytes))
        return data
    }

    static func string(_ value: String) -> Data {
        lengthPrefixed(Data(value.utf8))
    }

    static func optionalString(_ value: String?) -> Data {
        guard let value else { return presence(false) }
        var data = presence(true)
        data.append(string(value))
        return data
    }

    static func date(_ value: Date) -> Data {
        bigEndian(value.timeIntervalSinceReferenceDate.bitPattern)
    }

    static func optionalDate(_ value: Date?) -> Data {
        guard let value else { return presence(false) }
        var data = presence(true)
        data.append(date(value))
        return data
    }

    static func number(_ value: Int64) -> Data {
        bigEndian(UInt64(bitPattern: value))
    }

    static func lengthPrefixed(_ part: Data) -> Data {
        var data = bigEndian(UInt64(part.count))
        data.append(part)
        return data
    }

    static func presence(_ isPresent: Bool) -> Data {
        Data([isPresent ? 1 : 0])
    }

    static func bigEndian(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
}
