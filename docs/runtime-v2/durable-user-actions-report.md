# Durable user actions on a runtime card

Slice between the owner swap (`owner-swap-report.md`) and PR-17. The owner swap's own report found the
gap (§6.1 gap 1): in `v2Full` every user action was refused, because
`RuntimeCardUserActions.setBookmarked` threw `subjectUnavailable`. This document records what became
durable, the exact write path per database, the evidence for both halves the plan requires, and every
gap left open. It is written by the slice that made the change, in the shape of
`pr-16-hardening-report.md` and `owner-swap-report.md`.

**Status: code complete; all three gates green; a bookmark on a runtime card is durable, reversible, and
hydratable by a legacy reader that reopens the two databases.**

## 1. Gates

| Gate | Measured |
|---|---|
| `swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm` | **`Executed 489 tests, with 0 failures (0 unexpected)`** — the plan held 489 before this slice and holds 489 after: the one package change is a read accessor, and the tests this slice added are app-side. |
| `bash scripts/verify-runtime-v2-boundaries.sh` | `boundary gate: 76 source files, 153 imports` / **`PASS: module boundaries match the plan`** — unchanged. |
| `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd` | **`Executed 581 tests, with 0 failures (0 unexpected)`**; the plan's `.xcresult` reports `result: Passed`, `passedTests: 581`, `failedTests: 0`, `skippedTests: 0`. The plan held 579 tests before this slice and holds 581 after (the two new tests). |
| Sensitivity probes (below) | Each new test fails when *either* database's write is removed — measured both ways, not argued. |

One `xcodebuild test` run at a time, as the owner swap's §7 and baseline §8.25 require. The package
sweep was run before the app plan so a package defect could not hide behind the app suite (the rule the
migration lesson records).

## 2. What became durable, and where it is written

### 2.1 The subject: a card becomes a legacy item id

`user.sqlite` is keyed by the legacy item id, and legacy hydration reads `feedmine.sqlite.feed_item` for
that id (`BookmarkStore.bookmarkedItems`). So the first question is not "what do we write" but "what is a
runtime card called". The answer is the legacy reader's own rule, not a new one:

```
FeedItem.generateID(sourceURL: <the card's source>, guid: nil,
                    link: <the card's external action URL>, title: <the card's headline>,
                    publishedAt: <the card's declared date>)
```

(`feedmine/Models/FeedItem.swift:394-406`; the same call `RSSFetcher.makeItem` makes at
`RSSFetcher.swift:1050`.) A runtime id is deliberately **not** the subject: `PublicationCardID` is
allocated in the publication transaction and a rebuild changes it, which is exactly what ADR-004 D7
forbids as the only reference. The `legacy_item_map` row written beside it (`legacy_item_id` → the card's
`origin_record_id`/`origin_revision_id`) is the durable alias D18 names, and it is what the runtime's own
retention root already joins through (`FeedStorage/Retention/RetentionPolicy.swift:286-302`).

The source URL comes from the allocated `source` row (`RuntimeSourceRegistry.editorialKey(for:in:)`,
added here — a read), because a published payload freezes no URL at all (ADR-002 D3) and
`legacy_source_map.legacy_url` — the other candidate — **is never written in `v2Full`**: `V2Acquisition`
records it with the catalogue's `none` compact id, the table's `catalog_source_id > 0` check refuses the
row, and its `try?` swallows the failure (`V2Acquisition.swift:175-182`). That is a defect of the source
slice, found here and named in §6; this slice reads the value that does exist.

### 2.2 The three write paths, in ADR-004 D6's order

For a bookmark on card *C*, `RuntimeCardUserActions.setBookmarked` writes:

