Isto é uma transmissão ÍNTEGRA e ORDENADA dos fatos do checkout; ignore qualquer cópia parcial anterior que você tenha recebido. Vou enviar em partes. Responda a cada parte apenas com "ok" — nada mais. A ÚLTIMA parte traz [[TAREFA]] e o contrato de entrega; só então produza o documento.

--- D1 — identidade legada (FeedSource / FeedItem / SourceID) ---
## 1. FeedSource — `feedmine/Models/FeedSource.swift`
- `struct FeedSource: Codable, Identifiable, Equatable, Sendable` :10. Stored fields :15-35: `title,url,category,region`("global"|"countries/…"),`language?,mediaKind:MediaKind`(:3),`sourceDescription?,tags[],nature?,activity?,qualityScore?,defaultEnabled,contactEmail?,contactName?,contactSource?,contactType?`. `id` is computed, NOT stored/encoded: `OPMLParser.normalizeURL(url)` :14; CodingKeys exclude it :86-96.
- `struct SourceReference` :124, `var id = OPMLParser.normalizeURL(feedURL)` :125. `feedURL` is stored as `OPMLParser.requestURL(feedURL)` (keeps signed/auth params) :170; comment :163-169 says id/registry lookups normalize separately.
- Identity helpers: `OPMLParser.normalizeURL` OPMLParser.swift:740 = `transformedURL(raw, identity:true)` :744. It forces scheme `https` :736, strips `www` :704, drops default ports :717-723, removes ALL trailing `/` :726-727, and strips query params in `identityQueryParameters` :497-509 (`utm_*`, `ref`,`source`,`fbclid`,`gclid`,`mc_cid/eid`,`temp_url_sig/expires`,`expires`,`cfid`,`cftoken`,`jsessionid`,`phpsessid`,`token`,`sig`,`key`,`auth`,`apikey`,`api_key`,`signature`,`access_token`,`refresh_token`) plus any `x-amz-*` :669. `requestURL` :753 = `identity:false`. `CatalogIdentity.canonicalURLKey` delegates to it CatalogIdentity.swift:33-35; `sourceKey(for:)` :14-16; mirrors `scripts/catalog_identity.py` (:510-513).
- URL==identity assumptions (all key/lookup by a normalized-URL string): FeedSource.id :14; SourceReference.id :125; SourceCollectionMember.id UserStateStore.swift:1193; SourceRegistry.sourceKey `"url:"+normalized` :124 and byURL/regionMap/languageMap/enabledSources :167-169,340-341,412-413,679-682,743,749,758,764; AdaptiveScheduler :333-353; RSSFetcher :147; EditorialSequencer.providerKey :25; TaxonomyStore feedToNodeID :274-275,523,528; ShadowInputBridge :1093; OPMLParser dedupe :401; ImportPipeline :61,147,183,201; FeedStore :265,597,851,1601,1616,1659,1727,3324,3368,3684-3695,4406; UserStateStore persisted `source_identity` columns :330,336,390,937,1411,1419; FeedItem.withNormalizedSourceURL rewrites item.sourceURL FeedItem.swift:295-299.

## 2. FeedItem — `feedmine/Models/FeedItem.swift`
- `struct FeedItem: Identifiable, Sendable, Codable, Equatable` :4. Fields :5-24: `id,sourceTitle,sourceURL,category,title,excerpt,url,imageURL?,publishedAt,audioURL?,duration?,region,language?,updatedAt?,authors?,itemCategories?,rights?,attribution?,enclosures?,languageFromFeed?,alternateLinks?`, plus `isRead,isBookmarked,sectionDayOffset`, and `let searchableText` computed in init :70-72. NO `guid` field.
- `generateID(sourceURL:guid:link:title:publishedAt:)` :394-402 exactly: token = first non-empty of `guid` :396 → `link` :397 → `"\(title ?? "untitled")|\(String(publishedAt?.timeIntervalSince1970) ?? "0")"` :398-400; `raw = "\(sourceURL)|\(token)"`; returns lowercase-hex `SHA256.hash` :401-402. Callers: RSSFetcher.swift:1050-1056 (guid = Atom `entry.id` :949, RSS `item.guid?.value` :965-970, JSON), and V2FullRuntime.swift:186-192 (guid nil, link from `.externalURL`).
- Raw external keys survive only as locals/`ShadowParsedEntry` (guid/link) RSSFetcher.swift:1060-1076; never on FeedItem/record.
- `struct FeedItemRecord` FeedStore.swift:8391, table `feed_item` :8427. Columns :8392-8425: id,sourceURL,sourceTitle,region,category,title,excerpt,url,imageURL,audioURL,duration,publishedAt,fetchedAt,isRead,openedAt,clickedAt,consumedAt,language,updatedAt,authors,itemCategories,rights,attributionTitle/URL/FeedURL,enclosures,languageFromFeed,alternateLinks. Persists only hashed `id` (id=item.id :8458); guid/link/title source key are DROPPED.

