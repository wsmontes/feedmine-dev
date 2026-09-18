import Foundation
import FeedDomain

/// The fingerprint that decides whether a re-delivered batch is the same body (ADR-006 D2).
///
/// The runtime computes it, never the connector: a value the runtime cannot recompute stops being
/// evidence the moment the connector's version changes, and the connector's own `fingerprint` field
/// is therefore not consulted (ADR-006, rejected alternatives). The digest must be
/// collision-resistant — a collision would let a *different* body be answered as a replay of another
/// batch, silently dropping content — so it is SHA-256, not the auxiliary FNV index of the identity
/// layer. CryptoKit is not reachable from this module (the boundary gate allows Foundation, GRDB and
/// FeedDomain), so the digest is implemented here.
enum BatchFingerprint {
    /// 64 lowercase hex characters, matching `CHECK (length(fingerprint) = 64)`.
    static func of(_ batch: AcquisitionBatch) -> String {
        SHA256.hex(of: canonicalBytes(of: batch))
    }

    /// The canonical serialisation ADR-006 D2 names: observations (with their memberships,
    /// relations, media and offers), the target generation, the binding revision and the next
    /// checkpoint.
    ///
    /// Every field is length-prefixed or presence-prefixed, so two different bodies can never encode
    /// to the same bytes. Two fields are deliberately absent, for one reason: they are local stamps
    /// the *runtime* moves, so folding them in would make a retry that re-stamps the same content look
    /// like a different body — and a retry must be a replay, not a conflict (ADR-006 D2).
    /// `observedAt` is the first (ADR-003 D17): observation metadata. The **expected checkpoint
    /// revision** is the second, and it is the sharper case: the adapter stamps it from the request,
    /// so it is runtime-derived rather than connector-declared, *and* it advances as a consequence of
    /// admitting the batch itself — a body that carried it would make the same page a new batch
    /// forever. Measured before this change: one episode admitted the same page 24 times, bounded only
    /// by the request budget (§8.55). The lease epoch stays in, as ADR-006 D2's own list requires:
    /// work produced under a superseded epoch is different work.
    static func canonicalBytes(of batch: AcquisitionBatch) -> Data {
        var data = Data()
        data.append(CanonicalEncoding.string(batch.batchID))
        data.append(CanonicalEncoding.string(batch.targetID.rawValue))
        data.append(CanonicalEncoding.number(batch.generation))
        data.append(CanonicalEncoding.number(batch.bindingRevision))
        data.append(CanonicalEncoding.number(batch.leaseEpoch))
        data.append(CanonicalEncoding.optionalData(batch.nextCheckpoint?.blob))
        data.append(CanonicalEncoding.number(UInt64(batch.nextCheckpoint?.serializationSchema ?? 0)))
        data.append(CanonicalEncoding.optionalString(batch.nextCheckpoint?.connectorVersion))
        data.append(CanonicalEncoding.sequence(batch.observations.map(observationBytes)))
        data.append(CanonicalEncoding.sequence(batch.evidence.map(evidenceBytes)))
        return data
    }

    private static func observationBytes(_ observation: AcquisitionObservation) -> Data {
        var data = Data()
        data.append(CanonicalEncoding.string(observation.externalKey.scope.namespace.rawValue))
        data.append(CanonicalEncoding.string(observation.externalKey.scope.scopeKey))
        data.append(CanonicalEncoding.blob(observation.externalKey.bytes))
        data.append(CanonicalEncoding.optionalData(observation.versionKey?.bytes))
        data.append(precedenceBytes(observation.precedence))
        data.append(CanonicalEncoding.optionalString(observation.payload.headline))
        data.append(CanonicalEncoding.optionalString(observation.payload.link?.absoluteString))
        data.append(CanonicalEncoding.optionalString(observation.payload.excerpt))
        data.append(CanonicalEncoding.optionalString(observation.payload.body))
        data.append(CanonicalEncoding.optionalDate(observation.payload.authoredAt))
        data.append(CanonicalEncoding.optionalDate(observation.payload.modifiedAt))
        data.append(CanonicalEncoding.string(observation.identityConfidence.rawValue))
        data.append(CanonicalEncoding.optionalNumber(observation.fallbackSchemeVersion.map(UInt64.init)))
        if let provider = observation.provider {
            data.append(CanonicalEncoding.string(provider.namespace.rawValue))
            data.append(CanonicalEncoding.string(provider.providerKey))
            data.append(CanonicalEncoding.string(provider.displayName))
            data.append(CanonicalEncoding.string(provider.role.rawValue))
            data.append(CanonicalEncoding.optionalString(provider.evidenceKey))
        } else {
            data.append(CanonicalEncoding.presence(false))
        }
        data.append(CanonicalEncoding.sequence(observation.memberships.map(membershipBytes)))
        data.append(CanonicalEncoding.sequence(observation.relations.map(relationBytes)))
        data.append(CanonicalEncoding.sequence(observation.mediaCandidates.map(mediaBytes)))
        data.append(CanonicalEncoding.sequence(observation.interactionOffers.map(offerBytes)))
        return data
    }

