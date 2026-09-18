# PR-14 clause two — the local content search reads the canonical FTS

**Slice:** plan §14 PR-14, item 2, clause two — *“Search de fontes continua consulta de catálogo; Search de
conteúdo usa FTS canônica.”* The first clause (source search is a catalogue query) landed in PR-14; clause
three (the online sweep is an explicit, separate demand) landed in the owner swap. This slice closes the
middle clause: the index behind the *local content* search.

The clause was not actionable when §8.14 measured it — `origin_search` was inert, “nothing queries it, and
nothing fills it” — and it became actionable when the owner swap populated it (30 rows in the observed
`v2Full` launch, §8.25; repeated on the upgraded container, §8.28).

## 1. What the search did, and what the canonical index is

**Before.** `FeedStore.search` (`feedmine/Services/FeedStore.swift:3573`) starts a local query through
`SearchEngine.unifiedSearch` (`feedmine/Services/SearchEngine.swift:203`). Its content half ran two SQL reads
over the legacy database:

- `searchLocalRecords` (`SearchEngine.swift:313`) — `feed_item JOIN feed_item_fts ON rowid`, `MATCH` with the
  `{title excerpt} :` scope of `contentFTSQuery` (`:411`), ordered by `published_at DESC`, `LIMIT 180`;
- `searchSavedRecords` (`SearchEngine.swift:277`) — the same join restricted to the reader’s bookmarked ids.

**The canonical index.** `origin_search` is an FTS5 virtual table with a single `projection` column
(`Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift:431`), one row per record,
`rowid = origin_record_id`. It is written inside the transaction that makes a revision current
(`AdmissionEngine.refreshSupply`, `Admission/AdmissionEngine.swift:666`; the projection insert is `:695`) — a
revision that stops being current loses its row, so the index describes what is current now and never what
once was. The projection is `headline \n summary \n body` of that revision; nothing else about the record is
in the index, so a readable result joins the canonical tables beside it.

**A working read** (the shape the new repository issues, `FeedStorage/Selection/CanonicalSearchRepository.swift:69`):

```sql
SELECT origin_search.rowid AS origin_record_id,
       r.current_revision_id AS origin_revision_id,
       rev.headline, rev.summary, substr(rev.body_text, 1, 600) AS body_excerpt,
       rev.primary_link, rev.authored_at, rev.observed_at
FROM origin_search
JOIN origin_record r ON r.id = origin_search.rowid
JOIN origin_revision rev ON rev.id = r.current_revision_id
WHERE origin_search MATCH ?
  AND r.availability = 'available'
ORDER BY COALESCE(rev.authored_at, rev.observed_at) DESC, origin_search.rowid DESC
LIMIT ?
```

Two secondary reads per result set complete the hit: the record’s membership source (`source_membership` →
`source`, plus the `legacy_source_map` bridge row when one exists) and the current revision’s media
(`media_candidate` joined on `origin_record.current_revision_id`, so a previous revision’s candidates cannot
leak into a result). `CanonicalSearchHit` is the value that comes back; `feedmine/RuntimeV2/CanonicalContentSearch.swift`
maps it onto the `FeedItem` the search list already renders.

## 2. Which index each mode reads, and why

The read is chosen by **the composition, not by a mode string**: `CanonicalContentSearch` exists exactly when
`RuntimeCompositionRoot.compose` composed the acquiring runtime, which it does for `v2Full` only.

| Mode | Local content search reads | Why |
|---|---|---|
| `legacy` | `feed_item_fts` over `feedmine.sqlite` | nothing admits into a runtime database here: the acquisition gate is closed only when the runtime owns acquisition, and `compose` returns `.legacyOnly` outside `v2Full`. A canonical read would answer from an index this mode never writes. |
| `mirroredShadow` | `feed_item_fts` | the shadow is a parity lane that produces no feed and holds no authority; it is also not the database the composition hands to the store. |
| `v2Presentation` | `feed_item_fts` | `compose` refuses it (`legacyOnly`, reason recorded): there is no composed runtime database at all. |
| `v2Full` | `origin_search` over `runtime-v2.sqlite` | this is the mode whose runtime owns acquisition, so this is the mode whose Admission fills the index. |