## 3. `feedmine/FeedEngine/Identities.swift`
- `struct SourceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible { let rawValue: UInt32 }` :32-37. Siblings: `SourceKey`(String) :15-20, `NodeKey` :52-57, `CatalogNodeID{rawValue:UInt32}` :60-65, `CatalogNodeKind` :84-90.
- Reserve: `extension SourceID { static let none = SourceID(rawValue: 0) }` :72-74; `CatalogNodeID.none`/`.root` = 0 :77-81.
- Identities.swift contains no narrowing conversion. Boundary conversions: derivation `stableUInt32Digest` CatalogIdentity.swift:56-61 (SHA-256 first 4 bytes → `(p<<8)|UInt32(byte)`, 0→1). Persist widen UInt32→Int64 SQLiteCatalogStore.swift:255,284,286,302-303,329,394,412,544,546,551,599. Reads narrow unchecked Int64→UInt32: `SourceID(rawValue: UInt32(rawID))` :813; `CatalogNodeID(rawValue: UInt32(rawID))` :777 and :867; cursor `UInt32($0.entityID)` :501. Parallel `FeedDomain.SourceID{rawValue: UInt64}` RuntimeIDs.swift:14-24 with throwing init rejecting 0, `RuntimeRowID.checked(Int64)` :111-118; explicitly not positionally convertible from legacy UInt32 SourceID :5-8.


--- D2 — identidade de catálogo, storage e referências duráveis ---
## 1. FeedEngine/CatalogIdentity.swift (:63)
- `sourceKey(for:)`=`SourceKey(canonicalURLKey(url))` :12-14; `canonicalURLKey` delegates to `OPMLParser.normalizeURL` :29-31.
- Canonicalization (OPMLParser.swift:677-742, identity mode): XML-entity decode :678; validate scheme/host/port before early returns :685-697; output scheme forced `https` :732; strip `www.` :706; default ports 443/80 dropped :720-724; ALL trailing `/` removed :727-728; `filteredIdentityQuery` drops tracking params :729.
- `nodeKey(pathComponents:)`=join "/" :16-18. `sourceID`/`nodeID`=`stableUInt32Digest(key,reservedZero:true)` :20-26.
- Digest: SHA256(utf8) :56; first 4 bytes big-endian fold→UInt32 :57-59; 0→1 :61.
- Types: SourceID/CatalogNodeID raw `UInt32` (Identities.swift:32-37,61-66); `SourceID.none`=0, `CatalogNodeID.root`=0 :72-80. Collision→`FeedEngineError.identityCollision` (SQLiteCatalogStore.swift:186-196).
- Callers: SQLiteCatalogStore.swift:100-101,110,132-133; OPMLCatalogScanner.swift:62,95,104,149,159; CatalogInput.swift:12,165; RuntimeV2/V2Acquisition.swift:347.

