### Amendment — Missing legacy Source mapping and canonicalization lifecycle

**D20 — A missing catalog-to-runtime mapping is resolved only by the legacy Source resolver.** A lookup miss for `(catalog_source_key, canonicalization_version)` in `legacy_source_map` is not permission for the caller to derive, cast or synthesize a `FeedDomain.SourceID`. The bridge policy owner is `LegacySourceIdentityResolver`: it may request creation of a mapping only when the catalog input supplies a valid durable `EditorialSourceKey`, a positive `CatalogSourceID`, and no existing or conflicting durable mapping makes the requested identity ambiguous. If those preconditions are not satisfied, resolution fails explicitly and no Source or mapping is created.

**D21 — `RuntimeSourceRegistry` is the only allocator, and Source allocation plus mapping is one write transaction.** `LegacySourceIdentityResolver` decides whether D20 permits creation; `RuntimeSourceRegistry` performs the SQLite-owned allocation of the runtime `SourceID`. Creation/lookup of the `source` row, conflict validation, insertion of `legacy_source_map`, and read-back of the authoritative mapping occur inside one logical database write transaction. Concurrent resolves of the same durable key must converge on one `source.id` and one mapping. A transaction that cannot establish a single non-conflicting mapping rolls back rather than exposing an allocated-but-unmapped Source to the legacy bridge. If conflict validation finds an existing mapping that diverges from the proposed mapping, that allocation/mapping transaction must roll back completely; after that rollback, durable `legacy_map_conflict` evidence describing the rejected mapping must be committed in a separate write before the resolver returns the typed conflict, so neither `ON CONFLICT DO NOTHING` nor transaction rollback can silently erase the conflict.


**D22 — `canonicalization_version` versions the catalog identity algorithm, not the runtime Source.** The component that produces the catalog durable identity owns and writes `canonicalization_version`; Runtime V2 never increments it opportunistically. The version changes only when the rules used to derive or compare the catalog Source identity change in a way that can alter equivalence of catalog keys; ordinary catalog rebuilds, refetches, title changes, endpoint changes, or runtime migrations do not increment it. Every bridge lookup and persisted mapping includes the version explicitly.

**D23 — Canonicalization-version history is immutable and continuity is explicit.** A row in `legacy_source_map` for an older `(catalog_source_key, canonicalization_version)` is retained and never rewritten to represent a newer canonicalization version. Exact resolution uses the requested version. Older-version rows may be consulted as continuity evidence, but a newer-version mapping may reuse their `runtime_source_id` only when continuity is explicit and unambiguous under the catalog/bridge evidence available to the resolver. If more than one runtime Source is a viable predecessor, or continuity cannot be established without URL similarity or other inference, the resolver records/refuses the ambiguity and creates no automatic mapping.

### Invariants added or preserved by D20–D23

- **INV-M1 — No derived translation.** D2 remains absolute: no `CatalogSourceID`, URL, digest, row order or widened integer can produce a `FeedDomain.SourceID`; D20 permits only creation of a persisted mapping through D21.
- **INV-M2 — Bridge before return.** A catalog Source is returned to legacy-facing/runtime bridge code as a runtime `SourceID` only after the corresponding `legacy_source_map` row is durably established.
- **INV-M3 — Single allocator.** Only `RuntimeSourceRegistry` allocates a runtime Source row; the resolver may authorize allocation but cannot manufacture the ID.
- **INV-M4 — Atomic first mapping and durable conflict evidence.** The first successful allocation/mapping operation commits the Source and its bridge atomically; failure exposes neither a new mapping nor a bridge-visible orphan. If validation detects a divergent existing mapping, the allocation/mapping transaction rolls back and durable `legacy_map_conflict` evidence is committed separately before the typed conflict is returned.
- **INV-M5 — Existing mappings are authoritative.** If an exact `(catalog_source_key, canonicalization_version)` mapping exists, resolution returns that mapping; it is never silently re-pointed.
- **INV-M6 — Canonicalization versions are positive and explicit.** D3 and the schema requirement `canonicalization_version > 0` continue to apply to every persisted version.
- **INV-M7 — Version change does not renumber Sources.** Incrementing `canonicalization_version` alone neither creates a new semantic Source nor authorizes reuse of an old one; continuity must be established explicitly under D23.
- **INV-M8 — Historical mappings are immutable evidence.** Creating a mapping for version `N+1` never updates or deletes the mapping for version `N`.
- **INV-M9 — Ambiguity never becomes merge.** D12 remains binding: ambiguous continuity is refusal/conflict evidence, never automatic Source merging.
- **INV-M10 — `legacy_source_map` remains the only catalog legacy bridge.** D18 is preserved; D20–D23 do not introduce a parallel catalog-to-runtime identity path.

