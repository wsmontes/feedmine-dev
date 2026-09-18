# The `legacy_source_map` bridge row: the swallowed write, fixed

Two slices hit this defect from different directions and both routed around it instead of fixing it
(`durable-user-actions-report.md:48-52, 203-206`; `pr-14-canonical-search-report.md:160-168`): on a
real `v2Full` launch **no `legacy_source_map` row existed at all**.

## The defect

`V2Acquisition.compose` wrote the bridge row with the catalogue's `none` and discarded the answer:

```swift
try? mappings.recordSourceMapping(
    LegacySourceMapper.mapping(for: identity, runtimeSourceID: sourceID, mappedAt: clock.now),
    in: database
)
```

with `identity` built from `compactID: CatalogSourceID(0)` (`V2Acquisition.swift:164,175` pre-fix).
`legacy_source_map.catalog_source_id` is `INTEGER NOT NULL CHECK (catalog_source_id > 0)`
(`RuntimeMigrations.swift:394`) and zero is the catalogue's `SourceID.none`, never a source
(`FeedEngine/Identities.swift:71-74`). The INSERT was refused, and `try?` threw the refusal away.

## What the row is for, and what `catalog_source_id` must hold

The table (`RuntimeMigrations.swift:392-401`) is `PRIMARY KEY (catalog_source_key,
canonicalization_version)`, with `runtime_source_id REFERENCES source(id)` and
`INDEX idx_legacy_source_map_id (catalog_source_id, canonicalization_version)`. That index names the
row's purpose: ADR-003 D2 makes this the **only** catalogue-id → runtime-source translation, and
`LegacySourceMap.runtimeSource(forCatalogSource:canonicalizationVersion:)`
(`FeedDomain/Identity/EditorialIdentity.swift:144-171`) looks the runtime source up by
`catalogSourceID` + version, throwing `missingSourceMapping` when no row exists.

Readers of the table, and what each reads:

| Reader | Reads | file:line |
|---|---|---|
| D2 translation (in-memory map) | `catalog_source_id`, `canonicalization_version` | `FeedDomain/Identity/EditorialIdentity.swift:144-171` |
| Canonical search | `legacy_url` by `runtime_source_id` | `FeedStorage/Selection/CanonicalSearchRepository.swift:164-168` |
| Source registry (projection path) | does **not** read the bridge; reads the `source` row | `FeedStorage/Identity/SourceRegistry.swift:75-96` |
| Shadow lane | writes `legacy_item_map` only, never this table | `feedmine/RuntimeV2/ShadowInputBridge.swift:402,1093-1101` |

So `catalog_source_id` must hold the **catalogue's own** compact id for that key — the app-level
`SourceID`, `CatalogIdentity.sourceID(for: CatalogIdentity.sourceKey(for: declaredURL))`
(`FeedEngine/CatalogIdentity.swift:16-21`), which is exactly the value `SQLiteCatalogStore.insertSource`
stores as `catalog_source.id` (`SQLiteCatalogStore.swift:100-101, 247-255`). It is not a runtime id:
the runtime allocates its own and never derives one from a catalogue id or a URL digest (D2, D3).

## The fix

1. **The value.** `V2AcquisitionSourceDescriptor` now carries `compactID: CatalogSourceID`, computed in
   `descriptors(for:)` from the catalogue's own derivation applied to the same `FeedSource.id` the
   descriptor keys by; `compose` passes `descriptor.compactID` into
   `LegacySourceMapper.catalogIdentity`. Nothing about the runtime identity derivation changed — the
   runtime `SourceID` is still allocated by `RuntimeSourceRegistry` and reached only through the
   persisted row. No CHECK was widened, no placeholder remains.
2. **The refusal is visible.** The write is `try` inside `do/catch`. The failure is logged
   (`runtime-v2 source-bridge-write-failed catalogSourceID=… canonicalizationVersion=…
   runtimeSourceID=… error=…` — ids, never a URL, §16) and rethrown, so `watch` refuses that source and
   names it in `V2AcquisitionReport.refused`, exactly as it already does for a failed editorial key,
   source allocation, binding or enrollment. Acquiring content behind a bridge that does not exist was
   the silent alternative, and it is gone.

## The two work-arounds, re-read

Had the row been present, would either slice have needed its work-around? Neither, and both stay:

- **Projection** — `RuntimeSourceRegistry.editorialKey(for:in:)` reads the `source` row the runtime
  allocated. That is the better answer regardless of the bridge: a projection holding a runtime
  `SourceID` wants the runtime's own identity row, while `legacy_source_map.legacy_url` is the legacy
  *evidence* of the same mapping (`LegacySourceMapper.CatalogIdentity.normalizedURL`). Left unchanged;
  only its rationale was stale (it justified itself with "the row does not exist to read"), and the
  reason is now recorded at the line. The same correction was made at
  `LegacyContentProjection.legacySourceURL` (`UserStateBridge.swift:120-129`), which claimed to be
  "the only durable evidence".
- **Search** — `CanonicalContentSearch.catalogueSource(for:)` tries `hit.sourceKey` first,
  `hit.legacySourceURL` second, with the registry validating the winner. The order is on the merits,
  not because the bridge was empty: candidate 1 is the source's durable editorial key read from the
  runtime's own `source` row, candidate 2 is the address the *catalogue* knew and is stored as
  evidence. Left unchanged; its comment claimed the bridge was second *because* the composition could
  not write it, and that is now false, so it was rewritten (`CanonicalContentSearch.swift:80-92`).

## Evidence

Tests in `feedmineTests/OwnerSwapAcquisitionTests.swift`:

- `testAProductionAdmissionWritesTheCatalogueSourceBridgeRow` — drives the production owner
  (`V2Acquisition` over `V2AcquisitionSourceDescriptor.descriptors(for:)`, stub wire, real coordinator
  and connector) through one admission, then asserts the row exists **with its value named**: key
  `FeedSource.id`, `catalog_source_id` = `CatalogIdentity.sourceID(for: SourceKey(source.id)).rawValue`,
  version 1, `runtime_source_id` = the allocated `source` row, and that
  `LegacySourceMap.runtimeSource(forCatalogSource:canonicalizationVersion:)` resolves the catalogue id.
- `testABridgeWriteTheSchemaRefusesRefusesTheSourceInsteadOfBeingSwallowed` — a descriptor carrying the
  catalogue's `none` is refused, reported, and leaves no row.

Falsified against the pre-fix code (both edits restored temporarily, then reverted):
`testAProductionAdmissionWritesTheCatalogueSourceBridgeRow` fails with `XCTUnwrap failed: expected
non-nil value of type "Row"`, and `testABridgeWriteTheSchemaRefusesRefusesTheSourceInsteadOfBeingSwallowed`
fails with `watched` 1 and an empty `refused` — i.e. the swallow it exists to catch.

Gates, verbatim:

```
$ swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm
Test Suite 'All tests' passed at 2026-09-18 03:43:49.029.
	 Executed 493 tests, with 0 failures (0 unexpected) in 10.762 (10.790) seconds

$ bash scripts/verify-runtime-v2-boundaries.sh
boundary gate: 77 source files, 156 imports, root=/Users/wagnermontes/Documents/GitHub/feedmine/Packages/FeedRuntimeV2
PASS: module boundaries match the plan

$ xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd
	 Executed 586 tests, with 0 failures (0 unexpected) in 114.141 (114.320) seconds
Test Suite 'All tests' passed at 2026-09-18 03:50:40.651.
** TEST SUCCEEDED **
```

`586` against the previous `584`: the two tests above. One app-plan run at a time; no run shared the
simulator with another.

## Gaps left

- **The compact id is derived, not read.** The composition holds the OPML registry's enabled set, not a
  compiled catalog, so the id comes from `CatalogIdentity.sourceID(for:)` applied to `FeedSource.id`
  rather than from a `catalog_source.id` read. The two agree by construction — both digest
  `OPMLParser.normalizeURL` of the source's declared URL — but that equality is a property of the
  derivation, not of a read, and nothing in this slice asserts it against a compiled catalog.
- **Digest collisions between two enabled sources.** They would write two rows sharing one
  `catalog_source_id`; D18's answer then applies (`runtimeSource(forCatalogSource:)` throws
  `conflictingSourceMapping`) and the catalog compiler refuses such a catalog outright
  (`FeedEngineError.identityCollision`). Neither path is exercised here.
- **Scope of the write.** The row is written for the up-to-`launchWindow` (32) sources a launch watches;
  a catalogue source beyond that window gets its row when a later episode reaches it. Not a defect, but
  it means "the bridge covers the catalogue" is true only for what has been composed.
- **Conflicts on relaunch.** `recordSourceMapping` is `ON CONFLICT DO NOTHING`, so a relaunch whose
  catalogue now claims a different runtime source for an established key is not detected here; the
  mapper's `reapply` remains the conflict path (ADR-003 D18, unchanged).
- The shadow lane's `CatalogSourceID(0)` (`ShadowInputBridge.swift:1099-1100`) stays: it only feeds
  `objectScope`, which never reads the compact id, and the shadow never writes this table.
