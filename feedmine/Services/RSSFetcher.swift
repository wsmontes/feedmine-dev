import Foundation
import FeedKit

actor RSSFetcher {
    /// Collected per-source response times (ms) from the most recent batch.
    /// Callers read + clear via `drainResponseTimes()` after each batch.
    private var pendingResponseTimes: [String: Double] = [:]

    /// Return and clear the accumulated response times from the last batch.
    func drainResponseTimes() -> [String: Double] {
        let times = pendingResponseTimes
        pendingResponseTimes.removeAll(keepingCapacity: true)
        return times
    }

    /// How many feed fetches this fetcher has attempted since the process started: one per
    /// `performFetch`, whether the transport succeeded or failed.
    ///
    /// Counted here rather than derived from the demand ledger because the two answer different
    /// questions: the ledger counts *decisions* (an endpoint was `shared`, so no request was made),
    /// and this counts *requests actually made*. "No double acquisition" is a claim about requests.
    private(set) var attemptedFetchCount = 0

    /// The number of fetches attempted so far. A demand that issues no request leaves this unchanged.
    func fetchAttemptCount() -> Int { attemptedFetchCount }

    /// Where fetches go. Injected so a test can script and count them: `URLProtocol` registration does
    /// not reach these sessions (`docs/runtime-v2/baseline.md` §8.8.3 measured `blockedRequests` at 0),
    /// which left a real `fetchAll`'s interleaving unexercised.
    private let transport: any FeedHTTPTransport
    private let starterTransport: any FeedHTTPTransport

    /// PR-12: the shadow observes what this fetcher already fetched. It is resolved per call rather
    /// than captured at init, because a fetcher built before the shadow is installed must still
    /// observe — a silent no-op would look exactly like perfect agreement.
    private let injectedMirrorSink: (any ShadowMirrorSink)?
    private var mirrorSink: (any ShadowMirrorSink)? {
        injectedMirrorSink ?? ShadowMirrorRegistry.current
    }

    /// Cache of audio-URL → playable? so repeat fetches never re-probe the same
    /// enclosure (podcast episode URLs are stable).
    private var audioPlayability: [String: Bool] = [:]

    private static let playabilityCacheKey = "audio_playability_cache"

    /// The session the audio playability probe uses. It asks whether a podcast enclosure is playable,
    /// which is not feed acquisition, so it is not the feed transport. Built on first use: a fetcher
    /// given its transports allocates no session at all.
    private lazy var probeSession: URLSession = Self.makeSession(
        cache: URLCache(memoryCapacity: 4_194_304, diskCapacity: 20_971_520),
        fastLane: false
    )

    init(
        shadow: (any ShadowMirrorSink)? = nil,
        transport: (any FeedHTTPTransport)? = nil,
        starterTransport: (any FeedHTTPTransport)? = nil
    ) {
        self.injectedMirrorSink = shadow
        // Restore persisted playability cache (#34) so probes survive restart
        if let saved = UserDefaults.standard.dictionary(forKey: Self.playabilityCacheKey) as? [String: Bool] {
            audioPlayability = saved
        }

        // Both feed sessions share one cache, so a fast-lane response is also available to the regular
        // refresh pipeline. Nothing is built when both transports are supplied.
        if let injected = transport {
            self.transport = injected
            self.starterTransport = starterTransport ?? injected
        } else {
            let cache = URLCache(memoryCapacity: 4_194_304, diskCapacity: 20_971_520)
            self.transport = transport ?? FeedHTTPSync(session: Self.makeSession(cache: cache, fastLane: false))
            self.starterTransport = starterTransport ?? transport
                ?? FeedHTTPSync(session: Self.makeSession(cache: cache, fastLane: true))
        }
    }

    /// The two session shapes this fetcher has always used: a normal one, and a fast lane with a real
    /// wall-clock ceiling so one unresponsive publisher cannot stretch a starter deadline to the
    /// normal resource timeout.
    private static func makeSession(cache: URLCache, fastLane: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = fastLane ? 5 : 15
        config.timeoutIntervalForResource = fastLane ? 7 : 30
        config.waitsForConnectivity = false      // let timeouts fire; app gates on its own reachability
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 2 // be a good citizen
        config.urlCache = cache
        config.httpAdditionalHeaders = [
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/json, text/xml"
        ]
        return URLSession(configuration: config)
    }

    /// Fetch and parse a single feed with conditional GET support.
    /// - Parameters:
    ///   - source: The feed source to fetch.
    ///   - validators: Previously-stored HTTP validators for conditional GET.
    ///   - transport: HTTP transport to use (defaults to this fetcher's regular transport).
    ///
    /// PR-12 hook (level 1): this is the convergence point where the items, the source and the
    /// outcome exist together, so the shadow is told what the legacy path produced — including a 304,
    /// an empty response and a failure, which mirroring only "new items" would lose. The shadow
    /// observes and never fetches: nothing below it can start network work.
    func fetch(_ source: FeedSource,
               validators: HTTPValidators = HTTPValidators(),
               transport: (any FeedHTTPTransport)? = nil) async -> FeedFetchResult {
        let result = await performFetch(source, validators: validators, transport: transport)
        // A fetch the mode's gate refused is not legacy behaviour to mirror: nothing was fetched, so
        // there is nothing to observe, and `ShadowOutcomeKind` maps it to no kind at all.
        if let kind = ShadowOutcomeKind(result.outcome) {
            mirrorSink?.mirrorFetch(ShadowFetchMirror(
                sourceURL: source.url,
                sourceTitle: source.title,
                outcome: kind,
                items: result.items
            ))
        }
        return result
    }

    private func performFetch(_ source: FeedSource,
                              validators: HTTPValidators,
                              transport: (any FeedHTTPTransport)?) async -> FeedFetchResult {
        // The one place the mode closes the legacy producers (plan §13). It is checked before the
        // attempt is counted, so `fetchAttemptCount()` stays 0 in a launch whose runtime owns
        // acquisition: a request that was never meant to happen is not an attempt, and the
        // no-double-acquisition proof reads this counter.
        guard LegacyAcquisitionGate.allowsFeedRequest() else {
            return FeedFetchResult(source: source, items: [], outcome: .legacyProducerClosed)
        }
        // One attempt, counted before the transport is asked: a request this fetcher meant to make is
        // what the no-double-acquisition proof counts, whether or not the network answered.
        attemptedFetchCount += 1
        guard !Task.isCancelled else {
            return FeedFetchResult(source: source, items: [], outcome: .failed(CancellationError()))
        }

        let startedAt = ContinuousClock().now
        let transport = transport ?? self.transport
        let httpResult = await transport.fetch(source, validators: validators)
        let elapsed = ContinuousClock().now - startedAt

        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        pendingResponseTimes[OPMLParser.normalizeURL(source.url)] = ms

        switch httpResult.outcome {
        case .notModified:
            return FeedFetchResult(
                source: source, items: [],
                outcome: .notModified, elapsedMs: ms
            )

        case .throttled(let until):
            return FeedFetchResult(
                source: source, items: [],
                outcome: .throttled(until: until), elapsedMs: ms
            )

        case .failed(let error):
            return FeedFetchResult(
                source: source, items: [],
                outcome: .failed(error), elapsedMs: ms
            )

        case .success(let data):
            let parser = FeedParser(data: data)
            let result = parser.parse()

            switch result {
            case .success(let feed):
                let feedLevelMeta = extractFeedLevelMetadata(from: feed, source: source)
                var updatedValidators = httpResult.updatedValidators
                updatedValidators.ttl = feedLevelMeta.ttl
                updatedValidators.skipHours = feedLevelMeta.skipHours
                updatedValidators.skipDays = feedLevelMeta.skipDays
                updatedValidators.lastBuildDate = feedLevelMeta.lastBuildDate
                updatedValidators.capabilities = feedLevelMeta.capabilities
                if let canonicalURL = httpResult.canonicalURL {
                    updatedValidators.canonicalURL = canonicalURL
                }

                let items = extractItems(from: feed, source: source)
                if items.isEmpty {
                    updatedValidators.lastOutcome = .modifiedWithoutNewItems
                    Log.network.info("Empty feed: \(source.title)")
                    return FeedFetchResult(
                        source: source, items: [],
                        outcome: .modifiedWithoutNewItems(validators: updatedValidators),
                        elapsedMs: ms
                    )
                }
                let validated = await validateAudio(in: items)
                updatedValidators.lastOutcome = .modifiedWithNewItems
                return FeedFetchResult(
                    source: source, items: validated,
                    outcome: .modifiedWithNewItems(validated, validators: updatedValidators),
                    elapsedMs: ms
                )

            case .failure(let error):
                var failedValidators = httpResult.updatedValidators
                failedValidators.lastOutcome = .failed
                Log.network.error("Parse failure for \(source.title): \(error)")
                return FeedFetchResult(
                    source: source, items: [],
                    outcome: .failed(error),
                    elapsedMs: ms
                )
            }
        }
    }

    /// Cold-start fetch that uses the starter HTTP sync with the 5s/7s
    /// timeout session so a slow publisher can't stretch the cold-start
    /// deadline past the ~2.25s per-feed window.
    private func fetchStarterSource(_ source: FeedSource) async -> FeedFetchResult {
        await fetch(source, validators: HTTPValidators(), transport: starterTransport)
    }

    /// Fetch multiple feeds concurrently with a real concurrency cap.
    func fetchAll(_ sources: [FeedSource], maxConcurrent: Int = 5) async -> FeedFetchBatch {
        var allItems: [FeedItem] = []
        var fetchedSourceCount = 0
        var failedSourceCount = 0
        var emptySourceCount = 0
        var notModifiedCount = 0
        var throttledCount = 0
        var gatedSourceCount = 0
        var sourceOutcomes: [String: FeedFetchOutcome] = [:]

        // Sliding-window concurrency: keep up to `maxConcurrent` fetches in
        // flight at all times. As each one finishes we immediately start the
        // next, so a single slow feed can only occupy its own slot — it can't
        // stall the whole batch. (The previous chunked approach blocked every
        // free slot until the slowest feed in the chunk returned, so with
        // maxConcurrent=15 one hung feed idled up to 14 others for the full
        // request timeout.)
        let cap = max(1, maxConcurrent)

        await withTaskGroup(of: FeedFetchResult.self) { group in
            var iterator = sources.makeIterator()

            // Prime the window.
            var started = 0
            while started < cap, let source = iterator.next() {
                group.addTask { await self.fetch(source) }
                started += 1
            }

            // Drain as results arrive, refilling each freed slot.
            while let result = await group.next() {
                // A request the gate refused produced no outcome: it stays out of `sourceOutcomes`, so
                // the caller's demand ledger cannot count it as a refill that happened and the adaptive
                // scheduler cannot read it as a failure.
                if case .legacyProducerClosed = result.outcome {
                    gatedSourceCount += 1
                } else {
                    sourceOutcomes[result.source.url] = result.outcome
                }
                switch result.outcome {
                case .modifiedWithNewItems:
                    fetchedSourceCount += 1
                    allItems.append(contentsOf: result.items)
                case .modifiedWithoutNewItems:
                    emptySourceCount += 1
                case .notModified:
                    notModifiedCount += 1
                case .failed:
                    failedSourceCount += 1
                case .throttled:
                    throttledCount += 1
                case .legacyProducerClosed:
                    break
                }

                if Task.isCancelled {
                    // Stop starting new work; signal in-flight fetches to bail
                    // early, then keep draining until the window empties.
                    group.cancelAll()
                } else if let source = iterator.next() {
                    group.addTask { await self.fetch(source) }
                }
            }
        }

        return FeedFetchBatch(
            items: allItems,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount,
            notModifiedCount: notModifiedCount,
            throttledCount: throttledCount,
            gatedSourceCount: gatedSourceCount,
            sourceOutcomes: sourceOutcomes
        )
    }

    /// Cold-start fetch that stops waiting as soon as there is enough content
    /// for the first page and its runway. Slow feeds are cancelled for this
    /// pass and remain eligible for the progressive background fetch.
    func fetchStarter(
        _ sources: [FeedSource],
        maxConcurrent: Int = 15,
        minimumSuccessfulSources: Int = 4,
        minimumItemCount: Int = 40,
        deadline: Duration = .milliseconds(2_250),
        onProgress: (@MainActor @Sendable (FeedFetchResult) -> Void)? = nil
    ) async -> FeedFetchBatch {
        enum Event: Sendable {
            case result(FeedFetchResult)
            case deadline
            case cancelled
        }

        var allItems: [FeedItem] = []
        var fetchedSourceCount = 0
        var failedSourceCount = 0
        var emptySourceCount = 0
        var notModifiedCount = 0
        var throttledCount = 0
        var gatedSourceCount = 0
        var sourceOutcomes: [String: FeedFetchOutcome] = [:]
        let cap = max(1, maxConcurrent)

        await withTaskGroup(of: Event.self) { group in
            var iterator = sources.makeIterator()
            var activeFetches = 0

            while activeFetches < cap, let source = iterator.next() {
                group.addTask { .result(await self.fetchStarterSource(source)) }
                activeFetches += 1
            }
            group.addTask {
                do {
                    try await Task.sleep(for: deadline)
                    return .deadline
                } catch {
                    return .cancelled
                }
            }

            eventLoop: while let event = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break eventLoop
                }
                switch event {
                case .cancelled:
                    continue
                case .deadline:
                    group.cancelAll()
                    break eventLoop
                case .result(let result):
                    activeFetches -= 1
                    if case .legacyProducerClosed = result.outcome {
                        gatedSourceCount += 1
                    } else {
                        sourceOutcomes[result.source.url] = result.outcome
                    }
                    switch result.outcome {
                    case .modifiedWithNewItems:
                        fetchedSourceCount += 1
                        allItems.append(contentsOf: result.items)
                    case .modifiedWithoutNewItems:
                        emptySourceCount += 1
                    case .notModified:
                        notModifiedCount += 1
                    case .failed:
                        failedSourceCount += 1
                    case .throttled:
                        throttledCount += 1
                    case .legacyProducerClosed:
                        break
                    }
                    await onProgress?(result)

                    let runwayReady = fetchedSourceCount >= minimumSuccessfulSources
                        && allItems.count >= minimumItemCount
                    if runwayReady {
                        group.cancelAll()
                        break eventLoop
                    }

                    if let source = iterator.next() {
                        group.addTask { .result(await self.fetchStarterSource(source)) }
                        activeFetches += 1
                    } else if activeFetches == 0 {
                        group.cancelAll()
                        break eventLoop
                    }
                }
            }
        }

        return FeedFetchBatch(
            items: allItems,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount,
            notModifiedCount: notModifiedCount,
            throttledCount: throttledCount,
            gatedSourceCount: gatedSourceCount,
            sourceOutcomes: sourceOutcomes
        )
    }

    // MARK: - Audio extraction

    private struct AudioEnclosure {
        let url: String
        let duration: TimeInterval?
    }

    private func extractAudio(from item: RSSFeedItem, source: FeedSource) -> AudioEnclosure? {
        // Standard enclosure
        if let enc = item.enclosure?.attributes,
           let url = enc.url,
           Self.isAudioCandidate(url: url, type: enc.type, medium: nil),
           let resolved = resolvedAudioURL(url, source: source) {
            return AudioEnclosure(url: resolved, duration: nil)
        }

        // Media namespace
        let mediaContents = (item.media?.mediaContents ?? []) + (item.media?.mediaGroup?.mediaContents ?? [])
        if !mediaContents.isEmpty {
            for m in mediaContents {
                guard let attr = m.attributes, let url = attr.url else { continue }
                if Self.isAudioCandidate(url: url, type: attr.type, medium: attr.medium),
                   let resolved = resolvedAudioURL(url, source: source) {
                    let duration = attr.duration.map(TimeInterval.init)
                    return AudioEnclosure(url: resolved, duration: duration)
                }
            }
        }

        return nil
    }

    /// True if the URL path ends in a common audio file extension. Uses the URL
    /// path so query strings (e.g. "…/ep.mp3?token=…") don't defeat the match.
    private static func hasAudioFileExtension(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? url).lowercased()
        let exts = [".mp3", ".m4a", ".m4b", ".aac", ".ogg", ".oga", ".opus", ".wav", ".flac"]
        return exts.contains { path.hasSuffix($0) }
    }

    private static func isAudioCandidate(url: String, type: String?, medium: String?) -> Bool {
        let mediaType = type?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mediaMedium = medium?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if mediaMedium == "audio" || mediaType.hasPrefix("audio/") { return true }
        if mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/") || mediaType.hasPrefix("text/") {
            return false
        }
        return hasAudioFileExtension(url)
    }

    private func resolvedAudioURL(_ raw: String?, source: FeedSource) -> String? {
        FeedItem.resolvedMediaURL(from: raw, baseURL: source.url)?.absoluteString
    }

    private func extractAtomAudio(from entry: AtomFeedEntry, source: FeedSource) -> String? {
        guard let links = entry.links else { return nil }
        for link in links {
            guard let attr = link.attributes, let href = attr.href else { continue }
            let isEnclosure = attr.rel?.lowercased() == "enclosure"
            if Self.isAudioCandidate(url: href, type: attr.type, medium: nil) || (isEnclosure && Self.hasAudioFileExtension(href)) {
                return resolvedAudioURL(href, source: source)
            }
        }
        return nil
    }

    private func extractJSONAudio(from item: JSONFeedItem, source: FeedSource) -> AudioEnclosure? {
        guard let attachment = item.attachments?.first(where: {
            guard let url = $0.url else { return false }
            return Self.isAudioCandidate(url: url, type: $0.mimeType, medium: nil)
        }),
              let resolved = resolvedAudioURL(attachment.url, source: source) else {
            return nil
        }
        return AudioEnclosure(url: resolved, duration: attachment.durationInSeconds)
    }

    private func extractDuration(from item: RSSFeedItem) -> TimeInterval? {
        let dur = item.iTunes?.iTunesDuration ?? 0
        return dur > 0 ? dur : nil
    }

    // MARK: - Audio playability validation

    /// Probe the audio enclosures of freshly-parsed items and strip `audioURL`
    /// from any that don't actually serve playable audio, so unplayable
    /// "podcasts" never reach the feed. Bounded, cached, and only touches items
    /// that claim audio — text feeds pay nothing.
    private func validateAudio(in items: [FeedItem]) async -> [FeedItem] {
        // Cap probes per feed so a huge episode list can't stall a fetch; the
        // newest items matter most and appear first.
        let audioIndices = items.indices.filter { items[$0].audioURL != nil }
        guard !audioIndices.isEmpty else { return items }
        let toProbe = Array(audioIndices.prefix(12))

        var playable: [String: Bool] = [:]
        let cap = 6
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = toProbe.makeIterator()
            var started = 0
            while started < cap, let idx = iterator.next() {
                guard let audio = items[idx].audioURL else { continue }
                group.addTask { (audio, await self.isPlayableAudio(audio)) }
                started += 1
            }
            while let (audio, ok) = await group.next() {
                playable[audio] = ok
                if let idx = iterator.next(), let next = items[idx].audioURL {
                    group.addTask { (next, await self.isPlayableAudio(next)) }
                }
            }
        }

        guard !playable.isEmpty else { return items }
        var result = items
        for idx in toProbe {
            if let audio = result[idx].audioURL, playable[audio] == false {
                result[idx] = result[idx].withoutAudio()
            }
        }
        return result
    }

    private enum AudioProbe { case playable, notAudio, unknown }

    /// Whether `urlString` should be treated as playable audio. Only a
    /// *definitive* negative — a 2xx with a text/image body, or a gone status
    /// (404/410) — is cached as false and strips the item. Transient failures
    /// (timeouts, 5xx, rate limits) return true (keep) and are NOT cached, so a
    /// network blip can't permanently demote a good podcast.
    private func isPlayableAudio(_ urlString: String) async -> Bool {
        if let cached = audioPlayability[urlString] { return cached }
        guard let url = URL(string: urlString) else {
            audioPlayability[urlString] = false
            savePlayabilityCache()
            return false
        }
        switch await probeAudio(url) {
        case .playable:
            audioPlayability[urlString] = true
            trimPlayabilityCache()
            savePlayabilityCache()
            return true
        case .notAudio:
            audioPlayability[urlString] = false
            trimPlayabilityCache()
            savePlayabilityCache()
            return false
        case .unknown:
            return true   // couldn't confirm — keep it, retry on a later fetch
        }
    }

    private func trimPlayabilityCache() {
        guard audioPlayability.count > 500 else { return }
        // Drop arbitrary entries to keep cache bounded
        let keysToRemove = audioPlayability.keys.prefix(audioPlayability.count - 300)
        for key in keysToRemove { audioPlayability.removeValue(forKey: key) }
        savePlayabilityCache()
    }

    private func savePlayabilityCache() {
        UserDefaults.standard.set(audioPlayability, forKey: Self.playabilityCacheKey)
    }

    private func probeAudio(_ url: URL) async -> AudioProbe {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 6
        do {
            let (_, response) = try await probeSession.data(for: head)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            // Some servers reject HEAD — retry with a 1-byte ranged GET.
            if http.statusCode == 405 || http.statusCode == 501 {
                return await probeAudioRanged(url)
            }
            return classify(http)
        } catch {
            return await probeAudioRanged(url)
        }
    }

    private func probeAudioRanged(_ url: URL) async -> AudioProbe {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            // Use bytes(for:) to avoid downloading full episode bodies from
            // servers that ignore Range requests. Stream at most 64 KB and
            // classify based on headers alone — we don't need the body for audio probes.
            let (asyncBytes, response) = try await probeSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            // Drain body bytes (capped at 64 KB) to avoid leaking the connection.
            // asyncBytes iterates individual UInt8 values — count them to cap.
            var drained = 0
            for try await _ in asyncBytes.prefix(65_000) {
                drained += 1
                if drained > 64_000 { break }
            }
            return classify(http)
        } catch {
            return .unknown   // network error — can't determine, don't strip
        }
    }

    /// Classify a probe response. Lenient on content-type (many audio CDNs send
    /// octet-stream / video-mp4); only a 2xx with a text/image body or a gone
    /// status (404/410) is a definitive non-audio. Everything else
    /// (3xx/403/429/5xx) is transient/ambiguous → unknown (keep, don't cache).
    private func classify(_ http: HTTPURLResponse) -> AudioProbe {
        let code = http.statusCode
        if (200...299).contains(code) || code == 206 {
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.hasPrefix("text/") || type.hasPrefix("image/") { return .notAudio }
            return .playable
        }
        if code == 404 || code == 410 { return .notAudio }
        return .unknown
    }

    // MARK: - Feed-Level Metadata Extraction

    /// Extract feed-level metadata (TTL, skip hours/days, last build date, capabilities)
    /// from a parsed feed for persistence in HTTPValidators.
    private func extractFeedLevelMetadata(from feed: Feed, source: FeedSource) -> (
        ttl: Int?,
        skipHours: [Int]?,
        skipDays: [String]?,
        lastBuildDate: Date?,
        capabilities: SourceCapabilities?
    ) {
        switch feed {
        case .rss(let rss):
            let cloud = rss.cloud.map { cloud in
                SourceCapabilities.RSSCloudEndpoints(
                    domain: cloud.attributes?.domain ?? "",
                    port: cloud.attributes?.port ?? 0,
                    path: cloud.attributes?.path ?? "",
                    registerProcedure: cloud.attributes?.registerProcedure ?? "",
                    protocolVersion: cloud.attributes?.protocolSpecification ?? ""
                )
            }
            let websubFromRSS = discoverWebSubFromRSS(source: source)
            let caps = SourceCapabilities(
                websub: websubFromRSS,
                cloud: cloud,
                hasPagination: false
            )
            return (
                ttl: rss.ttl,
                skipHours: rss.skipHours,
                skipDays: rss.skipDays?.map(\.rawValue),
                lastBuildDate: rss.lastBuildDate,
                capabilities: caps
            )
        case .atom(let atom):
            let websub = atom.links?.first(where: { link in
                link.attributes?.rel?.lowercased() == "hub"
            }).map { hub in
                SourceCapabilities.WebSubEndpoints(
                    hub: hub.attributes?.href ?? "",
                    selfURL: atom.links?.first(where: {
                        $0.attributes?.rel?.lowercased() == "self"
                    })?.attributes?.href
                )
            }
            let hasPagination = atom.links?.contains(where: {
                let rel = $0.attributes?.rel?.lowercased() ?? ""
                return rel == "next" || rel == "previous" || rel == "first" || rel == "last"
            }) ?? false
            let caps = SourceCapabilities(websub: websub, hasPagination: hasPagination)
            return (
                ttl: nil,
                skipHours: nil,
                skipDays: nil,
                lastBuildDate: atom.updated,
                capabilities: caps
            )
        case .json(let json):
            let websub = json.hubs?.first(where: { $0.type?.lowercased() == "websub" }).map { hub in
                SourceCapabilities.WebSubEndpoints(hub: hub.url ?? "", selfURL: json.feedUrl)
            }
            return (
                ttl: nil,
                skipHours: nil,
                skipDays: nil,
                lastBuildDate: nil,
                capabilities: websub.map { SourceCapabilities(websub: $0, hasPagination: false) }
            )
        }
    }

    /// Discover WebSub endpoints from RSS feed's atom:link elements.
    /// FeedKit doesn't expose these natively, so we parse the raw XML.
    private func discoverWebSubFromRSS(source: FeedSource) -> SourceCapabilities.WebSubEndpoints? {
        // WebSub in RSS is declared via atom:link elements.
        // FeedKit 9.x may expose these via rssFeed.namespaces or similar.
        // For now, return nil — a follow-up can add regex-based extraction
        // from raw XML if FeedKit doesn't expose these links.
        // The Atom and JSON Feed paths are already covered.
        return nil
    }

    // MARK: - Item Metadata Extraction

    private func extractRSSAuthors(from item: RSSFeedItem) -> [FeedItemAuthor]? {
        var authors: [FeedItemAuthor] = []
        if let author = item.author, !author.isEmpty {
            // RSS author is often just a string — parse name if it looks like "Name <email>"
            if let emailStart = author.firstIndex(of: "<"),
               let emailEnd = author.firstIndex(of: ">"),
               emailStart < emailEnd {
                let name = String(author[..<emailStart]).trimmingCharacters(in: .whitespaces)
                let email = String(author[author.index(after: emailStart)..<emailEnd])
                authors.append(FeedItemAuthor(name: name.isEmpty ? nil : name, email: email, uri: nil))
            } else {
                authors.append(FeedItemAuthor(name: author, email: nil, uri: nil))
            }
        }
        if let itunesAuthor = item.iTunes?.iTunesAuthor, !itunesAuthor.isEmpty {
            // Avoid duplicates
            if !authors.contains(where: { $0.name == itunesAuthor }) {
                authors.append(FeedItemAuthor(name: itunesAuthor, email: nil, uri: nil))
            }
        }
        return authors.isEmpty ? nil : authors
    }

    private func extractRSSCategories(from item: RSSFeedItem) -> [FeedItemCategory]? {
        guard let cats = item.categories, !cats.isEmpty else { return nil }
        return cats.compactMap { cat in
            guard let value = cat.value, !value.isEmpty else { return nil }
            return FeedItemCategory(term: value, scheme: cat.attributes?.domain, label: nil)
        }
    }

    private func extractRSSAttribution(from item: RSSFeedItem) -> FeedItemAttribution? {
        guard let src = item.source?.value, !src.isEmpty else { return nil }
        return FeedItemAttribution(
            title: src,
            url: item.source?.attributes?.url,
            feedURL: nil
        )
    }

    private func extractRSSEnclosures(from item: RSSFeedItem, source: FeedSource) -> [FeedEnclosure]? {
        var enclosures: [FeedEnclosure] = []

        // Standard enclosure
        if let enc = item.enclosure?.attributes, let url = enc.url, !url.isEmpty {
            enclosures.append(FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: enc.type,
                length: enc.length.flatMap(Int64.init),
                duration: nil,
                medium: classifyMedium(mimeType: enc.type, url: url)
            ))
        }

        // Media RSS contents
        for media in (item.media?.mediaContents ?? []) {
            guard let attr = media.attributes, let url = attr.url, !url.isEmpty else { continue }
            enclosures.append(FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: attr.type,
                length: attr.fileSize.flatMap(Int64.init),
                duration: attr.duration.map(TimeInterval.init),
                medium: attr.medium ?? classifyMedium(mimeType: attr.type, url: url)
            ))
        }

        return enclosures.isEmpty ? nil : enclosures
    }

    private func extractAtomAuthors(from entry: AtomFeedEntry) -> [FeedItemAuthor]? {
        guard let authors = entry.authors, !authors.isEmpty else { return nil }
        return authors.map { author in
            FeedItemAuthor(name: author.name, email: author.email, uri: author.uri)
        }
    }

    private func extractAtomCategories(from entry: AtomFeedEntry) -> [FeedItemCategory]? {
        guard let cats = entry.categories, !cats.isEmpty else { return nil }
        return cats.compactMap { cat in
            guard let term = cat.attributes?.term, !term.isEmpty else { return nil }
            return FeedItemCategory(term: term, scheme: cat.attributes?.scheme, label: cat.attributes?.label)
        }
    }

    private func extractAtomAttribution(from entry: AtomFeedEntry) -> FeedItemAttribution? {
        guard let source = entry.source, let title = source.title, !title.isEmpty else { return nil }
        return FeedItemAttribution(title: title, url: nil, feedURL: nil)
    }

    private func extractAtomEnclosures(from entry: AtomFeedEntry, source: FeedSource) -> [FeedEnclosure]? {
        guard let links = entry.links, !links.isEmpty else { return nil }
        let enclosures = links.compactMap { link -> FeedEnclosure? in
            guard let href = link.attributes?.href, !href.isEmpty else { return nil }
            return FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: href, baseURL: source.url)?.absoluteString ?? href,
                mimeType: link.attributes?.type,
                length: link.attributes?.length.flatMap(Int64.init),
                duration: nil,
                medium: classifyMedium(mimeType: link.attributes?.type, url: href)
            )
        }
        return enclosures.isEmpty ? nil : enclosures
    }

    private func extractAtomAlternateLinks(from entry: AtomFeedEntry, source: FeedSource) -> [FeedAlternateLink]? {
        guard let links = entry.links, !links.isEmpty else { return nil }
        let alternates = links.compactMap { link -> FeedAlternateLink? in
            guard let href = link.attributes?.href, !href.isEmpty else { return nil }
            let resolved = FeedItem.resolvedMediaURL(from: href, baseURL: source.url)?.absoluteString ?? href
            return FeedAlternateLink(
                url: resolved,
                mimeType: link.attributes?.type,
                language: link.attributes?.hreflang,
                rel: link.attributes?.rel
            )
        }
        return alternates.isEmpty ? nil : alternates
    }

    private func extractJSONAuthors(from jsonItem: JSONFeedItem) -> [FeedItemAuthor]? {
        guard let author = jsonItem.author else { return nil }
        return [FeedItemAuthor(name: author.name, email: nil, uri: author.url)]
    }

    private func extractJSONCategories(from jsonItem: JSONFeedItem) -> [FeedItemCategory]? {
        guard let tags = jsonItem.tags, !tags.isEmpty else { return nil }
        return tags.map { FeedItemCategory(term: $0, scheme: nil, label: nil) }
    }

    private func extractJSONEnclosures(from jsonItem: JSONFeedItem, source: FeedSource) -> [FeedEnclosure]? {
        guard let attachments = jsonItem.attachments, !attachments.isEmpty else { return nil }
        let enclosures = attachments.compactMap { att -> FeedEnclosure? in
            guard let url = att.url, !url.isEmpty else { return nil }
            return FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: att.mimeType,
                length: att.sizeInBytes.flatMap(Int64.init),
                duration: att.durationInSeconds,
                medium: classifyMedium(mimeType: att.mimeType, url: url)
            )
        }
        return enclosures.isEmpty ? nil : enclosures
    }

    /// Classify an enclosure as audio/video/image based on MIME type and URL extension.
    private func classifyMedium(mimeType: String?, url: String) -> String? {
        let type = mimeType?.lowercased() ?? ""
        if type.hasPrefix("audio/") { return "audio" }
        if type.hasPrefix("video/") { return "video" }
        if type.hasPrefix("image/") { return "image" }
        let path = (URL(string: url)?.path ?? url).lowercased()
        let audioExts = ["mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "flac"]
        let videoExts = ["mp4", "mov", "webm", "avi", "mkv"]
        let imageExts = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"]
        if audioExts.contains(where: path.hasSuffix) { return "audio" }
        if videoExts.contains(where: path.hasSuffix) { return "video" }
        if imageExts.contains(where: path.hasSuffix) { return "image" }
        return nil
    }

    // MARK: - Private

    func extractItems(fromFeedData data: Data, source: FeedSource) -> [FeedItem] {
        guard case .success(let feed) = FeedParser(data: data).parse() else { return [] }
        return extractItems(from: feed, source: source)
    }

    private func extractItems(from feed: Feed, source: FeedSource) -> [FeedItem] {
        // Channel-level image fallback for podcasts (many RSS feeds have
        // artwork at the channel level but not per-episode).
        let feedImage: String? = {
            // Aggregator channel artwork identifies the transport, not the
            // article. Reusing the Google News logo on every card makes many
            // publishers look like one repeated feed.
            if URL(string: source.url)?.host?.lowercased() == "news.google.com" {
                return nil
            }
            let image: String? = {
                switch feed {
                case .atom(let a): return a.logo ?? a.icon
                case .rss(let r):  return r.iTunes?.iTunesImage?.attributes?.href ?? r.image?.url
                case .json(let j): return j.icon ?? j.favicon
                }
            }()
            // Skip obvious favicons and tiny site logos — they block article
            // image resolution. A missing image triggers ArticleImageResolver
            // which finds the actual article artwork.
            if let image, Self.isLikelyFaviconOrLogo(image) { return nil }
            return image
        }()

        let entries: [FeedItem] = {
            switch feed {
            case .atom(let atomFeed):
                let atomEntries = (atomFeed.entries as? [AtomFeedEntry]) ?? []
                return atomEntries.compactMap { entry in
                    let rawContent = entry.content?.value ?? entry.summary?.value ?? ""
                    let audio = extractAtomAudio(from: entry, source: source)
                    let entryLink = entry.links?.first(where: { link in
                        let rel = link.attributes?.rel?.lowercased()
                        let type = link.attributes?.type?.lowercased() ?? ""
                        return (rel == nil || rel == "alternate")
                            && !type.contains("atom")
                            && !type.contains("rss")
                    })?.attributes?.href
                        ?? entry.links?.first(where: {
                            $0.attributes?.rel?.lowercased() != "enclosure"
                        })?.attributes?.href
                    let img = bestMediaImageURL(from: entry.media)
                        ?? extractFirstImageFromHTML(rawContent)
                        ?? feedImage
                    let metadata = ParsedItemMetadata(
                        authors: extractAtomAuthors(from: entry),
                        categories: extractAtomCategories(from: entry),
                        rights: entry.rights,
                        attribution: extractAtomAttribution(from: entry),
                        enclosures: extractAtomEnclosures(from: entry, source: source),
                        language: nil,
                        alternateLinks: extractAtomAlternateLinks(from: entry, source: source),
                        publishedAt: entry.published,
                        updatedAt: entry.updated
                    )
                    return makeItem(
                        guid: entry.id,
                        link: entryLink ?? entry.id,
                        title: entry.title,
                        source: source,
                        rawDescription: entry.summary?.value ?? entry.content?.value,
                        rawContent: entry.content?.value,
                        imageURL: img,
                        audioURL: audio,
                        metadata: metadata
                    )
                }
            case .rss(let rssFeed):
                let rssItems = (rssFeed.items as? [RSSFeedItem]) ?? []
                return rssItems.compactMap { item in
                    let audio = extractAudio(from: item, source: source)
                    let duration = extractDuration(from: item) ?? audio?.duration
                    let img = extractImageURL(from: item) ?? feedImage
                    let metadata = ParsedItemMetadata(
                        authors: extractRSSAuthors(from: item),
                        categories: extractRSSCategories(from: item),
                        rights: nil,
                        attribution: extractRSSAttribution(from: item),
                        enclosures: extractRSSEnclosures(from: item, source: source),
                        language: rssFeed.language,
                        alternateLinks: nil,
                        publishedAt: item.pubDate,
                        updatedAt: nil
                    )
                    return makeItem(
                        guid: item.guid?.value,
                        link: item.link,
                        title: item.title,
                        source: source,
                        itemSourceTitle: item.source?.value,
                        rawDescription: item.description,
                        rawContent: item.content?.contentEncoded,
                        imageURL: img,
                        audioURL: audio?.url,
                        duration: duration,
                        metadata: metadata
                    )
                }
            case .json(let jsonFeed):
                let jsonItems = (jsonFeed.items as? [JSONFeedItem]) ?? []
                return jsonItems.compactMap { jsonItem in
                    let audio = extractJSONAudio(from: jsonItem, source: source)
                    // Check attachments for image types (e.g., "image/jpeg")
                    let attachmentImage = jsonItem.attachments?.first { attachment in
                        Self.isSupportedRasterMIMEType(attachment.mimeType)
                    }?.url
                    let img = jsonItem.image ?? jsonItem.bannerImage ?? attachmentImage ?? feedImage
                    let metadata = ParsedItemMetadata(
                        authors: extractJSONAuthors(from: jsonItem),
                        categories: extractJSONCategories(from: jsonItem),
                        rights: nil,
                        attribution: nil,
                        enclosures: extractJSONEnclosures(from: jsonItem, source: source),
                        language: nil, // JSON Feed language not exposed by FeedKit 9.x
                        alternateLinks: nil,
                        publishedAt: jsonItem.datePublished,
                        updatedAt: jsonItem.dateModified
                    )
                    return makeItem(
                        guid: jsonItem.id,
                        link: jsonItem.url,
                        title: jsonItem.title,
                        source: source,
                        rawDescription: jsonItem.summary ?? jsonItem.contentText,
                        rawContent: jsonItem.contentHtml,
                        imageURL: img,
                        audioURL: audio?.url,
                        duration: audio?.duration,
                        metadata: metadata
                    )
                }
            }
        }()

        return entries
    }

    private func makeItem(
        guid: String?,
        link: String?,
        title: String?,
        source: FeedSource,
        itemSourceTitle: String? = nil,
        rawDescription: String?,
        rawContent: String?,
        imageURL: String?,
        audioURL: String? = nil,
        duration: TimeInterval? = nil,
        metadata: ParsedItemMetadata = ParsedItemMetadata()
    ) -> FeedItem? {
        let resolvedLink = [link, audioURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        // Text items need a clickable URL. Podcast items can use their
        // enclosure URL, because tapping them starts playback instead.
        guard let resolvedLink else { return nil }

        // A visible card without a real headline is worse than skipping an
        // incomplete feed item. Some malformed feeds encode CDATA as text;
        // sanitizedHTMLText unwraps that form before this check.
        let sanitizedTitle = Self.sanitizedHTMLText(title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedTitle.isEmpty else { return nil }
        let truncatedTitle = String(sanitizedTitle.prefix(200))

        let itemPubDate = metadata.publishedAt ?? metadata.updatedAt

        let id = FeedItem.generateID(
            sourceURL: source.url,
            guid: guid,
            link: link,
            title: sanitizedTitle,
            publishedAt: itemPubDate
        )

        let excerpt = extractExcerpt(
            description: rawDescription,
            content: rawContent
        )

        // PR-12 hook (level 2): the parsed entry still holds the GUID/Atom id here, and the
        // `FeedItem` built below keeps only a hash of it (`Models/FeedItem.swift:394-402`). The
        // shadow gets the wire identity verbatim, plus the legacy alias, so the two mirror levels
        // refer to one item without either re-deriving an identity.
        mirrorSink?.mirrorParsedEntry(ShadowParsedEntry(
            legacyItemID: id,
            sourceURL: source.url,
            guid: guid,
            link: resolvedLink,
            title: truncatedTitle,
            publishedAt: itemPubDate,
            updatedAt: metadata.updatedAt,
            excerpt: excerpt,
            audioURL: audioURL
        ))

        // Resolve relative image URLs against the article URL
        let resolvedImageURL = resolveImageURL(imageURL, baseURL: link ?? source.url)

        // Sanitize: truncate long titles, strip HTML, cap source names
        let isGoogleNews = URL(string: source.url)?.host?.lowercased() == "news.google.com"
        let preferredSourceTitle: String? = if isGoogleNews {
            if let publisher = itemSourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !publisher.isEmpty {
                publisher
            } else {
                "Google News"
            }
        } else {
            nil
        }
        let sanitizedSource = String(
            Self.sanitizedHTMLText(
                preferredSourceTitle?.isEmpty == false ? preferredSourceTitle! : source.title
            ).prefix(80)
        )

        return FeedItem(
            id: id,
            sourceTitle: sanitizedSource,
            sourceURL: source.url,
            category: source.category,
            title: truncatedTitle,
            excerpt: excerpt,
            url: resolvedLink,
            imageURL: resolvedImageURL,
            publishedAt: itemPubDate ?? Date(),
            audioURL: audioURL,
            duration: duration,
            region: source.region,
            language: metadata.language,
            updatedAt: metadata.updatedAt,
            authors: metadata.authors,
            itemCategories: metadata.categories,
            rights: metadata.rights,
            attribution: metadata.attribution,
            enclosures: metadata.enclosures,
            languageFromFeed: metadata.language,
            alternateLinks: metadata.alternateLinks
        )
    }

    /// Pick the best image URL from a Media RSS namespace — largest width
    /// wins; "image/*" type preferred over "thumbnail/*" when sizes match.
    /// Checks both item-level and ``MediaGroup`` children so that feeds
    /// wrapping their media in ``<media:group>`` (e.g. YouTube) are covered.
    private func bestMediaImageURL(from media: MediaNamespace?) -> String? {
        guard let media else { return nil }

        // Collect media:content from both the item and its optional media:group.
        // FeedKit maps <media:group/media:content> into media.mediaGroup.mediaContents
        // but <media:group/media:thumbnail> is NOT mapped (MediaGroup lacks the
        // property), so we also check group-level media:content for image/* types.
        let allContents = (media.mediaContents ?? []) + (media.mediaGroup?.mediaContents ?? [])

        // media:content may represent audio, video, documents, or browser
        // players. Only direct raster images are valid card artwork.
        let imageContents = allContents.filter { content in
            guard let attributes = content.attributes else { return false }
            if attributes.medium?.lowercased() == "image" {
                return !Self.isUnsupportedImageURL(attributes.url)
            }
            if Self.isSupportedRasterMIMEType(attributes.type) {
                return !Self.isUnsupportedImageURL(attributes.url)
            }
            guard attributes.medium == nil, attributes.type == nil else { return false }
            return Self.hasRasterImageExtension(attributes.url)
        }
        if !imageContents.isEmpty {
            let best = imageContents.max { a, b in
                let aW = a.attributes?.width.flatMap(Int.init) ?? 0
                let bW = b.attributes?.width.flatMap(Int.init) ?? 0
                return aW < bW
            }
            if let url = best?.attributes?.url { return url }
        }

        // 2. media:thumbnails — pick largest by width (item-level only;
        //    MediaGroup has no mediaThumbnails property in FeedKit 9.x).
        if let thumbs = media.mediaThumbnails, !thumbs.isEmpty {
            let best = thumbs.max { a, b in
                let aW = a.attributes?.width.flatMap(Int.init) ?? 0
                let bW = b.attributes?.width.flatMap(Int.init) ?? 0
                return aW < bW
            }
            if let url = best?.attributes?.url { return url }
        }

        return nil
    }

    /// Extract image URL from RSS item, picking the best available image.
    private func extractImageURL(from item: RSSFeedItem) -> String? {
        // 1. media:content / media:thumbnail (Media RSS namespace)
        if let url = bestMediaImageURL(from: item.media) { return url }

        // 2. Episode artwork used by most podcast publishers.
        if let url = item.iTunes?.iTunesImage?.attributes?.href { return url }

        // 3. enclosure with a supported raster image type
        if let enclosure = item.enclosure,
           let type = enclosure.attributes?.type,
           Self.isSupportedRasterMIMEType(type),
           let url = enclosure.attributes?.url {
            return url
        }

        // 4. First <img> in content
        if let content = item.content?.contentEncoded ?? item.description {
            return extractFirstImageFromHTML(content)
        }

        return nil
    }

    /// Resolve a possibly-relative image URL against the article's base URL.
    private func resolveImageURL(_ imageURL: String?, baseURL: String?) -> String? {
        guard let original = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty else { return nil }
        let raw = original
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#038;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
        // Reject tracking pixels and spacer GIFs at the source so they never
        // enter the database or pollute the What's New carousel.
        let lower = raw.lowercased()
        if lower.contains("tracking") && lower.contains("pixel") { return nil }
        if lower.contains("/tracker/") || lower.contains("count.gif") || lower.contains("track-rss-story") { return nil }
        if lower.contains("spacer") && (lower.hasSuffix(".gif") || lower.hasSuffix(".png")) { return nil }
        if lower.hasSuffix("1x1.gif") || lower.hasSuffix("1x1.png") { return nil }
        if Self.isUnsupportedImageURL(raw) { return nil }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            let schemeLen = lower.hasPrefix("https://") ? 8 : 7
            let tail = lower.dropFirst(schemeLen)
            let nestedSchemes = ["http://", "https://"].compactMap { tail.range(of: $0) }
            if let firstNested = nestedSchemes.min(by: { $0.lowerBound < $1.lowerBound }) {
                let prefix = tail[..<firstNested.lowerBound]
                // URL proxies commonly use /https://... or ?url=https://...
                // A bare image.jpghttps://... sequence is malformed.
                if prefix.last != "/" && prefix.last != "=" { return nil }
            }
        }
        // Already absolute — upgrade HTTP to HTTPS so images don't fail
        // under ATS (NSAllowsArbitraryLoadsForMedia only covers AV media).
        if raw.hasPrefix("http://") {
            let upgraded = "https://" + raw.dropFirst("http://".count)
            return Self.validHTTPImageURL(String(upgraded))
        }
        if raw.hasPrefix("https://") { return Self.validHTTPImageURL(raw) }
        // Data URIs are accepted only for raster formats supported by ImageIO.
        if lower.hasPrefix("data:image/") { return raw }
        if lower.hasPrefix("data:") { return nil }
        // Protocol-relative URL
        if raw.hasPrefix("//") { return Self.validHTTPImageURL("https:\(raw)") }
        // Relative URL — resolve against base
        guard let base = baseURL, let baseURL = URL(string: base) else { return nil }
        guard let resolved = URL(string: raw, relativeTo: baseURL) else { return nil }
        return Self.validHTTPImageURL(resolved.absoluteString)
    }

    private static func isSupportedRasterMIMEType(_ value: String?) -> Bool {
        guard let type = value?.lowercased(), type.hasPrefix("image/") else { return false }
        return !type.contains("svg")
    }

    private static func hasRasterImageExtension(_ value: String?) -> Bool {
        guard let value, let components = URLComponents(string: value) else { return false }
        let extensions = Set(["jpg", "jpeg", "jfif", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff"])
        return extensions.contains((components.path as NSString).pathExtension.lowercased())
    }

    private static func isUnsupportedImageURL(_ value: String?) -> Bool {
        guard let value else { return true }
        let lower = value.lowercased()
        if lower.hasPrefix("data:image/svg") { return true }
        if lower.contains("youtube.com/embed/") { return true }
        guard let components = URLComponents(string: value) else { return true }
        let ext = (components.path as NSString).pathExtension.lowercased()
        return ["svg", "mp3", "m4a", "aac", "wav", "ogg", "opus", "mp4", "mov", "webm"].contains(ext)
    }

    private static func validHTTPImageURL(_ value: String) -> String? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              !isUnsupportedImageURL(value) else { return nil }
        return url.absoluteString
    }

    /// Extract the first plausible content image from an HTML fragment. Feed
    /// bodies often begin with a favicon, avatar, sharing button, or tracking
    /// image; when an img has srcset, use its largest declared variant.
    private func extractFirstImageFromHTML(_ html: String) -> String? {
        // Quick pre-check — skip if no img tag present
        guard html.contains("<img") || html.contains("&lt;img") else { return nil }

        let decoded = html
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        for candidate in [decoded, html] {
            let fullRange = NSRange(candidate.startIndex..., in: candidate)
            for match in Self.imgTagRegex.matches(in: candidate, range: fullRange) {
                guard let tagRange = Range(match.range, in: candidate) else { continue }
                let tag = String(candidate[tagRange])
                let attributes = Self.imageAttributeRegex.matches(
                    in: tag,
                    range: NSRange(tag.startIndex..., in: tag)
                ).compactMap { attribute -> (name: String, value: String)? in
                    guard let nameRange = Range(attribute.range(at: 1), in: tag),
                          let valueRange = Range(attribute.range(at: 2), in: tag) else { return nil }
                    return (String(tag[nameRange]).lowercased(), String(tag[valueRange]))
                }

                let valueForFirstAttribute: ([String]) -> String? = { names in
                    names.lazy.compactMap { name in
                        attributes.first(where: { $0.name == name })?.value
                    }.first
                }
                let srcset = valueForFirstAttribute(["data-lazy-srcset", "data-srcset", "srcset"])
                let src = valueForFirstAttribute([
                    "data-lazy-src", "data-original", "data-orig-file", "data-src", "src",
                ])
                let imageURL = Self.preferredSrcsetCandidate(srcset) ?? src
                guard let imageURL, !Self.isLikelyDecorativeImageURL(imageURL) else { continue }
                return Self.upgradedKnownThumbnailURL(imageURL)
            }
        }
        return nil
    }

    private static func preferredSrcsetCandidate(_ srcset: String?) -> String? {
        guard let srcset else { return nil }
        let candidates = srcset.split(separator: ",")
            .compactMap { entry -> (url: String, value: Double, unit: Character)? in
                let parts = entry.split(whereSeparator: \Character.isWhitespace)
                guard let first = parts.first else { return nil }
                let descriptor = parts.dropFirst().last.map(String.init) ?? ""
                guard let unit = descriptor.last,
                      unit == "w" || unit == "x",
                      let number = Double(descriptor.dropLast()) else { return nil }
                return (String(first), number, unit)
            }
        let widthCandidates = candidates.filter { $0.unit == "w" }.sorted { $0.value < $1.value }
        if let sufficient = widthCandidates.first(where: { $0.value >= 960 }) { return sufficient.url }
        if let largest = widthCandidates.last { return largest.url }
        let densityCandidates = candidates.filter { $0.unit == "x" }.sorted { $0.value < $1.value }
        if let retina = densityCandidates.first(where: { $0.value >= 2 }) { return retina.url }
        return densityCandidates.last?.url
    }

    private static func isLikelyDecorativeImageURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        let markers = [
            "favicon", "gravatar.com/avatar", "/emoji/", "s.w.org/images/core/emoji",
            "addtoany.com/buttons", "share_save", "icon_facebook", "tracking",
            "spacer", "pixel.gif", "count.gif",
        ]
        if markers.contains(where: lower.contains) { return true }
        return lower.range(of: #"(?:^|[-_/])(16|18|24|32)x(?:11|12|16|18|24|29|30|31|32)(?:[-_.?/]|$)"#,
                           options: .regularExpression) != nil
    }

    /// Rejects channel-level images that are obviously favicons or tiny logos.
    /// Using these as article images blocks ArticleImageResolver from finding
    /// the actual article artwork.
    private static func isLikelyFaviconOrLogo(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("favicon") || lower.contains("cropped") { return true }
        // Match tiny favicon dimensions (-32x32, -150x150) but not large
        // artwork (-1400x1400, -3000x3000). Threshold: ≤150px on either side.
        if let range = lower.range(of: #"[-.](\d{2,4})x(\d{2,4})"#, options: .regularExpression) {
            let match = String(lower[range]).dropFirst()  // strip leading - or .
            let parts = match.split(separator: "x").compactMap { Int($0) }
            if let w = parts.first, let h = parts.last, w <= 150 && h <= 150 {
                return true
            }
        }
        // Site logos used as channel images (not article artwork)
        if lower.contains("/logo") || lower.contains("-logo") || lower.contains("_logo") {
            return true
        }
        return false
    }

    private static func upgradedKnownThumbnailURL(_ value: String) -> String {
        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              host.contains("blogger.googleusercontent.com") || host.hasSuffix(".blogspot.com") else {
            return value
        }
        return value.replacingOccurrences(
            of: #"/s(?:72|144|320)(?:-w\d+-h\d+)?(?:-[a-z]+)?/"#,
            with: "/s1200/",
            options: .regularExpression
        )
    }

    /// Extract excerpt from available fields in priority order.
    private func extractExcerpt(description: String?, content: String?) -> String {
        // The same rule every runtime path now uses (`FeedTextSanitizer.displayExcerpt`), so the legacy
        // and the runtime feed strip markup the same way instead of each keeping its own copy of it.
        let excerpt = FeedTextSanitizer.displayExcerpt(description ?? content ?? "")
        return excerpt.isEmpty ? "No description" : excerpt
    }

    private static let imgTagRegex = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
    private static let imageAttributeRegex = try! NSRegularExpression(
        pattern: #"\s(data-lazy-srcset|data-srcset|srcset|data-lazy-src|data-original|data-orig-file|data-src|src)\s*=\s*["']([^"']+)["']"#,
        options: .caseInsensitive
    )

    /// Convert feed HTML/XML fragments into display text without pulling in
    /// NSAttributedString's HTML parser for every item.
    nonisolated static func sanitizedHTMLText(_ html: String) -> String {
        FeedTextSanitizer.sanitizedHTMLText(html)
    }
}

enum FeedTextSanitizer {
    private static let htmlTagRegex = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let htmlEntityRegex = try! NSRegularExpression(
        pattern: #"&#(?:x[0-9A-Fa-f]+|[0-9]+);?|&[A-Za-z][A-Za-z0-9]{1,31};"#
    )

    /// Convert feed HTML/XML fragments into display text without pulling in
    /// NSAttributedString's HTML parser for every item.
    static func sanitizedHTMLText(_ html: String) -> String {
        let decodedMarkup = unwrapCDATA(in: decodeHTMLEntities(in: html))
        let range = NSRange(decodedMarkup.startIndex..., in: decodedMarkup)
        let stripped = htmlTagRegex.stringByReplacingMatches(in: decodedMarkup, range: range, withTemplate: " ")
        return decodeHTMLEntities(in: stripped)
    }

    private static let whitespaceRunRegex = try! NSRegularExpression(pattern: #"\s+"#)

    /// The text a card shows for a payload's primary text — the one owner of "canonical text becomes
    /// display text".
    ///
    /// The frozen payload keeps what the publisher published: `PublishedCardPayload.primaryText` carries
    /// the publisher's HTML by design, because an immutable payload is what publication protects. The
    /// stripping therefore belongs on the display side, and every runtime path that shows that text has
    /// to come through here — the session card the presentation pipeline materializes, the bookmark
    /// snapshot the user-state projection writes into `feedmine.sqlite`, and a canonical search row.
    /// Until this existed, the legacy ingestion stripped markup (`extractExcerpt`) while every runtime
    /// path forwarded it, so the same feed showed `<p>…` in `v2Full` and clean text in `legacy`.
    /// Measured on screen on 2026-09-18 (`docs/runtime-v2/contract-matrix.md`'s screenshot note).
    ///
    /// Whitespace is collapsed and the result is cut to `limit` characters at a word boundary, which is
    /// what `extractExcerpt` has always done for the legacy path.
    static func displayExcerpt(_ raw: String, limit: Int = 200) -> String {
        let sanitized = sanitizedHTMLText(raw)
        let range = NSRange(sanitized.startIndex..., in: sanitized)
        let collapsed = whitespaceRunRegex
            .stringByReplacingMatches(in: sanitized, range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let capped = String(collapsed.prefix(limit))
        guard let lastSpace = capped.lastIndex(of: " "), lastSpace > capped.startIndex else { return capped }
        return String(capped[..<lastSpace]).trimmingCharacters(in: .whitespaces)
    }

    /// A few publishers write an escaped CDATA wrapper inside an XML element
    /// (`&lt;![CDATA[headline]]&gt;`). Once entities are decoded it looks like a
    /// tag, so the normal HTML stripper would erase the headline entirely.
    private static func unwrapCDATA(in input: String) -> String {
        var text = input
        while let start = text.range(of: "<![CDATA["),
              let end = text.range(of: "]]>", range: start.upperBound..<text.endIndex) {
            text.replaceSubrange(start.lowerBound..<end.upperBound, with: text[start.upperBound..<end.lowerBound])
        }
        return text
    }

    private static func decodeHTMLEntities(in text: String) -> String {
        guard text.contains("&") else { return text }

        let matches = htmlEntityRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var decoded = ""
        decoded.reserveCapacity(text.count)
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            decoded.append(contentsOf: text[cursor..<range.lowerBound])
            let token = String(text[range])
            decoded.append(decodedHTMLEntity(token) ?? token)
            cursor = range.upperBound
        }

        decoded.append(contentsOf: text[cursor...])
        return decoded
    }

    private static func decodedHTMLEntity(_ token: String) -> String? {
        guard token.hasPrefix("&") else { return nil }
        var body = String(token.dropFirst())
        if body.hasSuffix(";") {
            body.removeLast()
        }

        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            let hex = String(body.dropFirst(2))
            guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else { return nil }
            return scalar.value == 160 ? " " : String(scalar)
        }

        if body.hasPrefix("#") {
            let decimal = String(body.dropFirst())
            guard let value = UInt32(decimal, radix: 10), let scalar = UnicodeScalar(value) else { return nil }
            return scalar.value == 160 ? " " : String(scalar)
        }

        // Exact match first (case-sensitive — e.g. "Agrave" vs "agrave").
        if let exact = namedHTMLEntities[body] { return exact }
        // Fall back to case-insensitive for the common case.
        return namedHTMLEntities[body.lowercased()]
    }

    private static let namedHTMLEntities: [String: String] = [
        "amp": "&",
        "apos": "'",
        "bdquo": "\"",
        "bull": "*",
        "copy": "(c)",
        "euro": "EUR",
        "gt": ">",
        "hellip": "...",
        "laquo": "<<",
        "ldquo": "\"",
        "lsquo": "'",
        "lt": "<",
        "mdash": "-",
        "middot": "*",
        "nbsp": " ",
        "ndash": "-",
        "pound": "GBP",
        "quot": "\"",
        "raquo": ">>",
        "rdquo": "\"",
        "reg": "(r)",
        "rsquo": "'",
        "sbquo": "'",
        "trade": "TM",
        // Latin-1 accented characters
        "aacute": "\u{00E1}", "Aacute": "\u{00C1}",
        "acirc": "\u{00E2}", "Acirc": "\u{00C2}",
        "aelig": "\u{00E6}", "AElig": "\u{00C6}",
        "agrave": "\u{00E0}", "Agrave": "\u{00C0}",
        "aring": "\u{00E5}", "Aring": "\u{00C5}",
        "atilde": "\u{00E3}", "Atilde": "\u{00C3}",
        "auml": "\u{00E4}", "Auml": "\u{00C4}",
        "ccedil": "\u{00E7}", "Ccedil": "\u{00C7}",
        "eacute": "\u{00E9}", "Eacute": "\u{00C9}",
        "ecirc": "\u{00EA}", "Ecirc": "\u{00CA}",
        "egrave": "\u{00E8}", "Egrave": "\u{00C8}",
        "eth": "\u{00F0}", "ETH": "\u{00D0}",
        "euml": "\u{00EB}", "Euml": "\u{00CB}",
        "iacute": "\u{00ED}", "Iacute": "\u{00CD}",
        "icirc": "\u{00EE}", "Icirc": "\u{00CE}",
        "igrave": "\u{00EC}", "Igrave": "\u{00CC}",
        "iuml": "\u{00EF}", "Iuml": "\u{00CF}",
        "ntilde": "\u{00F1}", "Ntilde": "\u{00D1}",
        "oacute": "\u{00F3}", "Oacute": "\u{00D3}",
        "ocirc": "\u{00F4}", "Ocirc": "\u{00D4}",
        "ograve": "\u{00F2}", "Ograve": "\u{00D2}",
        "oslash": "\u{00F8}", "Oslash": "\u{00D8}",
        "otilde": "\u{00F5}", "Otilde": "\u{00D5}",
        "ouml": "\u{00F6}", "Ouml": "\u{00D6}",
        "szlig": "\u{00DF}",
        "thorn": "\u{00FE}", "THORN": "\u{00DE}",
        "uacute": "\u{00FA}", "Uacute": "\u{00DA}",
        "ucirc": "\u{00FB}", "Ucirc": "\u{00DB}",
        "ugrave": "\u{00F9}", "Ugrave": "\u{00D9}",
        "uuml": "\u{00FC}", "Uuml": "\u{00DC}",
        "yacute": "\u{00FD}", "Yacute": "\u{00DD}",
        "yuml": "\u{00FF}",
        // Inverted punctuation
        "iexcl": "\u{00A1}", "iquest": "\u{00BF}",
        // Miscellaneous
        "ordf": "\u{00AA}", "ordm": "\u{00BA}",
        "times": "\u{00D7}", "divide": "\u{00F7}",
        "plusmn": "\u{00B1}", "sup1": "\u{00B9}",
        "sup2": "\u{00B2}", "sup3": "\u{00B3}",
        "frac14": "\u{00BC}", "frac12": "\u{00BD}",
        "frac34": "\u{00BE}", "micro": "\u{00B5}",
        "para": "\u{00B6}", "sect": "\u{00A7}",
        "not": "\u{00AC}", "macr": "\u{00AF}",
        "cedil": "\u{00B8}", "acute": "\u{00B4}",
        "circ": "\u{02C6}", "tilde": "\u{02DC}",
        "uml": "\u{00A8}", "brvbar": "\u{00A6}",
        "cent": "\u{00A2}", "curren": "\u{00A4}",
        "yen": "\u{00A5}", "shy": "\u{00AD}",
    ]
}