## 2. FeedEngine/SQLiteCatalogStore.swift
`SQLiteCatalogSchema.create` :634-703; `PRAGMA foreign_keys=ON` :635.
- `catalog_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)` :637-640.
- `catalog_node(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, parent_id INTEGER REFERENCES catalog_node(id), name TEXT NOT NULL, kind INTEGER NOT NULL, source_count INTEGER NOT NULL DEFAULT 0, child_count INTEGER NOT NULL DEFAULT 0, language TEXT)` :643-652; idx :654.
- `catalog_source(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, title NOT NULL, declared_url NOT NULL, request_url NOT NULL, display_host, media_kind NOT NULL, language, site_url, description, tags, nature, activity, latest_item_at, quality_score, default_enabled INTEGER NOT NULL DEFAULT 1, contact_email, contact_name, contact_source, contact_type)` :656-677; idx :679.
- `catalog_placement(id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL REFERENCES catalog_source(id) ON DELETE CASCADE, node_id INTEGER NOT NULL REFERENCES catalog_node(id) ON DELETE CASCADE, node_name NOT NULL, opml_file NOT NULL, sort_order NOT NULL, title_override, language_override, media_kind_override, UNIQUE(source_id,node_id,opml_file,sort_order))` :681-692; idx :694-695.
- No item table: only these 4 + `catalog_source_fts` FTS5(title,description,tags,display_host,language,media_kind,…) :696-703 (CREATE TABLE at :637,643,656,681,697).
- Build→swap: tmp `.<db>.tmp` :55-57; `DatabaseQueue(path:tmp)` :65; schema+`writeCatalog` :66-69; `replaceItemAt(db,withItemAt:tmp)` else `moveItem` :72-76. `schema_version`="2" :236.
- `UInt32(rawID)` narrowing: node :777, source :813, placement node :867; writes `Int64(id.rawValue)` :269,293,300.

## 3. Services/FeedStore.swift (feedmine.sqlite)
- `PRAGMA journal_mode=WAL` + `foreign_keys=ON` :1360-1362.
- `feed_item` v1 :7824-7840: `id TEXT PRIMARY KEY`; NOT NULL `source_url,source_title,region,category,title,excerpt,url,published_at INTEGER,fetched_at INTEGER`; nullable `image_url,audio_url,duration,opened_at INTEGER`; `is_read INTEGER NOT NULL DEFAULT 0`. v7 `language TEXT` :7951-7954; v19 `clicked_at,consumed_at INTEGER` :8134-8136; v23 `updated_at,authors,item_categories,rights,attribution_title,attribution_url,attribution_feed_url,enclosures,language_from_feed,alternate_links` :8219-8236. Indexes :7841-7842, `idx_item_read` partial :7845-7847, :7914-7917. FTS `feed_item_fts` content='feed_item' content_rowid='rowid' :8238-8244.
- Other tables: `source_health(url TEXT PRIMARY KEY,…)` :7905-7911 (+etag/last_modified v22 :8193); `source_toggle(key TEXT PRIMARY KEY,state)` :7920-7923; `source_history_access(source_url TEXT PRIMARY KEY,last_accessed_at NOT NULL)` :8126-8129; `smart_feed_item(smart_feed_id,item_id TEXT REFERENCES feed_item ON DELETE CASCADE,matched_at,PK(smart_feed_id,item_id))` :8160-8166; `smart_feed_source(…,PK(smart_feed_id,source_url))` :8179-8185; `image_retry_queue(item_id TEXT PRIMARY KEY REFERENCES feed_item ON DELETE CASCADE,…)` :8261-8270; `image_resolution(item_id TEXT PRIMARY KEY REFERENCES feed_item(id) ON DELETE CASCADE,…)` :8280-8297.
- Legacy bookmark tables also in feedmine.sqlite v1: `bookmark_list(id auto PK,…)` :7849-7859; `bookmark_item(list_id REFERENCES bookmark_list ON DELETE CASCADE, item_id TEXT REFERENCES feed_item ON DELETE CASCADE, added_at, sort_order, PRIMARY KEY(list_id,item_id))` :7861-7869. FeedStore now delegates to BookmarkStore :7703-7737.
- Per-item write: `persistFetchedItems` :4632; dedup vs `loadedIDs` :4650-4658; `FeedItemRecord(from:).insert(db)` new :4788-4796, `.update(db)` on newer Atom :4798-4805; repair `UPDATE feed_item SET image_url=? WHERE id=? AND image_url IS NULL` :4694-4699.
- Item id: `FeedItem.generateID`=SHA256 hex of `"\(sourceURL)|\(guid ?? link ?? title|publishedAt)"` (FeedItem.swift:393-405); stored as `feed_item.id` (FeedStore.swift:8392).
- Retention: `performLightExpurgo` 30d cutoff -2592000, `DELETE … LIMIT 500`, excludes bookmark_item/smart_feed_item/source_history_access :7563-7590; `capSourceItemsBatch` keeps 50 newest/source :7602-7645; `performHeavyMaintenance` weekly VACUUM :7655-7690.
- Read/seen writes: markAsSeen `consumed_at` :3938-3948; markAsRead `is_read=1,consumed_at` :3952-3969; markAsClicked `+opened_at,clicked_at` :3972-3990; markAsUnread `is_read=0` :4061-4076.

