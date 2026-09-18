import Foundation
import FeedDomain

/// Identity plumbing for the syndication connector: the connector namespace, the per-source scope,
/// the key-resolution order and the connector's own record of the representation it last saw.
///
/// Nothing here parses a wire format and nothing here decides canonical identity: the connector
/// declares a key and the confidence it was declared with, and Admission decides what that key means
/// (plan §7; ADR-003 D8–D10, D16; ADR-005 D1).

/// The namespace every syndication key lives in. Opaque to the core: nothing outside the connector
/// interprets it (ADR-003 D8).
public enum SyndicationNamespace {
    public static let connector = ConnectorNamespace("feedmine.syndication")
}

public enum SyndicationIdentityError: Error, Equatable, Sendable {
    /// An empty scope key would put every source's items into one scope (ADR-003 D8).
    case emptyScopeKey
    /// The item declared no identifier, no link, no headline, no date and no content: there is
    /// nothing to observe, and a key invented out of nothing would be a fabrication.
    case noIdentityMaterial
    /// The declared fallback scheme version is not a legal persisted value (ADR-003 D16).
    case invalidFallbackSchemeVersion(Int)
    case keyRejected(ExternalIdentityError)
    case identityFailure(String)
}

/// Deterministic, non-cryptographic fingerprints.
///
/// The connector never decides identity with one and the core never reads one (ADR-003 D8/D9): a
/// deterministic value is what makes a replay of the same batch a duplicate instead of a new batch
/// with new bytes (plan §7). Cryptographic strength is not needed and a per-process seed would make
/// every stored fingerprint unreachable from the next launch.
public enum SyndicationFingerprint {
    /// 128-bit FNV-1a over the given bytes.
    public static func fingerprint128(_ bytes: Data) -> Data {
        var high: UInt64 = 0x6c62_272e_07bb_0142
        var low: UInt64 = 0x62b8_2175_6295_c58d
        let primeHigh: UInt64 = 0x0000_0000_0100_0000
        let primeLow: UInt64 = 0x0000_0000_0000_013b
        for byte in bytes {
            low ^= UInt64(byte)
            // Truncating 128x128 multiply: wrapping is the definition of the fingerprint, not an
            // unintended overflow.
            let (carry, nextLow) = low.multipliedFullWidth(by: primeLow)
            high = high &* primeLow &+ low &* primeHigh &+ carry
            low = nextLow
        }
        var digest = Data(capacity: 16)
        digest.append(bigEndian(high))
        digest.append(bigEndian(low))
        return digest
    }

    /// Lowercase hexadecimal, so a fingerprint can be a string column, a map key or evidence.
    public static func hex(_ bytes: Data) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The slot one object key occupies in the connector's record of observed representations. The
    /// digest only prunes a lookup; the full key bytes remain the identity (ADR-003 D8).
    public static func slot(of key: ExternalObjectKey) -> String {
        hex(ExternalKeyDigest.of(key).bytes)
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
}

/// What the connector last saw for one object: the version the document declared for it and the
/// fingerprint of its canonical payload.
///
/// Two version keys are never ordered, compared or sorted (ADR-003 D9). "Unchanged" therefore means
/// *the same declared version and the same payload*. A changed payload under an unchanged declared
/// version is deliberately not called a duplicate: it is handed to Admission as a current request so
/// the divergence is recorded instead of being dropped (ADR-003 D11).
public struct SyndicationRepresentationStamp: Hashable, Sendable, Codable {
    /// The version the document declared for this representation, rendered by the translator; `nil`
    /// when the document declared none for this item.
    public let declaredVersion: String?
    /// Fingerprint of the canonical payload, with the local observation time excluded (ADR-003 D17).
    public let payloadFingerprint: String

    public init(declaredVersion: String?, payload: ObservationPayload) {
        self.declaredVersion = declaredVersion
        self.payloadFingerprint = SyndicationFingerprint.hex(PayloadDigest.of(payload).bytes)
    }

    public func isUnchanged(from previous: SyndicationRepresentationStamp?) -> Bool {
        guard let previous else { return false }
        return declaredVersion == previous.declaredVersion
            && payloadFingerprint == previous.payloadFingerprint
    }

