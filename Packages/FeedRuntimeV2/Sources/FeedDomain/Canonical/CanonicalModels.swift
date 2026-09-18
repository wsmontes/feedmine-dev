import Foundation

/// The canonical domain: the logical external object and its immutable representations
/// (ADR-003 D4, D8, D9, D11, D16, D17).

/// 128-bit fingerprint of one canonical payload.
///
/// It is compared only to *detect* that two revisions of one record carry divergent content (D11).
/// It never joins two records, never replaces the payload and is never an identity (D8).
public struct PayloadDigest: Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Fingerprint of the whole canonical payload, so a changed payload is always a different
    /// digest and therefore a divergence that can be detected instead of overwritten (D11).
    public static func of(_ payload: ObservationPayload) -> PayloadDigest {
        PayloadDigest(bytes: Fingerprint128.of(DigestEncoding.payload(payload)))
    }
}

extension DigestEncoding {
    /// The canonical content of one observation. `observedAt` is deliberately absent: it is local
    /// observation metadata (D17), and folding it in would make every re-observation of unchanged
    /// content a new payload, which would defeat versionless deduplication (D9) and turn an
    /// unchanged feed into endless divergence conflicts (D11).
    static func payload(_ payload: ObservationPayload) -> Data {
        var data = Data()
        data.append(optionalString(payload.headline))
        data.append(optionalString(payload.link?.absoluteString))
        data.append(optionalString(payload.excerpt))
        data.append(optionalString(payload.body))
        data.append(optionalDate(payload.authoredAt))
        data.append(optionalDate(payload.modifiedAt))
        return data
    }
}

/// The logical external object: exactly one per `(connector namespace, scope, full object key)`.
///
/// It is never destroyed to express syndication or similarity (D13), never merged because two keys
/// look alike (D12), and never renumbered by a catalogue rebuild (D4).
public struct OriginRecord: Hashable, Sendable {
    public let id: OriginRecordID
    /// The identity that created the record. An alias added later adds evidence; it never rewrites
    /// this (D12).
    public let primaryIdentity: ExternalIdentityRef
    public let firstObservedAt: Date
    /// High-water mark of observation. A late observation of an older representation never moves it
    /// backwards (`CHECK (last_observed_at >= first_observed_at)`).
    public let lastObservedAt: Date
}

/// One immutable representation of an `OriginRecord`.
///
/// There is no update path: a changed payload is a new revision, and a divergent payload under an
/// already-used version key is a recorded conflict, never an overwrite (D11, I-06).
public struct OriginRevision: Hashable, Sendable {
    public let id: OriginRevisionID
    public let record: OriginRecordID
    /// Opaque and unordered; `nil` for a versionless observation (D9).
    public let versionKey: ExternalVersionKey?
    /// What the collision policy compares (D11).
    public let payloadDigest: PayloadDigest
    /// The exact canonical payload. `headline` and `link` may be absent and are never synthesized
    /// (D16, D17).
    public let payload: ObservationPayload
    public let identityConfidence: IdentityConfidence
    /// Non-nil exactly when `identityConfidence` is `.low` (D16).
    public let fallbackSchemeVersion: Int?
}

/// D17: the sort date is a policy input, not a rewritten payload field.
///
/// `authoredAt` and `modifiedAt` are written only when the connector declares them; `observedAt` is
/// always the local observation time. No code path substitutes one for the other, so a consumer that
/// needs a sortable date asks this policy and is told when the answer is a fallback.
public struct SortDatePolicy: Hashable, Sendable {
    public static let currentVersion = 1

    public struct Outcome: Hashable, Sendable {
        public let date: Date
        /// True when `date` is the observation time standing in for a missing authored date.
        public let isFallback: Bool
        /// The sort-date policy that produced this outcome, so a consumer can record which policy a
        /// published date came from instead of presenting a fallback as an authored date (D17).
        public let policyVersion: Int
    }

    public let version: Int

    public init(version: Int = SortDatePolicy.currentVersion) {
        self.version = version
    }

    /// The declared authored date when there is one, otherwise the observation time reported as a
    /// fallback. A declared date is never clamped: clock skew is stored and reported as declared.
    public func outcome(for payload: ObservationPayload) -> Outcome {
        guard let authoredAt = payload.authoredAt else {
            return Outcome(date: payload.observedAt, isFallback: true, policyVersion: version)
        }
        return Outcome(date: authoredAt, isFallback: false, policyVersion: version)
    }
}