## 4. Services/UserStateStore.swift + BookmarkStore.swift (user.sqlite)
- WAL + foreign_keys :196-198; migrations :208-458.
- v1: `bookmark_list(id auto PK, name NOT NULL, sort_order DEFAULT 0, created_at NOT NULL, is_default DEFAULT 0, search_query, search_region, search_category, search_active DEFAULT 0)` :209-218; `bookmark_item(list_id INTEGER NOT NULL REFERENCES bookmark_list ON DELETE CASCADE, item_id TEXT NOT NULL, added_at INTEGER NOT NULL, sort_order INTEGER DEFAULT 0, PRIMARY KEY(list_id,item_id))` :221-227; idx :230-233. item_id has NO FK to feed_item (cross-DB).
- v2/v7: `source_collection(id auto PK,name,sort_order,created_at)` :243-247; `source_collection_member(collection_id REFERENCES source_collection ON DELETE CASCADE, source_identity NOT NULL, source_url NOT NULL, title_snapshot, media_kind, added_at, sort_order, PK(collection_id,source_identity))` :327-336; rebuilt with `source_identity=OPMLParser.normalizeURL(source_url)` :350; renamed+indexed :375-381.
- v8 `imported_source`: `id auto PK, source_identity TEXT NOT NULL UNIQUE, request_url NOT NULL, title NOT NULL, category DEFAULT 'Imported', media_kind, language, added_at NOT NULL, enabled DEFAULT 1` :388-397; idx :399-400.
- v10 `bookmark_snapshot`: `list_id REFERENCES bookmark_list ON DELETE CASCADE, item_id TEXT NOT NULL, title NOT NULL, url, source_title, source_url, excerpt, media_url, authored_at, captured_at NOT NULL, PK(list_id,item_id)` :425-437.
- v11 `user_operation`: `operation_id TEXT PRIMARY KEY, kind, subject_id TEXT NOT NULL, payload_json, state, created_at, applied_at, failure_reason` :446-455.
- `user_metadata(key TEXT PRIMARY KEY,value)` :269-272; `smart_feed` :276-283; `curated_feed` :307-315.
- BookmarkStore: owns bookmark_list/bookmark_item in `userDB`; `feed_item` only `contentDB` :6-11; toggle `INSERT OR IGNORE bookmark_item` :231-233; snapshot upsert :236-247; delete :257-260; pin from feed_item :432-435.
- Read/seen state: ABSENT from UserStateStore (no table; grep read|seen|consumed → only contentDB joins :884-886). Durable read state is feedmine.sqlite `feed_item.is_read/opened_at/clicked_at/consumed_at`; runtime read authority absent (RuntimeV2/V2FullRuntime.swift:34-37,101-105).


--- D3 — identidade de card e a fronteira de ingestão RSS ---
# Digest: Card identity + RSS ingress (feedmine @ 70f7b06b, working tree)

## 1. Card identity
- `PreparedFeedCard` `feedmine/Models/PreparedFeedCard.swift:103-119`: `id: String { item.id }` (:104), `item: FeedItem` (:108), `media: RenderReadyMedia` (:111; cases image/placeholder/none :49-64), `layout: PreparedCardLayout` (:114; hero/thumbnail/textOnly :86-90), `presentationEpoch: UInt64` (:118). No card-specific ID field.
- Minted at `CardPreparationCoordinator.decodeToRenderReady` `feedmine/Services/CardPreparationCoordinator.swift:649-654`; cached `renderReadyByID[item.id]` (:17,191,325-327,438).
- Legacy `FeedCardPresentation` `feedmine/Models/FeedCardPresentation.swift:75-119` (item/media/layout/isRead/isBookmarked/preparedAt); adapter `init(from:prepared:)` :103-118; deprecation note :5-8.
- V2 card ID: `MainFeedCardBridge.cardID(forLegacyItemID:)` `feedmine/RuntimeV2/MainFeedCardBridge.swift:206-224` — SHA256(item.id) first 8 bytes → Int64 clamped into `PublicationCardID`; deterministic alias, NOT an allocation (real `PublicationCardID` allocated by runtime, ADR-003).
- Minted into `CardPresentation` at `MainFeedCardBridge.value` :191 (`id: cardID(forLegacyItemID: item.id)`); entry `MainFeedCardBridge.card` :203-210.
- Handoffs to SwiftUI:
  - Main feed: `FeedScreen.swift:955-975` `ForEach(section.rows)` + `.id(row.id)`; `MainFeedRow.id = item.id` `MainFeedPresentationPipeline.swift:13-18`; `row.card` → `FeedItemView` :957.
  - `FeedItemView.swift:40` → `FeedItemCardView(item:isRead:isBookmarked:mediaSlot:affordances:)`.
  - `CollectionManagementView.swift:373` and `:668`; `FeedComposerScene.swift:82-92`; `WelcomeScene.swift:152-161` call `MainFeedCardBridge.card`/`affordances` and pass result to `FeedItemCardView`.
  - `FeedItemCardView.swift:4-40`: Equatable on item/mediaSlot/affordances/states; takes no cardID — SwiftUI identity is legacy `item.id`.
