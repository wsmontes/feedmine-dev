import XCTest
@testable import FeedDomain

/// The named acceptance tests of ADR-003 §"Named acceptance tests" for the identity slice (PR-02).
///
/// Every assertion here is about observable identity behaviour with fixed inputs: no clock, no
/// randomness, no network, no file system. Where a named test belongs to a persistence PR, the
/// assertion here is the honest value-level part of it and the persistence half is reported.

// MARK: - Fixed inputs

private let dayOne = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let dayTwo = Date(timeIntervalSinceReferenceDate: 800_003_600)
private let dayThree = Date(timeIntervalSinceReferenceDate: 800_007_200)

private func scopeKey(_ namespace: String = "rss", _ key: String = "feed:1") -> ExternalScopeKey {
    ExternalScopeKey(namespace: ConnectorNamespace(namespace), scopeKey: key)
}

private func objectKey(
    _ text: String,
    namespace: String = "rss",
    scope key: String = "feed:1"
) throws -> ExternalObjectKey {
    try ExternalObjectKey(scope: scopeKey(namespace, key), text: text)
}

private func versionKey(
    _ text: String,
    namespace: String = "rss",
    scope key: String = "feed:1"
) throws -> ExternalVersionKey {
    try ExternalVersionKey(scope: scopeKey(namespace, key), text: text)
}

private func payload(
    _ headline: String?,
    link: String? = nil,
    authoredAt: Date? = nil,
    observedAt: Date = dayOne
) -> ObservationPayload {
    ObservationPayload(
        headline: headline,
        link: link.flatMap { URL(string: $0) },
        excerpt: nil,
        body: nil,
        authoredAt: authoredAt,
        modifiedAt: nil,
        observedAt: observedAt
    )
}

private func declaredRequest(
    _ key: ExternalObjectKey,
    version: ExternalVersionKey? = nil,
    payload: ObservationPayload
) -> IdentityResolutionRequest {
    IdentityResolutionRequest(key: key, versionKey: version, payload: payload)
}

private func fallbackRequest(
    _ key: ExternalObjectKey,
    version: ExternalVersionKey? = nil,
    payload: ObservationPayload,
    scheme: FallbackIdentityScheme
) -> IdentityResolutionRequest {
    IdentityResolutionRequest(key: key, versionKey: version, payload: payload, fallbackScheme: scheme)
}

private func resolve(
    _ index: inout IdentityIndex,
    _ request: IdentityResolutionRequest
) throws -> IdentityResolution {
    try index.resolve(request)
}

/// A digest policy that gives every key the same digest, so a test can prove that digest equality
/// alone never joins two records (ADR-003 invariant 9).
private struct ConstantIdentityDigest: IdentityDigestPolicy {
    static let constant = ExternalKeyDigest(bytes: Data(repeating: 0, count: 16))

    func digest(of key: ExternalObjectKey) -> ExternalKeyDigest { Self.constant }

    func digest(of key: ExternalVersionKey) -> ExternalKeyDigest { Self.constant }

    func digest(of payload: ObservationPayload) -> PayloadDigest { PayloadDigest.of(payload) }
}

// MARK: - Resolution reading helpers

private extension RevisionOutcome {
    var revisionID: OriginRevisionID {
        switch self {
        case let .appended(id), let .duplicate(id): return id
        case let .divergentPayloadPreserved(stored): return stored
        }
    }

    var isAppended: Bool {
        if case .appended = self { return true }
        return false
    }
}

private extension IdentityResolution {
    var record: OriginRecordID? {
        switch self {
        case let .newRecord(record, _, _, _, _), let .existingRecord(record, _, _, _, _): return record
        case .refused: return nil
        }
    }

    var isNewRecord: Bool {
        if case .newRecord = self { return true }
        return false
    }

    var revision: RevisionOutcome? {
        switch self {
        case let .newRecord(_, revision, _, _, _), let .existingRecord(_, revision, _, _, _):
            return revision
        case .refused:
            return nil
        }
    }

    var confidence: IdentityConfidence? {
        switch self {
        case let .newRecord(_, _, confidence, _, _), let .existingRecord(_, _, confidence, _, _):
            return confidence
        case .refused:
            return nil
        }
    }

    var fallbackSchemeVersion: Int? {
        switch self {
        case let .newRecord(_, _, _, version, _), let .existingRecord(_, _, _, version, _):
            return version
        case .refused:
            return nil
        }
    }

    var conflicts: [IdentityConflict] {
        switch self {
        case let .newRecord(_, _, _, _, conflicts), let .existingRecord(_, _, _, _, conflicts):
            return conflicts
        case .refused:
            return []
        }
    }

    var refusal: IdentityConflict? {
        if case let .refused(conflict) = self { return conflict }
        return nil
    }
}

// MARK: - Tests

final class IdentityTests: XCTestCase {

    // MARK: - D5, D6: Source, Provider, Binding