| # | Database | Rows | Writer |
|---|---|---|---|
| 1 | `user.sqlite` (authority) | `user_operation` (intent, `state = pending`), `bookmark_item(list_id, item_id = subject, added_at)`, `bookmark_snapshot` (title, url, source title/url, excerpt, authored_at, captured_at), then `user_operation.state = applied` | `BookmarkStore.setBookmarked` through `UserStateBridge.setBookmarked` — unchanged, and the only writer of the authority |
| 2 | `runtime-v2.sqlite` (projection) | `user_state_projection(kind = 'bookmark', subject_id = subject, wanted, last_operation_id)` and `user_state_watermark` | `UserStateProjectionStore.apply`, through the same bridge |
| 3 | `feedmine.sqlite` (legacy compatibility) | `feed_item(id = subject, source_url, source_title, region, category, title, excerpt, url, image_url, published_at, fetched_at, is_read = 0)` — `ON CONFLICT(id) DO NOTHING`; then the content-database retention pin `bookmark_item(list_id, item_id, added_at)` | `LegacyContentProjection.write`, new here |
| 4 | `runtime-v2.sqlite` (durable alias) | `legacy_item_map(legacy_item_id = subject, legacy_source_url, origin_record_id, origin_revision_id, confidence, mapped_at)` | the same `LegacyContentProjection.write` |

Order and failure semantics: the authority first (its failure throws and the session keeps the state it
was showing — `FeedSession.performBookmark`), then the runtime projection (its failure marks the operation
failed and is reported, the bridge's existing rule), then the legacy compatibility projection (its failure
marks the operation failed too, so an action a relaunch would not show is never reported as done). Every
write is idempotent on its own key, so a retry re-runs the whole path and heals what is missing.

**Where the legacy row comes from.** Not from an invented mapping: from the bookmark's own snapshot
(`bookmark_snapshot`, ADR-004 D7's "minimum that survives a content rebuild"), materialised in the shape
the legacy schema declares. `LegacyCardContent(snapshot:)` is that derivation, and it is the reason the
row can be rebuilt rather than remembered. What the payload does not freeze is stated rather than
approximated: `region` takes the legacy default (`global` — region is catalogue metadata no card carries),
`category` is empty, the language is absent, and no media URL is written (a payload names media by digest,
and a digest is not an address).

**Two properties kept, not just claimed.**

* *No legacy row V2 does not own is deleted or rewritten.* The content insert is `ON CONFLICT DO NOTHING`:
  a row that already exists belongs to the legacy lane, and the bookmark hydrates from it. The only
  legacy-side mutation this slice performs beyond that insert is the retention pin — and it is written by
  the legacy path's own mechanism (`BookmarkStore.synchronizeRetentionPin`, whose visibility widened from
  `private` for this one second call site because its insert selects the `feed_item` row and therefore has
  to *follow* the content write rather than precede it).
* *Nothing is written for content the reader did not act on.* The projection runs inside
  `setBookmarked(cardID:wanted:operationID:)`, for that card only. There is no eager mirror of the feed:
  it would bloat the legacy database and make the rollback window meaningless. The second new test measures
  this with a two-card fixture: after one bookmark, `feed_item` holds exactly one row.

### 2.3 The interaction path

Making the port durable was not enough on its own. In `v2Full` the screen's bookmark tap travelled
`MainFeedRuntime.toggleBookmark(itemID:)` → `presentation.send` → `MainFeedRuntime.handle` → and `handle`
executed the *legacy* effect: `loader.toggleBookmark(itemID)`, where the item id is the display id the
bridge synthesizes (`MainFeedPresentation.displayItem`, `card:<cardID>`). That wrote a durable
`bookmark_item` row nothing can hydrate — invisible in the mode it was taken in and after a rollback
alike. The intent never reached the session at all: only `.refresh` did.

`handle(.toggleBookmark:)` now routes through the runtime when the runtime owns acquisition
(`V2FullRuntime.setBookmarked(cardID:wanted:operationID:)` → `session.send(.toggleBookmark)`), exactly as
`.refresh` already did, and keeps the legacy effect for every mode that does not own the feed. `legacy`
and `mirroredShadow` are untouched, and `LegacyAcquisitionGate` is untouched.

