import Foundation
import FeedDomain

/// The syndication connector's checkpoint: connector-owned data the core only stores
/// (ADR-005 D11, row #28).
///
/// This is a `Sendable`, `Codable` value with no SQL in it. `FeedStorage` persists `encoded()` in
/// `connector_checkpoint` and never interprets it; the core never reads a validator, a version or a
/// page token out of it (Blueprint §62). Only Admission may commit a checkpoint, and only together
/// with the content of the batch that produced it — the connector merely *proposes* one
/// (`invariant 6`).

/// `ETag` / `Last-Modified` as an endpoint declared them.
///
/// Both are opaque byte strings: a weak validator keeps its `W/` prefix and its quotes, and a date
/// is never re-parsed, re-rendered or compared as a date.
public struct SyndicationValidators: Hashable, Sendable, Codable {
    public let etag: String?
    public let lastModified: String?

    public init(etag: String? = nil, lastModified: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
    }

    public var isEmpty: Bool { etag == nil && lastModified == nil }
}

public enum SyndicationCheckpointError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    /// A 304 confirms a baseline; without an admitted baseline there is nothing to confirm, and the
    /// body must be fetched unconditionally first (ADR-005 D12).
    case notModifiedWithoutAdmittedBaseline
    case encodingFailed(String)
    case decodingFailed(String)
}

public struct SyndicationCheckpoint: Hashable, Sendable, Codable {
    /// The only serialization this build understands. A payload written by another schema version is
    /// refused rather than guessed at (ADR-005 D11).
    public static let currentSchemaVersion = 1

    /// A document this connector is partway through, because its items did not all fit in one batch
    /// (ADR-005 D4: a connector that would exceed the batch ceiling splits into batches, it does not
    /// re-emit the same prefix). Absent — `nil` — when no document is in flight, which is also what a
    /// checkpoint written before this field existed decodes to.
    public struct PartialDocument: Hashable, Sendable, Codable {
        /// Fingerprint of the exact body bytes the offset counts items of. A slice may only continue a
        /// document whose bytes are unchanged: a body that differs restarts at its first item.
        public let bodyFingerprint: String
        /// The declared items of that document this connector already passed over, translated or
        /// rejected.
        public let consumedItemCount: Int
        /// Whether any slice of this document could not be translated. A document with a rejected item
        /// never confirms a validator, however far the slices got (ADR-005 D12).
        public let sawItemRejection: Bool

        public init(bodyFingerprint: String, consumedItemCount: Int, sawItemRejection: Bool) {
            self.bodyFingerprint = bodyFingerprint
            self.consumedItemCount = consumedItemCount
            self.sawItemRejection = sawItemRejection
        }
    }

    public let schemaVersion: Int
    /// The connector namespace this checkpoint belongs to, so a row handed to the wrong connector is
    /// refused instead of reused (ADR-005 D11).
    public let connectorNamespace: String
    /// The target generation the validators were obtained under. A generation bump makes the
    /// checkpoint unusable, never silently reusable (ADR-005 D10).
    public let generation: UInt64
    /// The endpoint that issued `validators`, in its audit form: scheme, host and path, with the
    /// insecure scheme already upgraded and without query, fragment or userinfo (ADR-005 D12, D14).
    /// A validator is never applied to another endpoint (`invariant 7`).
    public let endpoint: String
    public let validators: SyndicationValidators
    /// `true` only once V2 actually received a body from `endpoint`. While it is false the connector
    /// must fetch unconditionally, whatever validator it is holding (ADR-005 D12,
    /// `missingBodyRequiresUnconditionalFetch`).
    public let hasAdmittedBaseline: Bool
    /// What the connector last saw per object, so an unchanged representation is reported as a
    /// duplicate instead of a spurious current. Bounded by the per-batch item ceiling.
    public let observedRepresentations: [String: SyndicationRepresentationStamp]
    /// The document this checkpoint is partway through, or `nil` when it is at a document boundary.
    public let partialDocument: PartialDocument?

    public init(
        schemaVersion: Int = SyndicationCheckpoint.currentSchemaVersion,
        connectorNamespace: String = SyndicationNamespace.connector.rawValue,
        generation: UInt64,
        endpoint: String,
        validators: SyndicationValidators = SyndicationValidators(),
        hasAdmittedBaseline: Bool = false,
        observedRepresentations: [String: SyndicationRepresentationStamp] = [:],
        partialDocument: PartialDocument? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.connectorNamespace = connectorNamespace
        self.generation = generation
        self.endpoint = endpoint
        self.validators = validators
        self.hasAdmittedBaseline = hasAdmittedBaseline
        self.observedRepresentations = observedRepresentations
        self.partialDocument = partialDocument
    }

    /// The form an endpoint is stored and compared in. A query string is personal data and is never
    /// persisted, so two spellings of one endpoint — with and without a query — are one endpoint.
    public static func endpointKey(of url: URL) -> String {
        EndpointPolicy.effectiveEndpoint(of: url).absoluteString
    }

    /// A checkpoint for a target V2 has not fetched yet: no validators, no baseline, no memory.
    public static func initial(
        generation: UInt64,
        endpoint: URL,
        connectorNamespace: String = SyndicationNamespace.connector.rawValue
    ) -> SyndicationCheckpoint {
        SyndicationCheckpoint(
            connectorNamespace: connectorNamespace,
            generation: generation,
            endpoint: endpointKey(of: endpoint)
        )
    }

