import Foundation

/// Scheduler that learns publication cadence and uses HTTP validators
/// to decide when and how to fetch each source.
@MainActor
final class AdaptiveScheduler {
    private(set) var lastFetchedAt: [String: Date] = [:]
    private(set) var consecutiveFailures: [String: Int] = [:]
    private var validators: [String: HTTPValidators] = [:]
    private var estimators: [String: CadenceEstimator] = [:]
    private var consumptionTimestamps: [Date] = []

    // MARK: - Public API

    func nextBatch(
        reservoir: [FeedItem],
        sourcesByRegion: [String: [FeedSource]],
        activeRegion: String?,
        activeCategory: String?,
        activeContentType: String? = nil,
        prioritySourceURLs: Set<String> = [],
        activeLanguages: Set<String> = [],
        minimumBatchSize: Int = 10,
        presetMultipliers: [String: Double] = [:]
    ) -> [FeedSource] {
        // 1. Determine scope
        let regions = activeRegion.map { [$0] } ?? Array(sourcesByRegion.keys)
        guard !regions.isEmpty else { return [] }

        // 2. Measure consumption (preserved from SourceScheduler)
        let bufferNeeded = estimatedBufferNeeded()
        let currentBuffer: Int
        if let ct = activeContentType {
            let matchingItems = reservoir.filter { item in
                switch ct {
                case "video": return item.isYouTube
                case "audio": return item.isPodcast
                case "text": return !item.isYouTube && !item.isPodcast
                default: return true
                }
            }
            currentBuffer = matchingItems.count
            let sourceBreadth = Set(matchingItems.map(\.sourceURL)).count
            guard currentBuffer < bufferNeeded
                || sourceBreadth < FeedStore.immediateFilteredSourceTarget else { return [] }
        } else {
            let textCount = reservoir.filter { !$0.isYouTube && !$0.isPodcast }.count
            let videoCount = reservoir.filter { $0.isYouTube }.count
            let audioCount = reservoir.filter { $0.isPodcast }.count
            let textTarget = max(bufferNeeded, 300)
            let videoTarget = max(bufferNeeded / 2, 50)
            let audioTarget = max(bufferNeeded / 2, 50)
            let textDeficit = max(textTarget - textCount, 0)
            let videoDeficit = max(videoTarget - videoCount, 0)
            let audioDeficit = max(audioTarget - audioCount, 0)
            let totalDeficit = textDeficit + videoDeficit + audioDeficit
            guard totalDeficit > 0 else { return [] }
            currentBuffer = bufferNeeded - Int(ceil(Double(totalDeficit) / 3.0))
        }

        // 3. Measure entropy (preserved)
        let urlToRegion: [String: String] = sourcesByRegion.flatMap { region, srcs in
            srcs.map { ($0.url, region) }
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }

        let regionDistribution = distribution(of: reservoir, key: { urlToRegion[$0.sourceURL] ?? "unknown" })
        let categoryDistribution = distribution(of: reservoir, key: \.category)
        let regionWeights = sqrtWeights(for: sourcesByRegion)
        let allCategories = Set(sourcesByRegion.values.flatMap { $0 }.map(\.category))
        let idealRegionDist = normalize(regionWeights)
        let idealCategoryDist = normalize(Dictionary(uniqueKeysWithValues: allCategories.map { ($0, 1.0) }))
        let regionDeficits = deficits(ideal: idealRegionDist, actual: regionDistribution)
        let categoryDeficits = deficits(ideal: idealCategoryDist, actual: categoryDistribution)
        var finalCategoryDeficits = categoryDeficits
        if let cat = activeCategory {
            finalCategoryDeficits[cat] = max(finalCategoryDeficits[cat] ?? 0, 1.0)
        }

        let deficitNeeded = Int(ceil(Double(bufferNeeded - currentBuffer) / 3.0))
        let maxSelect = max(deficitNeeded, minimumBatchSize)

        // Phase 1: Priority sources (preserved)
        var selected: [FeedSource] = []
        var selectedURLs = Set<String>()
        selectedURLs.reserveCapacity(maxSelect)

        if !prioritySourceURLs.isEmpty {
            priorityLoop: for region in regions {
                guard let sources = sourcesByRegion[region] else { continue }
                for source in sources {
                    guard selected.count < maxSelect else { break priorityLoop }
                    guard prioritySourceURLs.contains(source.url) else { continue }
                    guard selectedURLs.insert(source.url).inserted else { continue }
                    guard Self.matches(source, contentType: activeContentType) else { continue }
                    if !activeLanguages.isEmpty {
                        let sourceLang = FeedStore.normalizedLanguageCode(
                            source.language.flatMap { $0.isEmpty ? nil : $0 }
                        )
                        if let sourceLang, !activeLanguages.contains(sourceLang) { continue }
                    }
                    lastFetchedAt.removeValue(forKey: source.url)
                    consecutiveFailures.removeValue(forKey: source.url)
                    selected.append(source)
                }
            }
        }

        // Phase 2: Fill remaining slots with adaptive scoring
        let remaining = maxSelect - selected.count
        if remaining > 0 {
            let now = Date()
            var scored: [(source: FeedSource, score: Double)] = []
            scored.reserveCapacity(sourcesByRegion.values.map(\.count).reduce(0, +))

            for region in regions {
                guard let sources = sourcesByRegion[region] else { continue }
                let regionDeficit = max(0, regionDeficits[region] ?? 0)
                for source in sources {
                    guard !selectedURLs.contains(source.url) else { continue }
                    guard Self.matches(source, contentType: activeContentType) else { continue }

                    let v = validators[source.url] ?? HTTPValidators()
                    let e = estimators[source.url] ?? CadenceEstimator()

                    // --- GATE: Skip if throttled, in skip window, or within min interval ---
                    if shouldSkip(source: source, validators: v, estimator: e, now: now) { continue }

                    // Existing failure backoff (capped to prevent overflow
                    // to infinity at ~55 consecutive failures)
                    let failures = consecutiveFailures[source.url] ?? 0
                    if failures >= 3 {
                        let cappedFailures = min(failures, 20)
                        let backoff = min(pow(2.0, Double(cappedFailures - 2)) * 60, 86_400)
                        if let last = lastFetchedAt[source.url],
                           now.timeIntervalSince(last) < backoff { continue }
                    }

                    let catDeficit = max(0, finalCategoryDeficits[source.category] ?? 0)

                    // --- STRATEGY: conditional GET possible? (informational, not a gate) ---
                    let canUseConditional = shouldUseConditionalGet(validators: v)

                    let contentTypeBoost: Double = switch activeContentType {
                    case "video": source.isYouTube || source.mediaKind == .video ? 3.0 : 1.0
                    case "audio": source.mediaKind == .audio ? 3.0 : 1.0
                    case "text":  source.mediaKind == .video ? 0.3 : (source.mediaKind == .audio ? 0.3 : 1.0)
                    default:      source.isYouTube ? 2.0 : (source.mediaKind == .audio ? 2.0 : 1.0)
                    }

                    let sourceLang = FeedStore.normalizedLanguageCode(
                        source.language.flatMap { $0.isEmpty ? nil : $0 }
                    )
                    if !activeLanguages.isEmpty,
                       let sourceLang,
                       !activeLanguages.contains(sourceLang) { continue }
                    let languageBoost: Double = activeLanguages.isEmpty ? 1.0
                        : (sourceLang != nil ? 3.0 : 0.8)

                    // ADAPTIVE: urgency replaces hardcoded 30-min timeFactor
                    let u = urgency(validators: v, estimator: e, now: now)

                    // Quality is a *baseline* term, not a preset term (review P1.1). For `.everything` — and for
                    // `.lastClicked`/`.smartFeed` — `PresetScorer` returns no multipliers at all, so every source reached
                    // the default 1.0 and "prefer high-quality sources" was implemented nowhere: this score ranked by
                    // region/category deficit, urgency and content type alone. A preset still *overrides* the baseline
                    // (its multiplier multiplies the product); it is simply no longer the only origin of priority.
                    let qualityFactor = Self.qualityFactor(for: source)

                    let score = regionDeficit * catDeficit * u * contentTypeBoost * languageBoost
                        * qualityFactor
                        * (presetMultipliers[source.url] ?? 1.0)
                    let finalScore = max(score, 0.01) * Double.random(in: 0.98...1.02)
                    if finalScore > 0 { scored.append((source, finalScore)) }
                }
            }

            let diverse = AdaptiveScheduler.diverseSources(from: scored, limit: remaining)
            for source in diverse {
                guard selected.count < maxSelect else { break }
                guard selectedURLs.insert(source.url).inserted else { continue }
                selected.append(source)
            }
        }

        return selected
    }