The wiring that makes that true:

- `RuntimeCompositionRoot.compose` builds `.full` only for `v2Full` (and `MainFeedRuntime` closes
  `LegacyAcquisitionGate` only when `decision.mode.ownsAcquisition`);
- `MainFeedRuntime.startSession` installs the read path on the loader it already holds —
  `CanonicalContentSearch(database: full.database, registry: loader.sourceRegistry)`
  (`feedmine/RuntimeV2/MainFeedRuntime.swift:217`) — and `stop()` removes it again (`:317`), the way it
  reopens the gate;
- `FeedLoader.useCanonicalContentSearch` (`feedmine/Services/FeedLoader.swift:343`) forwards to
  `FeedStore.useCanonicalContentSearch` (`feedmine/Services/FeedStore.swift:3569`), which sets
  `SearchEngine.canonicalContentSearch` (`feedmine/Services/SearchEngine.swift:165`);
- `SearchEngine.localContentItems` (`:252`) is the either/or: canonical when the property is set, the legacy
  `searchLocalRecords` read otherwise. **There is no fallback between the two** — the index is a decision of
  the mode, not of which index happens to have rows.

## 3. The two re-stated tests, and what they assert now

Both were named by the swap’s recon (baseline §8.23) as the tests that would move when the search is
rewired. They are re-stated, not deleted, and their meaning is intact: a local search is not a demand.

| Test (`feedmineTests/SurfacePlanMigrationTests.swift`) | Before | Now |
|---|---|---|
| `testLocalContentSearchIssuesNoOnlineDemand` (`:174`) | an in-memory store searched `"canonical"` and asserted only that no endpoint was demanded and no claim was left behind | **the same demand assertions**, plus the index the mode reads: the legacy row this launch can see is what comes back (`localItems == ["legacy-row"]`), because a launch that composes no runtime reads `feed_item_fts`. The fixture is a real `feed_item` row and a registry source, so the result passes the same `applyFilters` the production path applies |
| `testContentSearchStatesWhetherItDemandsTheNetwork` (`:205`) | the demand flag was `true` after a demanding search and `false` after a non-demanding one | **unchanged assertions**, with the scope stated: the flag is a fact about the demand, not about which index answers — the local read is the same either way |

Two further tests make the mode-dependent answer visible, which is the part the clause cannot avoid:

| Test | What it asserts |
|---|---|
| `testLocalContentSearchReadsTheCanonicalIndexWhenTheRuntimeOwnsAcquisition` (`:223`) | with the canonical read installed over a runtime database holding one record, and a legacy row matching the *same* term in `feedmine.sqlite`, exactly one result comes back and it is the canonical one (title, excerpt, address, source, language, `origin:1` id) — the legacy label is asserted **absent**. The index is the mode’s decision, never a union |
| `testCanonicalModeDoesNotFallBackToTheLegacyIndex` (`:276`) | the same store against an empty runtime database returns **no** local results even though the legacy row matches: empty is the canonical answer, not a reason to read a second authority |
| `OwnerSwapAcquisitionTests.testTheLocalContentSearchReturnsTheAdmittedCanonicalContent` (`:351`) | end to end: a real HTTP answer → syndication translator → `AcquisitionCoordinator` → `AdmissionEngine` → `origin_search`, then `FeedStore.search` returns that record’s title, link, source and enclosure audio, with the demand flag false and zero endpoint demands. The real write path, not a fixture |

## 4. Gates

Verbatim, in the order the slice ran them, on the frozen tree (comments-only edits after a run were
re-gated, so the lines below describe the tree that was reported).

```
$ bash scripts/verify-runtime-v2-boundaries.sh
boundary gate: 77 source files, 156 imports, root=/Users/wagnermontes/Documents/GitHub/feedmine/Packages/FeedRuntimeV2
PASS: module boundaries match the plan
```

```
$ swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm
	 Executed 493 tests, with 0 failures (0 unexpected) in 9.250 (9.277) seconds
	 Executed 493 tests, with 0 failures (0 unexpected) in 9.250 (9.278) seconds
```

