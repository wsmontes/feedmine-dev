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