    // MARK: - Gate & Strategy

    /// Whether this source should be skipped right now.
    private func shouldSkip(source: FeedSource, validators: HTTPValidators, estimator: CadenceEstimator, now: Date) -> Bool {
        // Hard block: Retry-After still active
        if let retryAfter = validators.retryAfter, now < retryAfter { return true }

        // skipHours / skipDays
        if isSkipped(validators: validators, now: now) { return true }

        // Within minimum interval?
        let minInterval = minimumInterval(validators: validators, estimator: estimator)
        if let last = lastFetchedAt[source.url] ?? validators.lastFetchAt {
            if now.timeIntervalSince(last) < minInterval { return true }
        }

        return false
    }

    /// Whether we have validators that enable a conditional GET.
    func shouldUseConditionalGet(validators: HTTPValidators) -> Bool {
        validators.etag != nil || validators.lastModified != nil
    }

    /// Minimum interval before next fetch based on all available signals.
    func minimumInterval(validators: HTTPValidators, estimator: CadenceEstimator) -> TimeInterval {
        // Cache-Control: no-store means we should always do a full GET (no min interval from cache)
        if validators.cacheControl?.noStore == true { return 0 }

        var candidates: [TimeInterval] = []
        if let maxAge = validators.cacheControl?.maxAge { candidates.append(maxAge) }
        if let ttl = validators.ttl { candidates.append(TimeInterval(ttl * 60)) }
        if let expires = validators.expires {
            let delta = expires.timeIntervalSinceNow
            if delta > 0 { candidates.append(delta) }
        }
        if estimator.confidence > 0.3 { candidates.append(estimator.minInterval) }
        return candidates.max() ?? 300  // default 5 min
    }