```
$ xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd
Test Suite 'All tests' passed at 2026-09-18 03:36:12.504.
	 Executed 584 tests, with 0 failures (0 unexpected) in 114.207 (114.371) seconds

** TEST SUCCEEDED **
```

One app-plan run at a time: no other `xcodebuild` was running when either run started (checked, not
assumed — §8.25 records what a shared simulator does to a second log).

The app plan held 581 tests before this slice and holds 584 after: two re-stated tests plus three new ones
(`testLocalContentSearchReadsTheCanonicalIndexWhenTheRuntimeOwnsAcquisition`,
`testCanonicalModeDoesNotFallBackToTheLegacyIndex`, and the end-to-end
`testTheLocalContentSearchReturnsTheAdmittedCanonicalContent`).

The package count moved from 489 to 493 with this slice’s four `CanonicalSearchRepositoryTests`. The
boundary gate moved from 76 files / 153 imports to 77 / 156: one new `FeedStorage` source file, importing
`Foundation`, `GRDB` and `FeedDomain` — all three allowed for that target.

## 5. Gaps this slice leaves

Named rather than hidden. The first is the one the brief asks about explicitly.

1. **A `v2Full` reader whose runtime has admitted nothing gets no local results.** The runtime database is
   empty before the first admission lands (and stays empty if acquisition fails permanently). The search
   then returns nothing instead of the legacy database’s content. That is deliberate — the fallback would put
   two authorities behind one search and answer from a database the mode is not refreshing (the acquisition
   gate is closed, so nothing in `v2Full` writes `feed_item` either) — but the reader-visible consequence is
   real and is asserted by `testCanonicalModeDoesNotFallBackToTheLegacyIndex`. If the product wants legacy
   content visible during that window, it needs an explicit, named policy (e.g. “legacy results are marked as
   stale”), not an implicit fallback.
2. **A canonical hit carries no read/bookmark overlay.** The runtime’s `user_state_projection` is the authority
   for a runtime card’s overlay and is not read here, so every canonical result renders unread and un-saved
   even when the reader has read or saved it. Mapping a legacy/canonical subject onto a search row is the
   card-identity slice’s work (rollout §2.4 and §7), not an index switch’s.
3. **Saved/bookmark search stays on the legacy hydration path.** `searchSavedRecords` still reads
   `feed_item_fts`, because a bookmark is keyed by a legacy item id in `user.sqlite` and hydrated through
   `feed_item` (ADR-004 D6). That is a different authority with a different key, and this clause did not ask
   for it. Consequence: in `v2Full` the *Saved* section and the *History & local content* section can answer
   from different databases.
4. **A canonical hit has a legacy item id only when `legacy_item_map` has one** (`UserStateBridge` writes it
   when the reader acts on a runtime card; the shadow lane writes it during mirroring). Otherwise the item id
   is `origin:<recordID>`. `FeedScreen`’s search row calls `loader.markAsClicked(item.id)` on tap, which is a
   legacy write keyed by that id; for an `origin:` id it is a no-op on `feed_item`, so read state does not
   stick to a canonical search result. Same owner as gap 2.
5. **`legacy_source_map` is empty in production, and that is a finding, not a preference.** `V2Acquisition`
   writes the bridge row with `compactID: CatalogSourceID(0)` (`feedmine/RuntimeV2/V2Acquisition.swift:164,175`)
   — the catalogue’s `SourceID.none` — which `legacy_source_map.catalog_source_id > 0` refuses, and the call
   is `try?`, so the refusal is swallowed and no row exists on a real launch. The search therefore resolves a
   hit’s source through the source’s durable `editorial_key` first (validated against the registry, which
   skips any key it does not know as a source URL) and only then through `legacy_source_map`. That works
   because this app composes `editorial_key = FeedSource.id` = the normalized fetch URL
   (`V2Acquisition.descriptors(for:)`), and the unit/end-to-end tests confirm it. Fixing the bridge write
   (a real compact id, or not swallowing the failure) belongs to the acquisition slice, not this read path.
6. **`v2Full` is still not a shipping mode.** It is requested by launch arguments; the read path is installed
   by the composition, so the day the mode becomes reachable in the product, the search follows it with no
   further change — but nothing in this slice observed a device launch, only the app suite and the package.