### Compatibility with existing decisions

- **D2 — remains valid as amended by D20–D21.** Catalog identity and runtime identity remain distinct types and no cast, widening, URL digest or other derivation can translate between them. An existing `legacy_source_map` row remains authoritative; D20 adds only the controlled policy for establishing a missing persisted mapping from a valid durable `EditorialSourceKey`, and D21 defines the allocation and persistence of that act.

- **D4 — remains valid without further change.** `EditorialSourceKey(catalogIdentity, canonicalizationVersion)` remains the durable key separate from the local row ID; D22–D23 define ownership of the canonicalization version and the rules for continuity across versions.

- **D18 — remains valid without further change.** Catalog Sources still cross the legacy/runtime boundary exclusively through `legacy_source_map`; D20–D21 define how an absent row may be established and do not introduce a parallel identity path.

- **D1 — remains valid without further change.** A Source established through D20–D21 remains FeedMine-owned and receives an opaque runtime ID allocated by `RuntimeSourceRegistry`.

- **D3 — remains valid without further change.** Runtime Source IDs remain positive checked local row IDs; neither the resolver nor catalog identity chooses the integer value.

- **D12 — remains valid without further change.** D12 continues to govern ambiguous external-identity aliases. D21 independently requires a divergent `legacy_source_map` proposal to be refused and its durable conflict evidence to survive rollback; it does not change alias semantics.

### Named acceptance tests

- `missingLegacySourceMappingAllocatesAndPersistsExactlyOnce` — with no mapping for a valid `EditorialSourceKey`, resolution allocates one Source through `RuntimeSourceRegistry`, persists one `legacy_source_map` row, and returns that persisted ID — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (D20, D21).

- `existingLegacySourceMappingNeverAllocatesOrRepoints` — with an exact mapping already present, resolution returns its `runtime_source_id`, creates no Source and never rewrites the row — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (D20, INV-M5).

- `concurrentMissingSourceResolutionConvergesOnOneMapping` — two concurrent resolves of the same missing `(catalog_source_key, canonicalization_version)` leave exactly one Source and one authoritative mapping, with both callers observing the same `SourceID` — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (D21).

- `failedSourceMappingTransactionExposesNoBridgeMapping` — injected failure between Source allocation and mapping persistence rolls the operation back so a subsequent read sees no newly established legacy mapping — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (D21, INV-M4).

- `canonicalizationVersionChangesOnlyWithCatalogIdentityAlgorithmVersion` — ordinary rebuild, endpoint/title changes and runtime migration preserve the supplied canonicalization version; an explicit catalog identity algorithm-version change supplies a new positive version — `feedmineTests/LegacyIdentityMapperTests.swift` (D22).

- `newCanonicalizationVersionPreservesOlderMapping` — establishing a version `N+1` mapping leaves the version `N` row byte-for-byte unchanged and both versions remain independently queryable — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (D23).

- `explicitCanonicalizationContinuityMayReuseRuntimeSource` — when explicit unambiguous continuity connects old and new canonicalized identities, version `N+1` receives its own mapping row pointing to the existing runtime Source without rewriting version `N` — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (D23).

- `ambiguousCanonicalizationContinuityCreatesNoAutomaticMapping` — when a new identity could continue more than one runtime Source, resolution refuses automatic mapping and leaves every prior mapping unchanged — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (D12, D23).

### What this amendment does not authorize

- It does **not** authorize conversion, widening, hashing, URL-derived identity or any fallback from `CatalogSourceID`/catalog URL to `FeedDomain.SourceID`.
- It does **not** authorize re-pointing, deleting or rewriting existing `legacy_source_map` rows, nor automatic merging of Sources across canonicalization versions.
- It does **not** authorize a second generic legacy identity table, changes to `feed_item.id`, user-data rekeying, presentation cutover or release ownership changes; those remain outside this amendment.