    /// Urgency ramps from 0 at minInterval to 1.0 at 2x minInterval,
    /// or spikes faster when past expected publication time.
    func urgency(validators: HTTPValidators, estimator: CadenceEstimator, now: Date) -> Double {
        let minInterval = minimumInterval(validators: validators, estimator: estimator)
        let elapsed = now.timeIntervalSince(validators.lastFetchAt ?? .distantPast)

        if estimator.confidence > 0.5 && estimator.lastPublication > .distantPast,
           estimator.publicationInterval > 0 {
            let expectedNext = estimator.lastPublication.addingTimeInterval(estimator.publicationInterval)
            if now > expectedNext {
                return min(1.0, 0.5 + now.timeIntervalSince(expectedNext) / estimator.publicationInterval)
            }
        }

        let excess = elapsed - minInterval
        return min(1.0, max(0, excess / max(minInterval, 1)))
    }

    /// Check if the current time falls into a skipHours/skipDays window.
    func isSkipped(validators: HTTPValidators, now: Date) -> Bool {
        if let skipHours = validators.skipHours {
            let hour = Calendar.current.component(.hour, from: now)
            if skipHours.contains(hour) { return true }
        }
        if let skipDays = validators.skipDays {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let dayName = formatter.string(from: now)
            if skipDays.contains(dayName) { return true }
        }
        return false
    }

    // MARK: - State Management

    static func matches(_ source: FeedSource, contentType: String?) -> Bool {
        switch contentType {
        case "video": return source.isYouTube || source.mediaKind == .video
        case "audio": return source.mediaKind == .audio
        case "text":  return !source.isYouTube && source.mediaKind != .video
            && source.mediaKind != .audio && source.mediaKind != .forum
        case "forum": return source.mediaKind == .forum
        default: return true
        }
    }

    func recordConsumption() {
        consumptionTimestamps.append(Date())
        let cutoff = Date().addingTimeInterval(-300)
        consumptionTimestamps = consumptionTimestamps.filter { $0 > cutoff }
    }

    /// Batch-record fetch outcomes — single pass over all entries instead
    /// of N individual calls with N dictionary lookups. Called from
    /// fetchNextBatch/progressiveFetch after each chunk completes.
    func recordFetchBatch(_ entries: [(sourceURL: String, outcome: FeedFetchOutcome)]) {
        for (sourceURL, outcome) in entries {
            recordFetch(sourceURL: sourceURL, outcome: outcome)
        }
    }