    /// The instruction the connector derives from the wire format: a first sighting or a changed
    /// representation is `makeCurrent`, an unchanged one is `duplicate`.
    ///
    /// `historicalOnly` is never emitted: RSS and Atom declare no ordering, so "older than what is
    /// current" is not expressible at this boundary (ADR-003 D9; ADR-006 D7). `expectedRevision` is
    /// always nil because a revision row identifier belongs to the core, not to a connector.
    public func precedence(from previous: SyndicationRepresentationStamp?) -> PrecedenceInstruction {
        isUnchanged(from: previous) ? .duplicate : .makeCurrent(expectedRevision: nil)
    }
}

public struct SyndicationIdentity: Sendable {
    public static let defaultFallbackSchemeVersion = FallbackIdentityScheme.currentVersion

    public let namespace: ConnectorNamespace
    public let fallbackSchemeVersion: Int

    public init(
        namespace: ConnectorNamespace = SyndicationNamespace.connector,
        fallbackSchemeVersion: Int = SyndicationIdentity.defaultFallbackSchemeVersion
    ) {
        self.namespace = namespace
        self.fallbackSchemeVersion = fallbackSchemeVersion
    }

    /// The scope one source's items live in: the connector namespace plus the source-scoped key the
    /// caller owns. A target's configuration is never editorial identity (ADR-005 D5, D10), and two
    /// scopes are never merged even when they spell the same thing (ADR-003 D8).
    public func scope(sourceKey: String) throws -> ExternalScopeKey {
        guard !sourceKey.isEmpty else { throw SyndicationIdentityError.emptyScopeKey }
        return ExternalScopeKey(namespace: namespace, scopeKey: sourceKey)
    }

    /// The key-resolution order of plan §12:
    /// 1. the declared identifier, byte-identically (`<guid>` / `atom:id`);
    /// 2. the declared link, byte-identically;
    /// 3. the versioned fallback scheme, declared low-confidence, with an explicit disambiguator.
    ///
    /// A declared identifier is never rewritten as a URL, stripped, normalised or resolved against
    /// the feed's base URL (ADR-003 D10; `testGUIDSpelledLikeAURLIsPassedThroughByteIdentical`).
    public func resolve(
        scope: ExternalScopeKey,
        declaredIdentifier: String?,
        declaredLink: String?,
        payload: ObservationPayload
    ) throws -> ExternalIdentityRef {
        if let identifier = declaredIdentifier, !identifier.isEmpty {
            return try declared(scope: scope, text: identifier)
        }
        if let link = declaredLink, !link.isEmpty {
            return try declared(scope: scope, text: link)
        }
        guard payload.headline != nil || payload.excerpt != nil || payload.body != nil
            || payload.authoredAt != nil || payload.modifiedAt != nil
        else {
            throw SyndicationIdentityError.noIdentityMaterial
        }

        let scheme: FallbackIdentityScheme
        do {
            scheme = try FallbackIdentityScheme(version: fallbackSchemeVersion)
        } catch {
            throw SyndicationIdentityError.invalidFallbackSchemeVersion(fallbackSchemeVersion)
        }

        // The disambiguator is derived from the canonical payload rather than from the item's
        // position: a feed that declares neither identifier nor link has no stable order, and a
        // positional key would silently attach one item's history to another item's content when
        // the publisher reorders the document. The version is part of the derived bytes
        // (ADR-003 D16), so this derivation can be replaced later without rewriting identities.
        let disambiguator = SyndicationFingerprint.hex(PayloadDigest.of(payload).bytes)
        let key: ExternalObjectKey
        let ref: ExternalIdentityRef
        do {
            key = try scheme.key(
                scope: scope,
                title: payload.headline,
                authoredAt: payload.authoredAt,
                disambiguator: disambiguator
            )
            ref = try ExternalIdentityRef(
                key: key,
                confidence: .low,
                fallbackSchemeVersion: scheme.version
            )
        } catch let error as ExternalIdentityError {
            throw SyndicationIdentityError.keyRejected(error)
        } catch {
            throw SyndicationIdentityError.identityFailure(String(describing: error))
        }
        return ref
    }

    private func declared(scope: ExternalScopeKey, text: String) throws -> ExternalIdentityRef {
        do {
            let key = try ExternalObjectKey(scope: scope, bytes: Data(text.utf8))
            return try ExternalIdentityRef(key: key, confidence: .high, fallbackSchemeVersion: nil)
        } catch let error as ExternalIdentityError {
            throw SyndicationIdentityError.keyRejected(error)
        } catch {
            throw SyndicationIdentityError.identityFailure(String(describing: error))
        }
    }
}