    private static func precedenceBytes(_ precedence: PrecedenceInstruction) -> Data {
        switch precedence {
        case .historicalOnly:
            return CanonicalEncoding.string("historicalOnly")
        case .duplicate:
            return CanonicalEncoding.string("duplicate")
        case let .makeCurrent(expectedRevision):
            var data = CanonicalEncoding.string("makeCurrent")
            data.append(CanonicalEncoding.optionalNumber(expectedRevision.map { UInt64($0.rawValue) }))
            return data
        }
    }

    private static func membershipBytes(_ membership: MembershipClaim) -> Data {
        var data = CanonicalEncoding.number(UInt64(membership.sourceID.rawValue))
        data.append(CanonicalEncoding.string(membership.membershipKind))
        if let binding = membership.binding {
            data.append(CanonicalEncoding.presence(true))
            data.append(CanonicalEncoding.string(binding.namespace.rawValue))
            data.append(CanonicalEncoding.string(binding.bindingKey))
        } else {
            data.append(CanonicalEncoding.presence(false))
        }
        data.append(CanonicalEncoding.optionalNumber(membership.bindingGeneration))
        return data
    }

    private static func relationBytes(_ relation: RelationClaim) -> Data {
        var data = CanonicalEncoding.string(relation.verb.rawValue)
        data.append(CanonicalEncoding.string(relation.target.scope.namespace.rawValue))
        data.append(CanonicalEncoding.string(relation.target.scope.scopeKey))
        data.append(CanonicalEncoding.blob(relation.target.bytes))
        return data
    }

    private static func mediaBytes(_ candidate: MediaCandidateClaim) -> Data {
        var data = CanonicalEncoding.string(candidate.role.rawValue)
        data.append(CanonicalEncoding.string(candidate.resourceURL))
        data.append(CanonicalEncoding.optionalString(candidate.mediaTypeHint))
        data.append(CanonicalEncoding.optionalNumber(candidate.pixelWidth.map { UInt64($0) }))
        data.append(CanonicalEncoding.optionalNumber(candidate.pixelHeight.map { UInt64($0) }))
        data.append(CanonicalEncoding.number(UInt64(candidate.position)))
        return data
    }

    private static func offerBytes(_ offer: InteractionOfferClaim) -> Data {
        var data = CanonicalEncoding.string(offer.kind)
        data.append(CanonicalEncoding.optionalString(offer.handle))
        data.append(CanonicalEncoding.number(UInt64(offer.position)))
        return data
    }

    private static func evidenceBytes(_ evidence: ConnectorEvidence) -> Data {
        var data = CanonicalEncoding.string(evidence.kind.rawValue)
        data.append(CanonicalEncoding.string(evidence.digest))
        data.append(CanonicalEncoding.optionalData(evidence.bytes))
        return data
    }
}

/// Deterministic, injective byte encoding for the batch fingerprint.
///
/// A sequence is length-prefixed and every element is length-prefixed again, so no two different
/// batches share an encoding — including the case of one body being a prefix of another.
enum CanonicalEncoding {
    static func sequence(_ elements: [Data]) -> Data {
        var data = Data()
        data.append(number(UInt64(elements.count)))
        for element in elements {
            data.append(lengthPrefixed(element))
        }
        return data
    }

    static func string(_ value: String) -> Data { lengthPrefixed(Data(value.utf8)) }

    static func blob(_ value: Data) -> Data { lengthPrefixed(value) }

    static func number(_ value: UInt64) -> Data {
        var data = Data(capacity: 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
        return data
    }

    static func optionalNumber(_ value: UInt64?) -> Data {
        guard let value else { return presence(false) }
        var data = presence(true)
        data.append(number(value))
        return data
    }

    static func optionalString(_ value: String?) -> Data {
        guard let value else { return presence(false) }
        var data = presence(true)
        data.append(string(value))
        return data
    }

    static func optionalData(_ value: Data?) -> Data {
        guard let value else { return presence(false) }
        var data = presence(true)
        data.append(blob(value))
        return data
    }

    static func optionalDate(_ value: Date?) -> Data {
        guard let value else { return presence(false) }
        var data = presence(true)
        data.append(number(value.timeIntervalSinceReferenceDate.bitPattern))
        return data
    }

    static func presence(_ isPresent: Bool) -> Data { Data([isPresent ? 1 : 0]) }

    static func lengthPrefixed(_ part: Data) -> Data {
        var data = number(UInt64(part.count))
        data.append(part)
        return data
    }
}

/// SHA-256 (FIPS 180-4).
enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    static func hex(of message: Data) -> String {
        digest(of: message).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of message: Data) -> Data {
        var padded = [UInt8](message)
        let bitCount = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }

        var hash = initialState
        var schedule = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < padded.count {
            for index in 0..<16 {
                let base = offset + index * 4
                schedule[index] = (UInt32(padded[base]) << 24)
                    | (UInt32(padded[base + 1]) << 16)
                    | (UInt32(padded[base + 2]) << 8)
                    | UInt32(padded[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(schedule[index - 15], 7) ^ rotate(schedule[index - 15], 18) ^ (schedule[index - 15] >> 3)
                let s1 = rotate(schedule[index - 2], 17) ^ rotate(schedule[index - 2], 19) ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }

            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ schedule[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
            offset += 64
        }

        var digest = Data(capacity: 32)
        for word in hash {
            for shift in stride(from: 24, through: 0, by: -8) {
                digest.append(UInt8((word >> UInt32(shift)) & 0xff))
            }
        }
        return digest
    }

    private static func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