    func recordFetch(sourceURL: String, outcome: FeedFetchOutcome) {
        // A producer this process closed issued no request, so nothing about the source changes: not
        // its last-fetch time, not its cadence, not its validators and not its failure count. The
        // time is recorded after the check for exactly that reason.
        if case .legacyProducerClosed = outcome { return }
        lastFetchedAt[sourceURL] = Date()

        switch outcome {
        case .modifiedWithNewItems(let items, let newValidators):
            consecutiveFailures[sourceURL] = 0
            validators[sourceURL] = newValidators
            if let latestItem = items.map(\.publishedAt).max() {
                estimators[sourceURL, default: CadenceEstimator()].recordPublication(latestItem)
            }
        case .modifiedWithoutNewItems(let newValidators):
            consecutiveFailures[sourceURL] = 0
            validators[sourceURL] = newValidators
            estimators[sourceURL, default: CadenceEstimator()].recordNoChange()
        case .notModified:
            consecutiveFailures[sourceURL] = 0
            estimators[sourceURL, default: CadenceEstimator()].recordNoChange()
        case .failed:
            consecutiveFailures[sourceURL, default: 0] += 1
        case .throttled(let until):
            validators[sourceURL, default: HTTPValidators()].retryAfter = until
        case .legacyProducerClosed:
            // Unreachable: the early return above is the only path a closed producer takes. Stated for
            // exhaustiveness rather than folded into `.failed`, which would penalise a source for a
            // request the mode refused to make.
            return
        }
    }

    // MARK: - Response Time Tracking

    /// Exponential moving average of response time in milliseconds per source.
    /// Used to sort cold-start fetches — fast sources first, slow later.
    /// Missing key = no data yet (neutral, assumed average).
    private var sourceAvgResponseMs: [String: Double] = [:]
    private let responseTimeSmoothing: Double = 0.3  // EMA alpha

    /// Record the wall-clock response time for a source fetch.
    func recordResponseTime(sourceURL: String, milliseconds: Double) {
        let normalized = OPMLParser.normalizeURL(sourceURL)
        if let current = sourceAvgResponseMs[normalized] {
            sourceAvgResponseMs[normalized] = current * (1 - responseTimeSmoothing)
                + milliseconds * responseTimeSmoothing
        } else {
            sourceAvgResponseMs[normalized] = milliseconds
        }
    }

    /// Estimated response time in ms. Returns nil if no data yet.
    func estimatedResponseMs(for sourceURL: String) -> Double? {
        sourceAvgResponseMs[OPMLParser.normalizeURL(sourceURL)]
    }

    /// Sort sources by estimated speed: fastest first, unknown sources
    /// in the middle, known-slow sources last.
    func sortedBySpeed(_ sources: [FeedSource]) -> [FeedSource] {
        let globalAvg = sourceAvgResponseMs.values.reduce(0, +)
            / max(1, Double(sourceAvgResponseMs.count))
        return sources.sorted { lhs, rhs in
            let lhsMs = sourceAvgResponseMs[OPMLParser.normalizeURL(lhs.url)] ?? globalAvg
            let rhsMs = sourceAvgResponseMs[OPMLParser.normalizeURL(rhs.url)] ?? globalAvg
            return lhsMs < rhsMs
        }
    }

    func prioritize(sourceURLs: [String]) {
        for url in sourceURLs {
            lastFetchedAt.removeValue(forKey: url)
            consecutiveFailures.removeValue(forKey: url)
        }
    }

    func remove(sourceURLs: [String]) {
        for url in sourceURLs {
            lastFetchedAt.removeValue(forKey: url)
            consecutiveFailures.removeValue(forKey: url)
            validators.removeValue(forKey: url)
            estimators.removeValue(forKey: url)
        }
    }

    // MARK: - Persistence hooks

    func loadHealth(url: String, lastFetchAt: Date, consecutiveFailures: Int) {
        if self.lastFetchedAt[url] == nil {
            self.lastFetchedAt[url] = lastFetchAt
        }
        if self.consecutiveFailures[url] == nil {
            self.consecutiveFailures[url] = consecutiveFailures
        }
    }

    func loadValidators(url: String, _ v: HTTPValidators) {
        if validators[url] == nil { validators[url] = v }
    }

    func loadEstimator(url: String, _ e: CadenceEstimator) {
        if estimators[url] == nil { estimators[url] = e }
    }

    struct HealthSnapshot {
        let lastFetchAt: Date
        let consecutiveFailures: Int
        let lastStatus: String?
        let lastItemCount: Int?
        let validators: HTTPValidators
        let estimator: CadenceEstimator
    }

