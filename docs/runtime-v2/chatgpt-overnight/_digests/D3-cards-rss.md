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