- Runtime consumes cardID: `itemIDByCardID` `MainFeedPresentationPipeline.swift:140,459`; `MainFeedRuntime.swift:732,753,767,811,839,880`; `CardActionBridge.swift:30-63`; `V2FullRuntime.swift:45-132,401-416`. `MainFeedCardValue` `MainFeedCardBridge.swift:53-56`.

## 2. RSS ingress `feedmine/Services/RSSFetcher.swift`
- actor `:4`. Entries: `fetch` :107-123 (shadow mirror :117), `performFetch` :124-217, `fetchStarterSource` :219-221, `fetchAll` :224, `fetchStarter` :304.
- Gate `LegacyAcquisitionGate.allowsFeedRequest()` :138 → `.legacyProducerClosed`.
- Transport proto `FeedHTTPTransport` `feedmine/Services/FeedHTTPSync.swift:5-7`; actor `FeedHTTPSync`.
- Parser: FeedKit `FeedParser(data:).parse()` :169, :879 (vendor `Packages/FeedRuntimeV2/.build/checkouts/FeedKit/Sources/FeedKit/Parser/FeedParser.swift:32`).
- Translators `.atom` :908-950, `.rss` :952-981, `.json` :983-1015; `makeItem` :1020-1127. Atom link pick :915-921, fallback `entryLink ?? entry.id` :940. Google News channel-image suppression :886-906.
- Drops: no link/audio `guard let resolvedLink else { return nil }` :1032-1038; empty title `guard !sanitizedTitle.isEmpty else { return nil }` :1045; parse failure `extractItems(fromFeedData:)` guard :879.
- HTTP (`FeedHTTPSync.swift`): http→https upgrade :74-77; If-None-Match :85-86; If-Modified-Since :88-89; 304 :107-115; 429/503+Retry-After :117-126; 200 body 20MB cap :141-160; ETag/Last-Modified/Cache-Control/Expires extract :214-230; `canonicalURL = httpResponse.url` :166. Redirects (301/302/307/308) followed transparently by URLSession; only final response observed :128-133; http→https upgrade applies to initial request only :130-132.
- Fetcher applies `updatedValidators.canonicalURL` :181-182; ttl/skipHours/skipDays/lastBuildDate/capabilities :174-180; empty→`.modifiedWithoutNewItems` :185-193; audio probe :499-533.

## 3. Persisted from the wire
- feed_item schema `feedmine/Services/FeedStore.swift:7825-7839`: PK `id` (= generateID hash), `source_url`, `url`, `published_at`, `image_url`, `audio_url`, … **no guid column** (repo grep `guid` → `feedmine/Models/FeedItem.swift:394-402` only).
- ID mint: `FeedItem.generateID(sourceURL:guid:link:title:publishedAt:)` `FeedItem.swift:394-406` = SHA256("sourceURL|guid ?? link ?? (title|ts)"); called `RSSFetcher.swift:1050-1056`. Wire guid/link not stored raw.
- Persist: `persistFetchedItems` `FeedStore.swift:4632-4690`; `persistInSlices` :2385; `FeedItemRecord` :8393-8520 (`url` :8460, `published_at` :8471, CodingKeys `url`/`published_at`/`updated_at` :8438-8454, `toFeedItem` :8516).
- source_health: `etag`, `last_modified`, `canonical_url`, `cache_control_*`, `expires`, `last_outcome`, `retry_after`, `ttl`, `skip_hours/days`, `last_build_date`, `capabilities`, publication interval — upsert :1284-1335, load :1219-1255, `SourceHealthRecord` :8337-8368; `HTTPValidators` `feedmine/Models/HTTPValidators.swift:7-26`.
- Raw wire guid/link surface only in `ShadowParsedEntry` mirror `RSSFetcher.swift:1060-1073`; not persisted.