    func healthSnapshot(for url: String, itemCount: Int? = nil) -> HealthSnapshot {
        HealthSnapshot(
            lastFetchAt: lastFetchedAt[url] ?? Date(timeIntervalSince1970: 0),
            consecutiveFailures: consecutiveFailures[url] ?? 0,
            lastStatus: consecutiveFailures[url, default: 0] > 0 ? "error" : "ok",
            lastItemCount: itemCount,
            validators: validators[url] ?? HTTPValidators(),
            estimator: estimators[url] ?? CadenceEstimator()
        )
    }

    // MARK: - Private (preserved from SourceScheduler)

    private func estimatedBufferNeeded() -> Int {
        let recent = consumptionTimestamps.filter { $0 > Date().addingTimeInterval(-120) }
        let rate = Double(recent.count) / 120.0
        let target = Int(rate * 180)
        return max(50, min(500, target))
    }

    /// Quality as a **baseline** of the source priority: 0.85 at a score of 0 up to 1.15 at 100, with an undeclared score
    /// sitting at the app's own default (70) in the middle of the band.
    ///
    /// The band is deliberately narrow. Quality has to lean the order and break ties — a reader asking for `.everything`
    /// should meet the better sources first — without drowning the deficit, urgency and content-type signals that encode
    /// *what was asked for*, and without letting a preset's explicit ranking be overridden by a score.
    nonisolated static func qualityFactor(for source: FeedSource) -> Double {
        let raw = Double(source.qualityScore ?? 70)
        let normalised = min(100, max(0, raw)) / 100
        return 0.85 + 0.3 * normalised
    }

    nonisolated static func diverseSources(
        from scoredSources: [(source: FeedSource, score: Double)],
        limit: Int
    ) -> [FeedSource] {
        guard limit > 0, !scoredSources.isEmpty else { return [] }

        var pool = scoredSources.sorted {
            if $0.score == $1.score { return $0.source.url < $1.source.url }
            return $0.score > $1.score
        }
        var selected: [FeedSource] = []
        selected.reserveCapacity(min(limit, pool.count))
        var categoryCounts: [String: Int] = [:]
        var mediaCounts: [String: Int] = [:]
        var regionCounts: [String: Int] = [:]
        var lastCategory: String?

        while selected.count < limit, !pool.isEmpty {
            var bestIndex = pool.startIndex
            var bestRank = -Double.infinity

            for index in pool.indices {
                let candidate = pool[index]
                let source = candidate.source
                let categoryPenalty = 1.0 + Double(categoryCounts[source.category, default: 0]) * 1.85
                let mediaPenalty = 1.0 + Double(mediaCounts[source.mediaKind.rawValue, default: 0]) * 0.18
                let regionKey = diversityRegionKey(source.region)
                let regionPenalty = 1.0 + Double(regionCounts[regionKey, default: 0]) * 0.35
                let immediateRepeatPenalty = source.category == lastCategory ? 0.35 : 1.0
                let rank = candidate.score * immediateRepeatPenalty / categoryPenalty / mediaPenalty / regionPenalty

                if rank > bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }

            let source = pool.remove(at: bestIndex).source
            selected.append(source)
            categoryCounts[source.category, default: 0] += 1
            mediaCounts[source.mediaKind.rawValue, default: 0] += 1
            regionCounts[diversityRegionKey(source.region), default: 0] += 1
            lastCategory = source.category
        }

        return selected
    }

    private nonisolated static func diversityRegionKey(_ region: String) -> String {
        let parts = region.split(separator: "/")
        if parts.count >= 2, parts[0] == "countries" { return "countries/\(parts[1])" }
        if parts.count >= 2, parts[0] == "topic" { return "topic/\(parts[1])" }
        return region
    }

    private func distribution<T: Hashable>(of items: [FeedItem], key: (FeedItem) -> T) -> [T: Double] {
        guard !items.isEmpty else { return [:] }
        var counts: [T: Int] = [:]
        for item in items { counts[key(item), default: 0] += 1 }
        let total = Double(items.count)
        return counts.mapValues { Double($0) / total }
    }

    private func sqrtWeights(for sourcesByRegion: [String: [FeedSource]]) -> [String: Double] {
        sourcesByRegion.mapValues { sqrt(Double($0.count)) }
    }

    private func normalize(_ weights: [String: Double]) -> [String: Double] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return weights }
        return weights.mapValues { $0 / total }
    }

    private func deficits(ideal: [String: Double], actual: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (key, idealVal) in ideal {
            let actualVal = actual[key] ?? 0
            result[key] = idealVal - actualVal
        }
        return result
    }
}