    /// Whether this checkpoint may be used at all for this endpoint and generation.
    ///
    /// An endpoint change is not a Source identity change (ADR-005 D10) and a validator belongs to
    /// the endpoint that issued it (D12): a checkpoint for another endpoint — including one learned
    /// through a redirect — is discarded, and the next fetch is unconditional.
    public func isUsable(
        for endpoint: URL,
        generation: UInt64,
        connectorNamespace: String = SyndicationNamespace.connector.rawValue
    ) -> Bool {
        self.generation == generation
            && self.endpoint == SyndicationCheckpoint.endpointKey(of: endpoint)
            && self.connectorNamespace == connectorNamespace
    }

    /// The conditional headers this checkpoint authorises, or an empty set.
    ///
    /// Empty in three cases, each of them a rule: the checkpoint belongs to another endpoint,
    /// generation or connector; no body from this endpoint was ever received, so there is no
    /// baseline to confirm (ADR-005 D12); or the endpoint issued no validators.
    public func conditionalHeaders(
        for endpoint: URL,
        generation: UInt64,
        connectorNamespace: String = SyndicationNamespace.connector.rawValue
    ) -> [String: String] {
        guard isUsable(for: endpoint, generation: generation, connectorNamespace: connectorNamespace),
              hasAdmittedBaseline
        else { return [:] }
        // Half a document needs its body again to produce the next slice, and a validator that was
        // issued with a partially admitted body is not a confirmed baseline: the fetch that resumes a
        // document is unconditional by construction (ADR-005 D12).
        guard partialDocument == nil else { return [:] }
        var headers: [String: String] = [:]
        if let etag = validators.etag { headers["If-None-Match"] = etag }
        if let lastModified = validators.lastModified { headers["If-Modified-Since"] = lastModified }
        return headers
    }

    /// A fully consumed body: the validators issued with it replace the previous ones and this
    /// endpoint now has an admitted baseline.
    ///
    /// This is the only transition that advances a validator, and the connector reaches it only
    /// after a run that consumed everything the document declared — a parse failure, a truncated
    /// body, an item the connector could not translate or an item ceiling all leave the previous
    /// checkpoint untouched (ADR-005 D12; plan §14 PR-11).
    public func adoptingBaseline(
        validators: SyndicationValidators,
        endpoint: URL,
        observedRepresentations: [String: SyndicationRepresentationStamp]
    ) -> SyndicationCheckpoint {
        SyndicationCheckpoint(
            connectorNamespace: connectorNamespace,
            generation: generation,
            endpoint: SyndicationCheckpoint.endpointKey(of: endpoint),
            validators: validators,
            hasAdmittedBaseline: true,
            observedRepresentations: observedRepresentations
        )
    }

    /// A 304 on top of an admitted baseline: nothing advanced, nothing was removed and no version
    /// moved (ADR-005 D12, `invariant 9`). A 304 without a baseline is a protocol error, never a
    /// shortcut.
    public func confirmedByNotModified() throws -> SyndicationCheckpoint {
        guard hasAdmittedBaseline else { throw SyndicationCheckpointError.notModifiedWithoutAdmittedBaseline }
        return self
    }

    /// The same document, one slice further: the next pull translates from `consumedItemCount` of the
    /// same body bytes.
    ///
    /// Nothing about the baseline moves. The body was only partly admitted, so its validators are not
    /// confirmed and the fetch that produces the next slice must be unconditional — a conditional one
    /// would answer `304` and there would be no body left to translate (ADR-005 D12).
    public func continuing(
        document: PartialDocument,
        observedRepresentations: [String: SyndicationRepresentationStamp]
    ) -> SyndicationCheckpoint {
        SyndicationCheckpoint(
            connectorNamespace: connectorNamespace,
            generation: generation,
            endpoint: endpoint,
            validators: validators,
            hasAdmittedBaseline: hasAdmittedBaseline,
            observedRepresentations: observedRepresentations,
            partialDocument: document
        )
    }

    /// A document read to its end that may not confirm a validator: an item the connector could not
    /// translate, or a document that declares nothing recognizable (ADR-005 D12).
    ///
    /// The partial state is dropped — the next slice would be empty, and the next fetch is an ordinary
    /// conditional one again — while the previous baseline and validators stay exactly as they were.
    public func endingUnconfirmedDocument(
        observedRepresentations: [String: SyndicationRepresentationStamp]
    ) -> SyndicationCheckpoint {
        SyndicationCheckpoint(
            connectorNamespace: connectorNamespace,
            generation: generation,
            endpoint: endpoint,
            validators: validators,
            hasAdmittedBaseline: hasAdmittedBaseline,
            observedRepresentations: observedRepresentations
        )
    }

    /// The payload a repository stores as `connector_checkpoint.payload`.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw SyndicationCheckpointError.encodingFailed(String(describing: error))
        }
    }

    /// Reads a stored payload and refuses one written by a schema version this build does not know.
    public static func decoded(from data: Data) throws -> SyndicationCheckpoint {
        let checkpoint: SyndicationCheckpoint
        do {
            checkpoint = try JSONDecoder().decode(SyndicationCheckpoint.self, from: data)
        } catch {
            throw SyndicationCheckpointError.decodingFailed(String(describing: error))
        }
        guard checkpoint.schemaVersion == SyndicationCheckpoint.currentSchemaVersion else {
            throw SyndicationCheckpointError.unsupportedSchemaVersion(checkpoint.schemaVersion)
        }
        return checkpoint
    }
}
