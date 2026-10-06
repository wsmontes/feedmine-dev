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