--- D4 — superfície de compatibilidade e a ponte de identidade do runtime V2 ---
## 1. Version / schema compatibility (current tree)

**App version** — Info.plist `CFBundleShortVersionString`/`CFBundleVersion`, used only for display: `feedmine/Views/SettingsSheetView.swift:247`, archive tagging `Makefile:139-142`. No UserDefaults key persists app version (searched `lastAppVersion|appVersion` on disk module → absent).

**Migration versioning (GRDB `DatabaseMigrator`; version authority is GRDB's `grdb_migrations` table, not a numeric column):**
- content DB `feedmine.sqlite`: `feedmine/Services/FeedStore.swift:7823` (`v1`) … `:8279` (`v25_image_resolution`), applied `FeedStore.swift:8312`; store init `:1140`.
- user DB `user.sqlite`: `feedmine/Services/UserStateStore.swift:208` (`v1_bookmarks`) … `:441` (`v11_user_operation`), run `:459`.
- runtime DB: `Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift:56` (`v1_runtime_metadata`) … `:139` (`v7_user_list_membership`); `knownMigrationIdentifiers:20`, `through(_:) :32`. `RuntimeMetadata.schemaVersionKey="runtime_schema_version"`, `schemaNameKey`/`schemaName="runtime-v2"` at `Packages/FeedRuntimeV2/Sources/FeedStorage/RuntimeDatabase.swift:142-145`; explicitly "not an independent migration counter" (`:129-136`).
- catalog (bundled `catalog.sqlite`): `catalog_metadata` rows `schema_version=2`, `catalog_version=1789618085179441` written `feedmine/FeedEngine/SQLiteCatalogStore.swift:236-237`, read `:615`. Update manifest `supportedSchemaVersion=1` `feedmine/Services/CatalogUpdateService.swift:44`, checked `:97-98`.

**UserDefaults keys** (`feedmine/Services/AppSettings.swift:8-56`): filters `filterRegion/filterTaxonomyNodes/filterContentType/filterMood/filterSetAt/filterAutoExpire/filterLanguages` (`:11-19`), `activePreset :42`, `toggleDisabled/toggleEnabledOverrides :46-47`, session/streak `:33-38`.

**A migration must preserve (installed app):** bookmarks — `user.sqlite` `bookmark_item` + durable `bookmark_snapshot` (`UserStateStore.swift:418-440`; write `feedmine/Services/BookmarkStore.swift:231-252`); read state — `feed_item.is_read` in `feedmine.sqlite` (`FeedStore.swift:3965`); imported sources — `user.sqlite.imported_source` (`UserStateStore.swift:388-402`, legacy JSON path `:977`); filters — the `filter*` UserDefaults keys above.

## 2. Runtime bridge status

**DDL** `RuntimeMigrations.swift:414-423` `legacy_source_map` (`catalog_source_key`, `catalog_source_id>0`, `canonicalization_version>0`, `runtime_source_id`, `legacy_url`, `mapped_at`, PK(key,version)); `:425-433` `legacy_item_map` (`legacy_item_id` PK, `legacy_source_url`, `origin_record_id`, `origin_revision_id`, `confidence`, `mapped_at`).

**Persistence** `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/LegacyMappingStore.swift:19-43` (`recordSourceMapping`, `ON CONFLICT DO NOTHING`), `:64-95` (`legacy_item_map`).

**Accessor that throws `missingSourceMapping`** — `LegacySourceMap.runtimeSource(forCatalogSource:canonicalizationVersion:)` `Packages/FeedRuntimeV2/Sources/FeedDomain/Identity/EditorialIdentity.swift:150-165`; error case `:63`; conflict check `:154-160`; `isDisputed(forCatalogSource:) :190`. In-memory types: `EditorialSourceKey :21`, `CatalogSourceID :26`, `LegacySourceMap :103`, `LegacyItemMapping :256`, `LegacyItemMap :303`.

**Source-id allocation today** — `RuntimeSourceRegistry.sourceID(...)` inserts into `source` (`INTEGER PRIMARY KEY CHECK(id>0)` DDL `RuntimeMigrations.swift:221-230`) with `ON CONFLICT ... DO NOTHING` then `SELECT id`, returning `SourceID(UInt64(id))`: `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/SourceRegistry.swift:30-62`; `existingSourceID :65`; nothing is derived from URL/digest. Production write of the bridge row: `feedmine/RuntimeV2/V2Acquisition.swift:165-197` (failure refuses the source, logs `source-bridge-write-failed`).

**`FeedStorage/Publication/`** contains only `PublicationRepository.swift`, which owns `feed_edition`, `feed_segment`, `published_card`, `published_asset_ref`, `asset_version`, `media_preparation` (`PublicationRepository.swift:7-8`); DDL `RuntimeMigrations.swift:481-635`.

## 3. Does any shipping mode compose a runtime DB today?

Launch: `feedmine/feedmineApp.swift:214` `MainFeedRuntime.launch()` → `MainFeedRuntime.swift:373` `RuntimeModeLaunch.decide(in:.standard, arguments: ProcessInfo.processInfo.arguments)`. Mode resolution table (`Packages/FeedRuntimeV2/Sources/FeedRuntime/RuntimeMode.swift:57-79`): `(false,false,false) → .legacy` (`:57-58`). Compose: `feedmine/RuntimeV2/RuntimeCompositionRoot.swift:74-120` — `ownsAcquisition` (`v2Full`) builds `RuntimeDatabase` in the production dir (`:80-81`); `runsShadow` (`mirroredShadow`) builds one in `shadow/` (`:111-112`); everything else returns `.legacyOnly(reason:)` (`:98-105`) with **no** `RuntimeDatabase`. Request keys `runtimeV2.requested.shadow|ui|network` and args `-RuntimeV2Shadow|-RuntimeV2UI|-RuntimeV2Network` at `feedmine/RuntimeV2/RuntimeMode.swift:52-60`; `RuntimeModeLaunch.decide/current :129-146`. Repo-wide search: only tests call `RuntimeModeLaunch.request` (`feedmineTests/MainFeedRuntimeV2Tests.swift:35,56,439…`, `RuntimeV2ShadowTests.swift:834,885`); no call from app/Views (searched `runtimeV2|RuntimeV2|V2UI|v2Network` under `feedmine/Views` → absent). So a stock launch resolves `.legacy` → no runtime DB; `v2Full` (production DB) and `mirroredShadow` (shadow DB) are composable only via a stored request or launch argument.


[[TAREFA]]

Produza o PLANO DE MIGRAÇÃO que a §16 do seu ADR-003 declarou necessário, como documento normativo. Não reescreva o ADR-003 inteiro: produza o documento de migração que ele delega.

Autoridade: onde estes fatos contradisserem a sua memória do projeto (Blueprint v0.4, Technical Architecture v0.1, o ADR-003 que você escreveu), ESTES FATOS VENCEM. Você não tem acesso ao repo.

O documento DEVE conter, nesta ordem:
1. CONTRADIÇÕES — quais suposições do ADR-003/V0.4 os fatos invalidam ou confirmam, uma por linha, cada uma citando o fato (path:line) que a resolve. Seja adversarial.
2. MAPA DE MIGRAÇÃO — os oito pontos da §16, um por subseção: decisão (M1..M8), o que muda (tabela/coluna/tipo, arquivo, tipo Swift), o que explicitamente NÃO muda, e a invariante que continua valendo. Inclua DDL quando houver mudança de schema.
3. FATIAS EXECUTÁVEIS — a ordem dos slices (PR-00, PR-01, …): pré-requisito, alvos (arquivos/tabelas), o teste nomeado que prova o slice, critério de rollback. Nada pode depender do que não existe no checkout.
4. RISCO DE PERDA DE DADOS — tabela por tabela: bookmark_item, bookmark_snapshot, feed_item (is_read, clicked_at, consumed_at), imported_source, e os filtros em UserDefaults; risco exato e mitigação. Qualquer caminho que perca dado do usuário = BLOQUEADOR.
5. DECISÕES HUMANAS — só o que código e arquitetura não decidem, com pergunta fechada e opções; marque [PRECISA DE HUMANO].

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; depois o documento completo em markdown dentro de UM bloco de código; nada depois do bloco; sem canvas/Document; máximo ~4000 palavras; não repita os fatos, cite-os.