## 3. The evidence, both halves

### 3.1 In mode: visible and reversible through the app's own bookmark surface

`feedmineTests/OwnerSwapAcquisitionTests.testABookmarkOnARuntimeCardIsVisibleAndReversibleThroughTheBookmarkSurface`.
It publishes a real card through the production chain (scripted HTTP → `PolicyEnforcingHTTPTransport` →
`SyndicationAcquisitionSource` → `AcquisitionCoordinator` → Admission → Selection →
`RuntimeFeedSessionComposer` → a `FeedSession` snapshot), then drives the session's own durable path and
reads back:

* **the app's own bookmark surface** — `BookmarkStore.bookmarkedItems()`, the call
  `FeedLoader.loadBookmarkedItems` → `FeedStore.bookmarkedItems` makes — answers with exactly one item,
  and its title, URL, source title and source URL are the card's;
* **hydration came from the content row, not the snapshot** — `hydration().items` holds it and
  `snapshotOnly` is empty (`hydration()` is where the "content row is gone" degradation is stated);
* **the runtime agrees** — `user_state_projection.savedSubjects()` holds the subject, and
  `legacy_item_map` resolves it to the card's `origin_record_id`/`origin_revision_id` with `confidence:
  .high`;
* **the session's card carries the confirmed state** (`isBookmarked`);
* **reversible** — the removal (`wanted: false`) empties the authority, the hydration and the projection,
  clears the snapshot, removes the legacy pin, and the session's card reports `isBookmarked == false`.

### 3.2 Rollback: a legacy relaunch hydrates it with its content

`feedmineTests/OwnerSwapAcquisitionTests.testALegacyRelaunchHydratesABookmarkTakenOnARuntimeCard`.
Two cards are published and the reader acts on one, then the databases are **reopened**: fresh
`DatabaseQueue` connections over the same `user.sqlite` and `feedmine.sqlite` files (WAL, foreign keys on —
the configuration legacy opens with), a fresh `BookmarkStore`, and nothing else carried over — no runtime
database, no card id, no snapshot. What answers is the join build 17 performs, `bookmarkedItems()`:

* exactly one hydrated item, with the card's title, URL, source title, excerpt and declared date;
* `isBookmarked` true for the subject;
* the subject in the authority is the one the runtime wrote, and it is *not* `card:<cardID>`;
* the legacy retention pin holds the same subject;
* the untouched card left the legacy database alone (`feed_item` holds exactly one row).

The legacy row is not an artefact of the test container being on disk: the on-disk rig uses the app's own
migrations (`FeedStore.migrate`, `UserStateStore(databaseURL:)`), which is how the real container is built.

### 3.3 Sensitivity: either write removed fails the tests — measured

Run as deliberate breakages, one at a time, then reverted:

| Breakage | Result |
|---|---|
| the `feed_item` insert in `LegacyContentProjection.write` removed | both tests fail: `XCTAssertEqual failed: ("0") is not equal to ("1") - a bookmark on a runtime card must reach the bookmark surface`; `("Optional(0)") is not equal to ("Optional(1)") - the untouched card must leave the legacy database alone`; `("0") is not equal to ("1")` |
| the `userState.setBookmarked` authority write removed from `RuntimeCardUserActions` | both tests fail: `("0") is not equal to ("1") - a bookmark on a runtime card must reach the bookmark surface`; `("0") is not equal to ("1")` |

Both assertions travel the same join (`bookmark_item.item_id` → `feed_item.id`), so neither database alone
can satisfy them — which is the property the slice exists to establish.

## 4. What is unchanged

* `legacy` and `mirroredShadow`: `handle(.toggleBookmark:)` keeps the legacy effect in both, because
  neither composes a `V2FullRuntime` (`ownsAcquisition == false`). `v2Presentation` composes nothing and
  keeps it too.
* `LegacyAcquisitionGate`: not touched.
* `UserStateBridge`, `UserStateProjectionStore`, `BookmarkStore.setBookmarked`'s operation/snapshot
  semantics, and every existing test: no test was re-pinned, and the 7 pre-existing tests of
  `OwnerSwapAcquisitionTests` pass unchanged (that class is now `@MainActor`, which its harness needs
  because it builds the app's own stores).

## 5. Gaps, named

Ordered by what a rollback would still not survive.

1. **Read state does not survive.** A bookmark does; an *open* does not. The session's port has no
   `setRead`, and the opened intent still executes the legacy effect with the display item id
   (`MainFeedRuntime.handle(.opened)` → `loader.markAsClicked("card:<id>")`), which updates a `feed_item`
   row that does not exist. So after a rollback a runtime article the reader opened comes back unread, and
   ADR-004 D12's read-state half is unmet for content only V2 acquired. The identity path this slice built
   is what that fix needs (the same subject, the same row, `is_read`/`opened_at`); the port method is not.
2. **A crash between the three writes is repaired, but only when something replays.** If the process dies
   after `user.sqlite` commits and before the legacy row, the bookmark exists and hydrates only from the
   snapshot: invisible to the legacy surface, and nothing legacy after a rollback. `UserStateBridge.reconcile`
   has the snapshot it would need to rebuild the row, but (a) it does not rebuild it today and (b) it has no
   production caller at all (PR-04's remaining wiring). A user retry heals it, because every write is
   idempotent and a new operation id replays the whole path.
3. **Collections.** A runtime card cannot be put in a collection: the collection surface is legacy, keyed
   by item ids, and no affordance offers one on a runtime card. Nothing was attempted here; the same subject
   rule is the prerequisite.
4. **The id is the legacy scheme only when the legacy reader would derive the same one.** The subject uses
   the catalogue's normalized source URL and the card's external link; legacy uses the raw OPML URL and
   prefers a declared GUID. When those agree (usually) a later legacy fetch of the same article lands on
   the bookmark; when they do not, legacy can create a second, unbookmarked row beside the saved one. The
   saved article still hydrates and renders.
5. **Region, category and language on the projected row are defaults**, not the catalogue's values: a saved
   runtime article appears under `global` in legacy's region filters rather than under its country's.
6. **The row's excerpt is the frozen text verbatim**, including any markup the document declared — the
   presentation gap the owner swap recorded (§6.1 item 5), now also visible to the legacy renderer.
7. **No media on the row.** No image URL and no audio URL are written, because the payload names media by
   digest and this build publishes no bytes at all (owner-swap §6.1 item 4). After a rollback the saved
   card draws without an image, and its audio affordance has nothing to play.
8. **The un-bookmarked row stays.** Removing a bookmark removes the authority row, the snapshot and the pin,
   and leaves the `feed_item` row: V2 cannot prove that row is its own when the id already existed, and D1
   forbids deleting what it does not own. It is content cache from then on, and legacy's own retention
   (30-day cutoff, pins excluded) is what expires it.
9. **`legacy_source_map` is never written in `v2Full`** (the `CatalogSourceID(0)` CHECK + `try?` in
   `V2Acquisition`). ADR-003 D18's claim that the bridge row makes the source mapping durable "for every
   other reader" does not hold on this path. Owner: the source-identity slice; the fix needs the catalogue's
   real compact id, which the enabled-set composition does not hold.
10. **The routing hop has no test.** `MainFeedRuntime.handle`'s new branch is exercised only by inspection:
    exercising it needs a `MainFeedRuntime` with an acquiring composition *and* a started session, and
    starting one needs a `FeedLoader` with a loaded catalogue — the same limitation the owner swap recorded
    for `V2FullRuntime` (`owner-swap-report.md` §5). The two new tests drive the session's own port, which
    is the hop below it.
11. **The device repeat of the rollback is still missing.** §3.2 relands the two real databases in-process
    with fresh connections; reinstalling build 17 over a container V2 wrote is PR-17's item 3, and it is
    where the window's second half has to be observed on a device.