    func testSourceCanHaveMultipleBindings() throws {
        let source = try SourceID(7)
        let rss = try SourceBinding(
            key: SourceBindingKey(namespace: ConnectorNamespace("rss"), bindingKey: "feed-a"),
            sourceID: source,
            configurationJSON: #"{"endpoint":"https://a.example/feed.xml"}"#
        )
        let json = try SourceBinding(
            key: SourceBindingKey(namespace: ConnectorNamespace("jsonfeed"), bindingKey: "feed-b"),
            sourceID: source,
            configurationJSON: #"{"endpoint":"https://b.example/feed.json"}"#
        )

        var bindings = [rss, json]
        XCTAssertEqual(bindings.count, 2)
        XCTAssertTrue(bindings.allSatisfy { $0.sourceID == source }, "one source, two bindings")
        XCTAssertEqual(Set(bindings.map(\.key.namespace.rawValue)), ["rss", "jsonfeed"])
        XCTAssertTrue(bindings.allSatisfy { $0.state == .enabled })
        XCTAssertTrue(bindings.allSatisfy { $0.accepts(generation: $0.generation) })

        // Each binding carries its own generation: advancing one does not move the other.
        let reconfiguredJSON = try json.advanced(to: #"{"endpoint":"https://b.example/v2.json"}"#)
        bindings = [rss, reconfiguredJSON]
        XCTAssertEqual(rss.generation, 1)
        XCTAssertEqual(reconfiguredJSON.generation, 2)
        XCTAssertTrue(rss.accepts(generation: 1))
        XCTAssertFalse(rss.accepts(generation: 2))
        XCTAssertEqual(Set(bindings.map(\.sourceID)), [source])
    }

    func testEndpointChangePreservesSourceIdentity() throws {
        let source = try SourceID(7)
        let binding = try SourceBinding(
            key: SourceBindingKey(namespace: ConnectorNamespace("rss"), bindingKey: "feed-a"),
            sourceID: source,
            configurationJSON: #"{"endpoint":"https://a.example/feed.xml"}"#
        )

        let changed = try binding.advanced(to: #"{"endpoint":"https://mirror.example/feed.xml"}"#)

        XCTAssertEqual(changed.sourceID, binding.sourceID)
        XCTAssertEqual(changed.key, binding.key)
        XCTAssertEqual(changed.generation, 2)
        XCTAssertEqual(changed.state, .enabled)
        XCTAssertNotEqual(changed.configurationJSON, binding.configurationJSON)

        // D2: the catalogue identity is a different namespace. The only way to it is a persisted
        // mapping, and a missing row is an error rather than a derived runtime source.
        let mapping = LegacySourceMapping(
            editorialKey: try EditorialSourceKey(catalogIdentity: "source:a", canonicalizationVersion: 1),
            catalogSourceID: CatalogSourceID(1),
            runtimeSourceID: source,
            legacyURL: "https://a.example/feed.xml",
            mappedAt: dayOne
        )
        var map = LegacySourceMap([mapping])
        let mapped = try map.runtimeSource(forCatalogSource: CatalogSourceID(1), canonicalizationVersion: 1)
        XCTAssertEqual(mapped, changed.sourceID)

        let unmapped = CatalogSourceID(2)
        XCTAssertThrowsError(
            try map.runtimeSource(forCatalogSource: unmapped, canonicalizationVersion: 1)
        ) { error in
            XCTAssertEqual(
                error as? LegacyMappingError,
                .missingSourceMapping(catalogSourceID: unmapped, canonicalizationVersion: 1)
            )
        }
    }

    func testOneSourceContainsMultipleProviders() throws {
        var index = IdentityIndex()
        let key = try objectKey("post-1")
        let firstRevision = try resolve(
            &index,
            declaredRequest(key, version: versionKey("v1"), payload: payload("First", observedAt: dayOne))
        )
        let secondRevision = try resolve(
            &index,
            declaredRequest(key, version: versionKey("v2"), payload: payload("Second", observedAt: dayTwo))
        )
        let record = try XCTUnwrap(firstRevision.record)
        XCTAssertNotEqual(firstRevision.revision?.revisionID, secondRevision.revision?.revisionID)

        let wire = Provider(
            id: try ProviderID(11),
            namespace: ConnectorNamespace("rss"),
            providerKey: "wire.example",
            displayName: "Wire Service",
            createdAt: dayOne
        )
        let site = Provider(
            id: try ProviderID(22),
            namespace: ConnectorNamespace("atom"),
            providerKey: "site.example",
            displayName: "Site Desk",
            createdAt: dayOne
        )
        XCTAssertNotEqual(wire.namespace, site.namespace)
        XCTAssertNotEqual(wire.id, site.id)

        var provenance = Provenance()
        XCTAssertTrue(provenance.attribute(ProviderAttribution(
            revision: try XCTUnwrap(firstRevision.revision?.revisionID),
            provider: wire.id,
            role: .primary,
            createdAt: dayOne
        )))
        XCTAssertTrue(provenance.attribute(ProviderAttribution(
            revision: try XCTUnwrap(secondRevision.revision?.revisionID),
            provider: wire.id,
            role: .primary,
            createdAt: dayTwo
        )))
        XCTAssertTrue(provenance.attribute(ProviderAttribution(
            revision: try XCTUnwrap(secondRevision.revision?.revisionID),
            provider: site.id,
            role: .publisher,
            evidenceKey: "atom:author",
            createdAt: dayTwo
        )))

        XCTAssertEqual(provenance.attributions.count, 3)
        XCTAssertEqual(Set(provenance.attributions.map(\.provider)), [wire.id, site.id])
        XCTAssertEqual(provenance.attributions.filter { $0.role == .primary }.map(\.provider), [wire.id, wire.id])
        XCTAssertEqual(index.revisions(of: record).count, 2)
        XCTAssertTrue(provenance.memberships.isEmpty, "attribution is not membership")
        XCTAssertTrue(provenance.observations.isEmpty, "attribution is not an observation")
    }

    func testBindingChangeInvalidatesOldGeneration() throws {
        let binding = try SourceBinding(
            key: SourceBindingKey(namespace: ConnectorNamespace("rss"), bindingKey: "feed-a"),
            sourceID: try SourceID(7),
            configurationJSON: #"{"endpoint":"https://a.example/feed.xml"}"#
        )
        let batch = AcquisitionBatch(
            batchID: "batch-1",
            fingerprint: "fingerprint-1",
            targetID: AcquisitionTargetID("target-a"),
            generation: binding.generation,
            observations: []
        )
        XCTAssertTrue(binding.accepts(generation: batch.generation))

        let reconfigured = try binding.advanced(to: #"{"endpoint":"https://a.example/v2.xml"}"#)
        XCTAssertFalse(
            reconfigured.accepts(generation: batch.generation),
            "work stamped for the previous binding generation is not eligible"
        )
        XCTAssertTrue(reconfigured.accepts(generation: reconfigured.generation))
        XCTAssertEqual(reconfigured.key, binding.key)
        XCTAssertEqual(reconfigured.state, .enabled)

        // A revoked binding refuses its own current generation too, and keeps its identity.
        let revoked = reconfigured.revoked()
        XCTAssertFalse(revoked.accepts(generation: reconfigured.generation))
        XCTAssertEqual(revoked.sourceID, reconfigured.sourceID)
        XCTAssertEqual(revoked.key, reconfigured.key)

        // Disablement is the same: eligibility changes, identity does not.
        let disabled = reconfigured.disabled()
        XCTAssertFalse(disabled.accepts(generation: reconfigured.generation))
        XCTAssertEqual(disabled.sourceID, reconfigured.sourceID)
        XCTAssertEqual(disabled.generation, reconfigured.generation)

        XCTAssertThrowsError(
            try SourceBinding(
                key: binding.key,
                sourceID: binding.sourceID,
                configurationJSON: binding.configurationJSON,
                generation: 0
            )
        ) { error in
            XCTAssertEqual(error as? SourceBindingError, .nonPositiveGeneration(0))
        }

        // The generation counter is monotonic and never wraps a stale generation into eligibility.
        let exhausted = try SourceBinding(
            key: binding.key,
            sourceID: binding.sourceID,
            configurationJSON: binding.configurationJSON,
            generation: UInt64.max
        )
        XCTAssertThrowsError(try exhausted.advanced(to: "{}")) { error in
            XCTAssertEqual(error as? SourceBindingError, .generationExhausted)
        }
    }

    func testTargetIsIndependentOfSourceIdentity() throws {
        let target = AcquisitionTargetID("shared-target")
        let firstSource = try SourceID(7)
        let secondSource = try SourceID(8)
        let firstBinding = try SourceBinding(
            key: SourceBindingKey(namespace: ConnectorNamespace("rss"), bindingKey: "feed-a"),
            sourceID: firstSource,
            configurationJSON: "{}"
        )
        let secondBinding = try SourceBinding(
            key: SourceBindingKey(namespace: ConnectorNamespace("rss"), bindingKey: "feed-b"),
            sourceID: secondSource,
            configurationJSON: "{}"
        )
        XCTAssertEqual(firstBinding.sourceID, firstSource)
        XCTAssertEqual(secondBinding.sourceID, secondSource)

        var provenance = Provenance()
        provenance.record(TargetObservation(
            target: target,
            binding: firstBinding.key,
            bindingGeneration: firstBinding.generation,
            key: try objectKey("post-1"),
            observedAt: dayOne
        ))
        provenance.record(TargetObservation(
            target: target,
            binding: secondBinding.key,
            bindingGeneration: secondBinding.generation,
            key: try objectKey("post-2"),
            observedAt: dayOne
        ))

        XCTAssertEqual(Set(provenance.observations.map(\.target)), [target], "one target, two bindings")
        XCTAssertTrue(provenance.memberships.isEmpty, "a target observation enrolls no source")
        XCTAssertEqual(firstBinding.sourceID, firstSource, "sharing a target rewrites no source")
        XCTAssertEqual(secondBinding.sourceID, secondSource)

        // Two identities through the shared target stay two records.
        var index = IdentityIndex()
        _ = try resolve(&index, declaredRequest(try objectKey("post-1"), payload: payload("One")))
        _ = try resolve(&index, declaredRequest(try objectKey("post-2"), payload: payload("Two")))
        XCTAssertEqual(index.recordCount, 2)
    }

    // MARK: - D8, D9, D11: external keys, versions and collisions

    func testSameExternalKeyResolvesSameRecord() throws {
        var index = IdentityIndex()
        let key = try objectKey("post-1")
        let version = try versionKey("v1")

        let first = try resolve(&index, declaredRequest(key, version: version, payload: payload("Once")))
        let second = try resolve(&index, declaredRequest(key, version: version, payload: payload("Once")))

        XCTAssertTrue(first.isNewRecord)
        XCTAssertFalse(second.isNewRecord)
        XCTAssertEqual(second.record, first.record)
        XCTAssertEqual(second.revision, .duplicate(try XCTUnwrap(first.revision?.revisionID)))
        XCTAssertEqual(index.recordCount, 1)
        XCTAssertEqual(index.revisionCount, 1)
        XCTAssertEqual(index.identityCount, 2, "one object key and one version key")
        XCTAssertEqual(index.revisions(of: try XCTUnwrap(first.record)).count, 1)
        let stored = try XCTUnwrap(index.revision(try XCTUnwrap(first.revision?.revisionID)))
        XCTAssertEqual(stored.record, first.record)
        XCTAssertEqual(stored.versionKey, version)

        // Another scope is another object, even with the same bytes (D8).
        let otherScope = try objectKey("post-1", scope: "feed:2")
        let elsewhere = try resolve(&index, declaredRequest(otherScope, payload: payload("Once")))
        XCTAssertTrue(elsewhere.isNewRecord)
        XCTAssertNotEqual(elsewhere.record, first.record)
        XCTAssertEqual(index.recordCount, 2)
    }

    func testRevisionPayloadCannotBeUpdated() throws {
        var index = IdentityIndex()
        let key = try objectKey("post-1")
        let version = try versionKey("v1")
        let admitted = try resolve(
            &index,
            declaredRequest(key, version: version, payload: payload("Headline one"))
        )
        let record = try XCTUnwrap(admitted.record)
        let revisionID = try XCTUnwrap(admitted.revision?.revisionID)
        let stored = try XCTUnwrap(index.revision(revisionID))

        // The same version key with a divergent payload: the stored revision is preserved and the
        // contradiction is recorded instead of overwriting anything (D11, invariant 4).
        let divergent = try resolve(
            &index,
            declaredRequest(key, version: version, payload: payload("Headline two"))
        )
        XCTAssertEqual(divergent.revision, .divergentPayloadPreserved(stored: revisionID))
        XCTAssertEqual(index.revision(revisionID), stored, "the stored revision is unchanged")
        XCTAssertEqual(index.revisions(of: record).count, 1, "nothing was appended")
        let conflict = try XCTUnwrap(divergent.conflicts.first)
        XCTAssertEqual(conflict.kind, .versionPayloadDivergence)
        XCTAssertEqual(conflict.storedPayloadDigest, stored.payloadDigest)
        XCTAssertNotNil(conflict.incomingPayloadDigest)
        XCTAssertNotEqual(conflict.storedPayloadDigest, conflict.incomingPayloadDigest)
        XCTAssertEqual(index.conflicts.last, conflict)

        // A different version key appends a new immutable revision, and the first one survives.
        let next = try resolve(
            &index,
            declaredRequest(key, version: versionKey("v2"), payload: payload("Headline two"))
        )
        XCTAssertTrue(try XCTUnwrap(next.revision).isAppended)
        XCTAssertNotEqual(next.revision?.revisionID, revisionID)
        XCTAssertEqual(index.revision(revisionID), stored)
        XCTAssertEqual(index.revisions(of: record).count, 2)
    }

    func testVersionKeyIsNotAssumedGloballyOrdered() throws {
        var index = IdentityIndex()
        let key = try objectKey("post-1")
        let laterArrival = try versionKey("z")
        let earlierArrival = try versionKey("a")

        _ = try resolve(
            &index,
            declaredRequest(key, version: laterArrival, payload: payload("Seen first", observedAt: dayOne))
        )
        _ = try resolve(
            &index,
            declaredRequest(key, version: earlierArrival, payload: payload("Seen second", observedAt: dayTwo))
        )

        let record = try XCTUnwrap(index.record(for: key))
        let revisions = index.revisions(of: record)
        XCTAssertEqual(
            revisions.map(\.versionKey),
            [laterArrival, earlierArrival],
            "revisions stay in append order; nothing sorts by version key"
        )
        XCTAssertEqual(revisions.count, 2, "a lexically smaller version key replaces nothing")
        XCTAssertEqual(revisions.map(\.payload.headline), ["Seen first", "Seen second"])

        // The kind is part of the key space: the same bytes as an object key and as a version key are
        // two different identities, and neither is refused.
        var kindScoped = IdentityIndex()
        let object = try objectKey("same-bytes")
        let version = try versionKey("same-bytes")
        XCTAssertEqual(object.bytes, version.bytes)
        XCTAssertNotEqual(AnyHashable(object), AnyHashable(version))
        let asObject = try resolve(&kindScoped, declaredRequest(object, payload: payload("Object")))
        let asVersion = try resolve(
            &kindScoped,
            declaredRequest(try objectKey("other"), version: version, payload: payload("Version"))
        )
        XCTAssertTrue(asObject.isNewRecord)
        XCTAssertTrue(asVersion.isNewRecord)
        XCTAssertEqual(kindScoped.identityCount, 3, "one version key + two object keys")
    }

    func testDigestCollisionComparesFullExternalKey() throws {
        var index = IdentityIndex(digestPolicy: ConstantIdentityDigest())
        let firstKey = try objectKey("key-a")
        let secondKey = try objectKey("key-b")

        let first = try resolve(&index, declaredRequest(firstKey, payload: payload("A")))
        let second = try resolve(&index, declaredRequest(secondKey, payload: payload("B")))

        XCTAssertTrue(first.isNewRecord)
        XCTAssertTrue(second.isNewRecord, "a shared digest never joins two records")
        XCTAssertNotEqual(first.record, second.record)
        XCTAssertEqual(index.recordCount, 2)
        XCTAssertEqual(index.identityCount, 2)

        let conflict = try XCTUnwrap(second.conflicts.first)
        XCTAssertEqual(conflict.kind, .digestCollision)
        XCTAssertEqual(conflict.incomingKeyDigest, ConstantIdentityDigest.constant)
        XCTAssertEqual(conflict.existingRecord, first.record)
        XCTAssertEqual(conflict.claimingRecord, second.record)
        XCTAssertEqual(conflict.scope, .external(scopeKey()))

        // Each key keeps resolving to its own record, with its own payload.
        let again = try resolve(&index, declaredRequest(firstKey, payload: payload("A")))
        XCTAssertEqual(again.record, first.record)
        XCTAssertEqual(again.revision, .duplicate(try XCTUnwrap(first.revision?.revisionID)))
        XCTAssertEqual(index.records.map(\.primaryIdentity.key), [firstKey, secondKey])
    }

    func testOpaqueGuidIsNotUrlNormalized() throws {
        var index = IdentityIndex()
        let signed = "https://cdn.example/ep1.mp3?X-Amz-Signature=aaa&X-Amz-Expires=60"
        let resigned = "https://cdn.example/ep1.mp3?X-Amz-Signature=bbb&X-Amz-Expires=60"

        let first = try resolve(&index, declaredRequest(try objectKey(signed), payload: payload("Episode")))
        let second = try resolve(&index, declaredRequest(try objectKey(resigned), payload: payload("Episode")))

        XCTAssertTrue(first.isNewRecord)
        XCTAssertTrue(second.isNewRecord)
        XCTAssertNotEqual(first.record, second.record, "two signatures are two objects")
        XCTAssertEqual(index.recordCount, 2)
        XCTAssertEqual(
            index.record(try XCTUnwrap(first.record))?.primaryIdentity.key.bytes,
            Data(signed.utf8),
            "the key is stored byte-identical to what the connector supplied"
        )
        XCTAssertNil(
            index.record(for: try objectKey("https://cdn.example/ep1.mp3")),
            "no scheme/parameter-normalized form was ever minted"
        )
    }

    // MARK: - D12: aliases

    func testAmbiguousAliasDoesNotMergeOrigins() throws {
        var index = IdentityIndex()
        let firstKey = try objectKey("a")
        let secondKey = try objectKey("b")
        let first = try resolve(&index, declaredRequest(firstKey, payload: payload("A")))
        let second = try resolve(&index, declaredRequest(secondKey, payload: payload("B")))
        let firstRecord = try XCTUnwrap(first.record)
        let secondRecord = try XCTUnwrap(second.record)
        XCTAssertNotEqual(firstRecord, secondRecord)

        // Aliases add evidence: the key now resolves to the first record.
        let aliasKey = try objectKey("alias")
        let attached = try index.attachAlias(aliasKey, to: firstRecord, observedAt: dayTwo)
        XCTAssertNil(attached)
        XCTAssertEqual(index.record(for: aliasKey), firstRecord)

        // The same key claimed by another record is refused: neither record moves.
        let conflict = try index.attachAlias(aliasKey, to: secondRecord, observedAt: dayTwo)
        XCTAssertEqual(conflict?.kind, .ambiguousAlias)
        XCTAssertEqual(conflict?.existingRecord, firstRecord)
        XCTAssertEqual(conflict?.claimingRecord, secondRecord)
        XCTAssertEqual(index.record(for: aliasKey), firstRecord)
        XCTAssertEqual(index.recordCount, 2, "both records survive an ambiguous alias")
        XCTAssertEqual(index.revisions(of: firstRecord).count, 1)
        XCTAssertEqual(index.revisions(of: secondRecord).count, 1)
        XCTAssertEqual(index.record(firstRecord)?.primaryIdentity.key, firstKey, "no identity row was rewritten")
        XCTAssertEqual(index.conflicts.last, conflict)

        // A version key claimed by a second record is the same refusal.
        let sharedVersion = try versionKey("v-shared")
        _ = try resolve(
            &index,
            declaredRequest(firstKey, version: sharedVersion, payload: payload("A2", observedAt: dayTwo))
        )
        let refused = try resolve(
            &index,
            declaredRequest(secondKey, version: sharedVersion, payload: payload("B2", observedAt: dayTwo))
        )
        XCTAssertEqual(refused.refusal?.kind, .ambiguousAlias)
        XCTAssertEqual(refused.refusal?.existingRecord, firstRecord)
        XCTAssertEqual(refused.refusal?.claimingRecord, secondRecord)
        XCTAssertEqual(index.record(for: secondKey), secondRecord)

        // An alias never names a record the index does not hold.
        let missing = try OriginRecordID(999)
        XCTAssertThrowsError(
            try index.attachAlias(try objectKey("c"), to: missing, observedAt: dayTwo)
        ) { error in
            XCTAssertEqual(error as? IdentityIndexError, .unknownRecord(missing))
        }
    }

    // MARK: - D15, D13, D14: membership, equivalence, relations

    func testTargetObservationDoesNotImplyMembership() throws {
        let target = AcquisitionTargetID("target-a")
        let binding = SourceBindingKey(namespace: ConnectorNamespace("rss"), bindingKey: "feed-a")
        var provenance = Provenance()

        provenance.record(TargetObservation(
            target: target,
            binding: binding,
            bindingGeneration: 1,
            key: try objectKey("post-1"),
            observedAt: dayOne
        ))
        XCTAssertEqual(provenance.observations.count, 1)
        XCTAssertTrue(provenance.memberships.isEmpty, "observing through a target enrolls nothing")

        var index = IdentityIndex()
        let admitted = try resolve(&index, declaredRequest(try objectKey("post-1"), payload: payload("A")))
        let record = try XCTUnwrap(admitted.record)
        let editorial = SourceMembership(
            record: record,
            sourceID: try SourceID(7),
            membershipKind: "catalog",
            evidence: .editorial,
            firstObservedAt: dayOne,
            lastObservedAt: dayOne
        )
        XCTAssertTrue(provenance.claim(editorial))
        XCTAssertEqual(provenance.observations.count, 1, "claiming a membership observes nothing")
        XCTAssertEqual(provenance.attributions.count, 0)
        XCTAssertFalse(provenance.claim(editorial), "a claim is keyed by (record, source, kind)")

        // An acquisition-backed claim keeps how it was known.
        let acquired = SourceMembership(
            record: record,
            sourceID: try SourceID(8),
            membershipKind: "target",
            evidence: .acquisition(target: target, binding: binding, bindingGeneration: 3),
            firstObservedAt: dayTwo,
            lastObservedAt: dayTwo
        )
        XCTAssertTrue(provenance.claim(acquired))
        XCTAssertEqual(provenance.memberships.count, 2)
        XCTAssertEqual(provenance.memberships.last?.evidence, .acquisition(target: target, binding: binding, bindingGeneration: 3))
    }

    func testClusterSplitPreservesOriginalRecords() throws {
        var index = IdentityIndex()
        let firstKey = try objectKey("a")
        let secondKey = try objectKey("b")
        let first = try resolve(&index, declaredRequest(firstKey, payload: payload("A", observedAt: dayOne)))
        let second = try resolve(&index, declaredRequest(secondKey, payload: payload("B", observedAt: dayTwo)))
        let firstRecord = try XCTUnwrap(first.record)
        let secondRecord = try XCTUnwrap(second.record)

        var relations = ContentEquivalence()
        XCTAssertTrue(relations.declare(ContentEntityMember(
            entityID: 9,
            record: firstRecord,
            method: "syndication",
            version: 1,
            createdAt: dayOne
        )))
        XCTAssertTrue(relations.declare(ContentEntityMember(
            entityID: 9,
            record: secondRecord,
            method: "syndication",
            version: 1,
            createdAt: dayOne
        )))
        XCTAssertFalse(
            relations.declare(ContentEntityMember(
                entityID: 9,
                record: firstRecord,
                method: "syndication",
                version: 1,
                createdAt: dayTwo
            )),
            "the relation row is keyed by (entity, record)"
        )
        XCTAssertTrue(relations.declare(try ContentClusterMember(
            clusterID: 4,
            record: firstRecord,
            confidence: 0.9,
            method: "simhash",
            version: 2,
            createdAt: dayOne
        )))
        XCTAssertTrue(relations.declare(try ContentClusterMember(
            clusterID: 4,
            record: secondRecord,
            confidence: 0.72,
            method: "simhash",
            version: 2,
            createdAt: dayOne
        )))
        XCTAssertEqual(relations.entityID(of: firstRecord), 9)
        XCTAssertEqual(relations.clusterIDs(of: secondRecord), [4])
        XCTAssertEqual(relations.clusterMembers.map(\.confidence), [0.9, 0.72])
        XCTAssertThrowsError(try ContentClusterMember(
            clusterID: 4,
            record: firstRecord,
            confidence: 1.5,
            method: "simhash",
            version: 2,
            createdAt: dayOne
        )) { error in
            XCTAssertEqual(error as? RelationsError, .clusterConfidenceOutOfRange(1.5))
        }

        let recordsBefore = index.records
        let revisionsBefore = index.revisions(of: firstRecord)
        relations.split()

        XCTAssertTrue(relations.isEmpty)
        XCTAssertEqual(index.records, recordsBefore, "the relation never owned a record")
        XCTAssertEqual(index.revisions(of: firstRecord), revisionsBefore)
        let again = try resolve(&index, declaredRequest(firstKey, payload: payload("A", observedAt: dayOne)))
        XCTAssertEqual(again.record, firstRecord, "each record is still individually resolvable")
        XCTAssertEqual(again.revision, .duplicate(try XCTUnwrap(first.revision?.revisionID)))
        XCTAssertNotEqual(again.record, secondRecord)
    }

    func testUnknownExternalRelationStaysEvidence() throws {
        var index = IdentityIndex()
        let subject = try XCTUnwrap(
            try resolve(&index, declaredRequest(try objectKey("a"), payload: payload("A"))).record
        )
        let object = try objectKey("b")

        let unsupported = ConnectorEvidence(
            kind: .other,
            digest: "bookmarkOf",
            bytes: Data("bookmarkOf".utf8)
        )
        XCTAssertNil(
            ContentRelation(subject: subject, declaredVerb: "bookmarkOf", target: .externalKey(object), createdAt: dayOne),
            "a verb outside the four promoted relations writes no canonical relation"
        )
        XCTAssertEqual(unsupported.bytes, Data("bookmarkOf".utf8))

        for verb in ContentRelation.Verb.allCases {
            let relation = ContentRelation(
                subject: subject,
                declaredVerb: verb.rawValue,
                target: .externalKey(object),
                createdAt: dayOne
            )
            XCTAssertEqual(relation?.verb, verb)
        }

        // An unresolved object stays an opaque key: no record is invented for it.
        let reply = try XCTUnwrap(ContentRelation(
            subject: subject,
            declaredVerb: "replyTo",
            target: .externalKey(object),
            createdAt: dayOne
        ))
        XCTAssertEqual(reply.target, .externalKey(object))
        XCTAssertNil(index.record(for: object))
    }

    // MARK: - D16, D17, D18: timestamps, fallback identity, legacy bridge

    func testMissingAuthoredAtDoesNotBecomeClaimedPublicationDate() throws {
        var index = IdentityIndex()
        let undated = payload("Headline", link: "https://a.example/post", authoredAt: nil, observedAt: dayTwo)
        let admitted = try resolve(
            &index,
            declaredRequest(try objectKey("a"), version: versionKey("v1"), payload: undated)
        )
        let revision = try XCTUnwrap(index.revision(try XCTUnwrap(admitted.revision?.revisionID)))

        XCTAssertNil(revision.payload.authoredAt)
        XCTAssertNil(revision.payload.modifiedAt)
        XCTAssertEqual(revision.payload.observedAt, dayTwo, "observedAt is always the local time")

        let policy = SortDatePolicy(version: 2)
        let sorted = policy.outcome(for: revision.payload)
        XCTAssertEqual(sorted.date, dayTwo)
        XCTAssertTrue(sorted.isFallback, "the sort date is reported as a fallback, not as authored")
        XCTAssertEqual(sorted.policyVersion, 2, "the outcome names the policy that produced it")

        // A declared authored date is used as declared, even when it is skewed against the clock.
        let skewed = payload("Headline", authoredAt: dayThree, observedAt: dayTwo)
        let skewedOutcome = policy.outcome(for: skewed)
        XCTAssertEqual(skewedOutcome.date, dayThree)
        XCTAssertFalse(skewedOutcome.isFallback)
        XCTAssertEqual(skewed.authoredAt, dayThree, "never clamped and never replaced")
    }

    func testIdenticalTitleAndDateFallbackKeepsBothRecords() throws {
        var index = IdentityIndex()
        let scheme = try FallbackIdentityScheme()
        let title = "No GUID, no link"
        let firstKey = try scheme.key(scope: scopeKey(), title: title, authoredAt: dayOne, disambiguator: "entry-1")
        let secondKey = try scheme.key(scope: scopeKey(), title: title, authoredAt: dayOne, disambiguator: "entry-2")
        XCTAssertNotEqual(firstKey, secondKey)

        let first = try resolve(
            &index,
            fallbackRequest(firstKey, payload: payload(title, authoredAt: dayOne), scheme: scheme)
        )
        let second = try resolve(
            &index,
            fallbackRequest(secondKey, payload: payload(title, authoredAt: dayOne), scheme: scheme)
        )

        XCTAssertTrue(first.isNewRecord)
        XCTAssertTrue(second.isNewRecord)
        XCTAssertNotEqual(first.record, second.record, "identical title and date never merge")
        XCTAssertEqual(first.confidence, .low)
        XCTAssertEqual(second.confidence, .low)
        XCTAssertEqual(first.fallbackSchemeVersion, FallbackIdentityScheme.currentVersion)
        XCTAssertEqual(index.recordCount, 2)
        let firstRecord = try XCTUnwrap(first.record)
        XCTAssertEqual(index.revisions(of: firstRecord).map(\.payload.headline), [title])
        XCTAssertEqual(
            index.revisions(of: try XCTUnwrap(second.record)).map(\.payload.headline),
            [title]
        )

        // The identity does not silently gain confidence when a declared request re-observes it.
        let reobserved = try resolve(&index, declaredRequest(firstKey, payload: payload(title, authoredAt: dayOne)))
        XCTAssertEqual(reobserved.record, first.record)
        XCTAssertEqual(reobserved.confidence, .low)
        XCTAssertEqual(reobserved.revision, .duplicate(try XCTUnwrap(first.revision?.revisionID)))
        XCTAssertEqual(index.revisions(of: firstRecord).first?.identityConfidence, .low)

        // Even a collision on one fallback key discards nothing: the changed payload is a new
        // revision of that record.
        let collided = try resolve(
            &index,
            fallbackRequest(firstKey, payload: payload("Different text", authoredAt: dayOne), scheme: scheme)
        )
        XCTAssertTrue(try XCTUnwrap(collided.revision).isAppended)
        XCTAssertEqual(
            index.revisions(of: firstRecord).map(\.payload.headline),
            [title, "Different text"]
        )
        XCTAssertEqual(index.recordCount, 2)

        // A low-confidence identity always names its scheme, and the scheme version is part of the
        // derived key: a new scheme cannot silently reuse a v1 identity.
        XCTAssertThrowsError(
            try ExternalIdentityRef(key: firstKey, confidence: .low, fallbackSchemeVersion: nil)
        ) { error in
            XCTAssertEqual(error as? ExternalIdentityError, .lowConfidenceWithoutFallbackScheme)
        }
        let secondScheme = try FallbackIdentityScheme(version: 2)
        XCTAssertNotEqual(
            try secondScheme.key(scope: scopeKey(), material: Data("material".utf8)),
            try scheme.key(scope: scopeKey(), material: Data("material".utf8))
        )
        XCTAssertThrowsError(try FallbackIdentityScheme(version: 0)) { error in
            XCTAssertEqual(error as? ExternalIdentityError, .nonPositiveFallbackSchemeVersion(0))
        }
    }

    func testHeadlineAndLinkMayBeAbsent() throws {
        var index = IdentityIndex()
        let bare = payload(nil, link: nil, authoredAt: nil, observedAt: dayTwo)
        let admitted = try resolve(&index, declaredRequest(try objectKey("bare"), payload: bare))
        let revision = try XCTUnwrap(index.revision(try XCTUnwrap(admitted.revision?.revisionID)))

        XCTAssertNil(revision.payload.headline)
        XCTAssertNil(revision.payload.link, "no synthetic HTTP URL is ever written")
        XCTAssertNil(revision.payload.authoredAt)
        XCTAssertEqual(index.revisions(of: try XCTUnwrap(admitted.record)).count, 1)

        // D18: the legacy bridge never guesses. An unmapped legacy id is recorded as unresolved.
        let legacyURL = "https://a.example/feed.xml"
        let unmapped = LegacyItemMapping.unresolved(
            legacyItemID: "legacy-1",
            legacySourceURL: legacyURL,
            mappedAt: dayTwo
        )
        let mapped = LegacyItemMapping(
            legacyItemID: "legacy-2",
            legacySourceURL: legacyURL,
            record: admitted.record,
            revision: admitted.revision?.revisionID,
            confidence: .high,
            mappedAt: dayTwo
        )
        let itemMap = try LegacyItemMap([unmapped, mapped])
        let unresolved = try itemMap.mapping(forLegacyItemID: "legacy-1")
        XCTAssertEqual(unresolved.confidence, .unresolved)
        XCTAssertNil(unresolved.record)
        XCTAssertNil(unresolved.revision)
        XCTAssertEqual(try itemMap.mapping(forLegacyItemID: "legacy-2").record, admitted.record)
        XCTAssertThrowsError(try itemMap.mapping(forLegacyItemID: "legacy-9")) { error in
            XCTAssertEqual(error as? LegacyMappingError, .missingItemMapping(legacyItemID: "legacy-9"))
        }

        // Two rows claiming one legacy id are refused outright, not resolved by last-write-wins.
        let contested = LegacyItemMapping(
            legacyItemID: "legacy-2",
            legacySourceURL: legacyURL,
            record: try OriginRecordID(999),
            revision: nil,
            confidence: .low,
            mappedAt: dayThree
        )
        XCTAssertThrowsError(try LegacyItemMap([mapped, contested])) { error in
            XCTAssertEqual(error as? LegacyMappingError, .conflictingItemMapping(legacyItemID: "legacy-2"))
        }
    }

    func testCatalogRebuildReappliesPersistedSourceMap() throws {
        let version = 1
        let keyA = try EditorialSourceKey(catalogIdentity: "source:a", canonicalizationVersion: version)
        let keyB = try EditorialSourceKey(catalogIdentity: "source:b", canonicalizationVersion: version)
        let keyC = try EditorialSourceKey(catalogIdentity: "source:c", canonicalizationVersion: version)
        let sourceA = try SourceID(7)
        let sourceB = try SourceID(8)
        let sourceC = try SourceID(9)
        let catalogA = CatalogSourceID(1)
        let catalogB = CatalogSourceID(2)
        let catalogC = CatalogSourceID(3)
        let rows = [
            LegacySourceMapping(editorialKey: keyA, catalogSourceID: catalogA, runtimeSourceID: sourceA, legacyURL: "https://a.example/feed.xml", mappedAt: dayOne),
            LegacySourceMapping(editorialKey: keyB, catalogSourceID: catalogB, runtimeSourceID: sourceB, legacyURL: "https://b.example/feed.xml", mappedAt: dayOne),
            LegacySourceMapping(editorialKey: keyC, catalogSourceID: catalogC, runtimeSourceID: sourceC, legacyURL: "https://c.example/feed.xml", mappedAt: dayOne),
        ]
        var map = LegacySourceMap(rows)

        XCTAssertEqual(try map.runtimeSource(forCatalogSource: catalogA, canonicalizationVersion: version), sourceA)
        XCTAssertEqual(map.catalogSources(forRuntimeSource: sourceB, canonicalizationVersion: version), [catalogB])

        // Re-applying the same mappings changes nothing and allocates nothing.
        XCTAssertTrue(map.reapply(rows).isEmpty)
        XCTAssertEqual(try map.runtimeSource(forCatalogSource: catalogA, canonicalizationVersion: version), sourceA)
        XCTAssertEqual(map.rows.map(\.runtimeSourceID), [sourceA, sourceB, sourceC])

        // A rebuild that no longer mentions a source leaves that mapping in place.
        let rebuilt = Array(rows.dropLast())
        XCTAssertTrue(map.reapply(rebuilt).isEmpty)
        XCTAssertEqual(
            try map.runtimeSource(forCatalogSource: catalogC, canonicalizationVersion: version),
            sourceC,
            "a source the rebuild does not mention stays mapped to the same runtime source"
        )
        XCTAssertEqual(map.rows.count, 3)

        // A contested claim is refused and recorded instead of silently re-pointing the mapping.
        let contestedSource = try SourceID(12)
        let contested = [LegacySourceMapping(
            editorialKey: keyA,
            catalogSourceID: catalogA,
            runtimeSourceID: contestedSource,
            legacyURL: "https://a.example/feed.xml",
            mappedAt: dayThree
        )]
        let recorded = map.reapply(contested)
        XCTAssertEqual(recorded.map(\.kind), [.legacyMapConflict])
        XCTAssertEqual(recorded.first?.existingSource, sourceA)
        XCTAssertEqual(recorded.first?.claimedSource, contestedSource)
        XCTAssertEqual(recorded.first?.scope, .legacyBridge(keyA))
        XCTAssertEqual(try map.runtimeSource(forCatalogSource: catalogA, canonicalizationVersion: version), sourceA)
        XCTAssertEqual(map.conflicts.count, 1)

        // D2: an unknown catalogue id is an error, never a derived identity.
        let unknown = CatalogSourceID(99)
        XCTAssertThrowsError(
            try map.runtimeSource(forCatalogSource: unknown, canonicalizationVersion: version)
        ) { error in
            XCTAssertEqual(
                error as? LegacyMappingError,
                .missingSourceMapping(catalogSourceID: unknown, canonicalizationVersion: version)
            )
        }

        // The durable key is a value key: it must have content and a positive version (D4).
        XCTAssertThrowsError(
            try EditorialSourceKey(catalogIdentity: "", canonicalizationVersion: version)
        ) { error in
            XCTAssertEqual(error as? EditorialIdentityError, .emptyCatalogIdentity)
        }
        XCTAssertThrowsError(
            try EditorialSourceKey(catalogIdentity: "source:a", canonicalizationVersion: 0)
        ) { error in
            XCTAssertEqual(error as? EditorialIdentityError, .nonPositiveCanonicalizationVersion(0))
        }

        // Two durable keys claiming one catalogue id for two different runtime sources are
        // ambiguous. The lookup refuses instead of picking one.
        let renamed = try EditorialSourceKey(catalogIdentity: "source:a-renamed", canonicalizationVersion: version)
        let ambiguous = LegacySourceMap([
            rows[0],
            LegacySourceMapping(
                editorialKey: renamed,
                catalogSourceID: catalogA,
                runtimeSourceID: contestedSource,
                legacyURL: "https://a.example/feed-old.xml",
                mappedAt: dayThree
            ),
        ])
        XCTAssertThrowsError(
            try ambiguous.runtimeSource(forCatalogSource: catalogA, canonicalizationVersion: version)
        ) { error in
            XCTAssertEqual(
                error as? LegacyMappingError,
                .conflictingSourceMapping(
                    catalogSourceID: catalogA,
                    canonicalizationVersion: version,
                    runtimeSourceIDs: [sourceA, contestedSource]
                )
            )
        }

        // Two rows claiming one durable key for two different runtime sources are recorded at
        // construction: the first mapping stands and the claim is refused, never silently applied.
        let duplicateRows = LegacySourceMap([
            rows[0],
            LegacySourceMapping(
                editorialKey: keyA,
                catalogSourceID: catalogA,
                runtimeSourceID: contestedSource,
                legacyURL: rows[0].legacyURL,
                mappedAt: dayThree
            ),
        ])
        XCTAssertEqual(duplicateRows.conflicts.map(\.kind), [.legacyMapConflict])
        XCTAssertEqual(
            try duplicateRows.runtimeSource(forCatalogSource: catalogA, canonicalizationVersion: version),
            sourceA
        )
    }

    // MARK: - D3: identifiers

    func testZeroSourceIDIsNotPersistable() throws {
        XCTAssertThrowsError(try SourceID(0)) { error in
            XCTAssertEqual(error as? RuntimeIDError, .reservedZero(SourceID.self))
        }
        XCTAssertThrowsError(try RuntimeRowID.checked(0))
        XCTAssertThrowsError(try RuntimeRowID.checked(-1))
        XCTAssertThrowsError(try OriginRecordID(0))

        var index = IdentityIndex()
        let first = try resolve(&index, declaredRequest(try objectKey("a"), payload: payload("A")))
        let second = try resolve(&index, declaredRequest(try objectKey("b"), payload: payload("B")))
        let firstRecord = try XCTUnwrap(first.record)
        let secondRecord = try XCTUnwrap(second.record)
        XCTAssertGreaterThan(firstRecord.rawValue, 0)
        XCTAssertGreaterThan(secondRecord.rawValue, firstRecord.rawValue)
        XCTAssertGreaterThan(try XCTUnwrap(first.revision?.revisionID).rawValue, 0)

        // Allocation refuses the reserved zero and refuses to wrap around the identifier space.
        XCTAssertThrowsError(try IdentifierCounter(next: 0))
        XCTAssertThrowsError(try IdentifierCounter(next: -1))
        var exhausted = try IdentifierCounter(next: Int64.max)
        XCTAssertThrowsError(try exhausted.allocate()) { error in
            XCTAssertEqual(error as? RuntimeIDError, .identifierSpaceExhausted(Int64.max))
        }
    }

    // MARK: - D9, D11: versionless observations

    func testVersionlessObservationDoesNotDuplicateRevision() throws {
        var index = IdentityIndex()
        let key = try objectKey("a")
        let admitted = try resolve(&index, declaredRequest(key, payload: payload("A", observedAt: dayOne)))
        let record = try XCTUnwrap(admitted.record)
        let revisionID = try XCTUnwrap(admitted.revision?.revisionID)

        let repeated = try resolve(&index, declaredRequest(key, payload: payload("A", observedAt: dayTwo)))
        XCTAssertEqual(repeated.revision, .duplicate(revisionID))
        XCTAssertEqual(index.revisions(of: record).count, 1)

        let changed = try resolve(&index, declaredRequest(key, payload: payload("B", observedAt: dayThree)))
        XCTAssertTrue(try XCTUnwrap(changed.revision).isAppended)
        XCTAssertNotEqual(changed.revision?.revisionID, revisionID)
        XCTAssertEqual(index.revisions(of: record).count, 2)
        XCTAssertEqual(index.revisions(of: record).map(\.payload.headline), ["A", "B"])

        // The observation window keeps its start and never moves backwards.
        _ = try resolve(&index, declaredRequest(key, payload: payload("B", observedAt: dayOne)))
        XCTAssertEqual(index.record(record)?.firstObservedAt, dayOne)
        XCTAssertEqual(index.record(record)?.lastObservedAt, dayThree)
    }

    // MARK: - D5, D11, D15: attribution and invalid input

    func testProviderAttributionNeverSubstitutesForSource() throws {
        var index = IdentityIndex()
        let key = try objectKey("a")
        let admitted = try resolve(
            &index,
            declaredRequest(key, version: versionKey("v1"), payload: payload("A"))
        )
        let record = try XCTUnwrap(admitted.record)
        let revision = try XCTUnwrap(admitted.revision?.revisionID)
        let source = try SourceID(7)
        let binding = try SourceBinding(
            key: SourceBindingKey(namespace: ConnectorNamespace("rss"), bindingKey: "feed-a"),
            sourceID: source,
            configurationJSON: "{}"
        )
        let wire = try ProviderID(11)
        let site = try ProviderID(22)

        var provenance = Provenance()
        XCTAssertTrue(provenance.attribute(ProviderAttribution(
            revision: revision,
            provider: wire,
            role: .primary,
            createdAt: dayOne
        )))
        XCTAssertTrue(provenance.attribute(ProviderAttribution(
            revision: revision,
            provider: site,
            role: .contributor,
            createdAt: dayOne
        )))
        XCTAssertFalse(provenance.attribute(ProviderAttribution(
            revision: revision,
            provider: wire,
            role: .primary,
            createdAt: dayTwo
        )), "attribution is keyed by (revision, provider, role)")
        XCTAssertEqual(provenance.attributions.map(\.provider), [wire, site])

        // Nothing source-keyed moves: no membership, the same source the same binding names, the same
        // record identity.
        XCTAssertTrue(provenance.memberships.isEmpty)
        XCTAssertEqual(binding.sourceID, source)
        XCTAssertEqual([binding].map(\.sourceID), [source])
        XCTAssertEqual(index.record(record)?.primaryIdentity.key, key)
        XCTAssertEqual(index.record(for: key), record)
        XCTAssertNotEqual(AnyHashable(wire), AnyHashable(source), "a provider id is not a source id")
    }

    func testInvalidBatchDoesNotMutateCanonicalState() throws {
        var index = IdentityIndex()
        let firstKey = try objectKey("a")
        let secondKey = try objectKey("b")
        let sharedVersion = try versionKey("v-shared")
        let first = try resolve(
            &index,
            declaredRequest(firstKey, version: sharedVersion, payload: payload("A", observedAt: dayOne))
        )
        let second = try resolve(
            &index,
            declaredRequest(secondKey, payload: payload("B", observedAt: dayOne))
        )
        let firstRecord = try XCTUnwrap(first.record)
        let secondRecord = try XCTUnwrap(second.record)

        var provenance = Provenance()
        provenance.record(TargetObservation(
            target: AcquisitionTargetID("target-a"),
            binding: SourceBindingKey(namespace: ConnectorNamespace("rss"), bindingKey: "feed-a"),
            bindingGeneration: 1,
            key: firstKey,
            observedAt: dayOne
        ))
        provenance.claim(SourceMembership(
            record: firstRecord,
            sourceID: try SourceID(7),
            membershipKind: "catalog",
            evidence: .editorial,
            firstObservedAt: dayOne,
            lastObservedAt: dayOne
        ))
        provenance.attribute(ProviderAttribution(
            revision: try XCTUnwrap(first.revision?.revisionID),
            provider: try ProviderID(11),
            role: .primary,
            createdAt: dayOne
        ))
        var relations = ContentEquivalence()
        relations.declare(ContentEntityMember(
            entityID: 9,
            record: firstRecord,
            method: "syndication",
            version: 1,
            createdAt: dayOne
        ))

        let recordsBefore = index.records
        let revisionsBefore = index.revisions(of: firstRecord)
        let conflictsBefore = index.conflicts.count
        let observationsBefore = provenance.observations
        let membershipsBefore = provenance.memberships
        let attributionsBefore = provenance.attributions
        let entityMembersBefore = relations.entityMembers

        // An invalid stamp: a version key that another record already owns. The batch is refused.
        let refused = try resolve(
            &index,
            declaredRequest(secondKey, version: sharedVersion, payload: payload("B2", observedAt: dayTwo))
        )
        XCTAssertNotNil(refused.refusal)
        XCTAssertEqual(index.records, recordsBefore)
        XCTAssertEqual(index.revisions(of: firstRecord), revisionsBefore)
        XCTAssertEqual(index.revisions(of: secondRecord).count, 1)
        XCTAssertEqual(index.conflicts.count, conflictsBefore + 1, "only the conflict log grew")
        XCTAssertEqual(provenance.observations, observationsBefore)
        XCTAssertEqual(provenance.memberships, membershipsBefore)
        XCTAssertEqual(provenance.attributions, attributionsBefore)
        XCTAssertEqual(relations.entityMembers, entityMembersBefore)

        // A key that cannot be represented never reaches the index at all.
        XCTAssertThrowsError(try ExternalObjectKey(scope: scopeKey(), bytes: Data())) { error in
            XCTAssertEqual(error as? ExternalIdentityError, .emptyKeyBytes)
        }
        XCTAssertThrowsError(try ExternalVersionKey(scope: scopeKey(), bytes: Data())) { error in
            XCTAssertEqual(error as? ExternalIdentityError, .emptyKeyBytes)
        }
        XCTAssertEqual(index.records, recordsBefore)
    }
}
