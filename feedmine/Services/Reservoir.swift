//
//  Reservoir.swift
//  feedmine
//
//  Created by FeedMine Team on 4/7/25.
//

import Foundation

/// In-memory buffer with fairness interleave and source/region diversity.
/// Extracted from FeedLoader. Does NOT touch SQLite — only holds FeedItem arrays.
@MainActor
final class Reservoir {
    static let maxBuffer = 300
    /// A page's worth of items. `nonisolated` because it is a constant every actor-bound caller needs — the cold-start
    /// publish gate in `FeedStore` includes it and is itself `nonisolated` (review P0.3).
    nonisolated static let pageSize = 20
    static let loadMoreThreshold = 5
    static let discardBatchSize = 50
    static let reservoirLowWatermark = 80
    static let progressiveFillTarget = 240
    static let safetyZoneRadius = 50
    static let maxReservoirSize = 500
    nonisolated static let surfacedCooldown: TimeInterval = 1800
    nonisolated static let initialUniqueSourceTarget = 100

    private(set) var visibleItems: [FeedItem] = []
    private(set) var reservoir: [FeedItem] = []
    var reservoirCount: Int { reservoir.count }

    /// Next N items from the reservoir (not yet visible). Used for prefetching.
    func upcomingItems(_ count: Int) -> [FeedItem] {
        Array(reservoir.prefix(count))
    }

    private(set) var surfacedTimestamps: [String: Date] = [:]
    /// Items the user has explicitly marked as read (readItemIDs from FeedStore).
    /// Read items deprecate harder than surfaced items — pushed to the stale bucket.
    var readItemIDs: Set<String> = []

    /// URL → region lookup, provided by SourceRegistry
    var sourceRegionMap: [String: String] = [:]

    /// Preset scoring multipliers for the current preset. Set by FeedStore before
    /// seeding and updated when the preset changes. Used by interleave methods
    /// to bias slot weights toward higher-scored sources.
    var presetMultipliers: [String: Double] = [:]

    // MARK: - Seed (cold/warm start)

    /// Computes the interleave for a cold/warm seed **without touching reservoir
    /// state**. Runs the expensive computation off the main actor.
    ///
    /// The caller re-validates its composition between this call and
    /// ``commitSeed(_:presetMultipliers:)``: the computation runs in a detached
    /// task, which does not inherit cancellation, so it always runs to
    /// completion and a superseded operation must not install its result.
    func computeSeed(
        items: [FeedItem],
        presetMultipliers pm: [String: Double] = [:]
    ) async -> [FeedItem] {
        let rid = readItemIDs
        let st = surfacedTimestamps
        let srm = sourceRegionMap
        return await Task.detached(priority: .userInitiated) {
            Reservoir.interleaveOffMain(items, readItemIDs: rid, surfacedTimestamps: st, sourceRegionMap: srm, presetMultipliers: pm)
        }.value
    }

    /// Installs the result of ``computeSeed(items:presetMultipliers:)``.
    ///
    /// This is the only place a seed mutates the reservoir — including
    /// `markAsSurfaced`, which persists — so it must run only after the caller
    /// has re-validated that its composition is still the current one.
    func commitSeed(_ interleaved: [FeedItem], presetMultipliers pm: [String: Double] = [:]) {
        presetMultipliers = pm
        let w = min(Self.pageSize, interleaved.count)
        visibleItems = Array(interleaved.prefix(w))
        // Union, don't replace: items appended while the interleave ran (e.g.
        // by a concurrent fetch task) would be lost by wholesale replacement.
        // Interleaved items keep their slots first — dedupReservoir is
        // order-preserving (first occurrence wins) — so anything appended
        // during the await lands after them instead of disappearing.
        reservoir = Array(interleaved.dropFirst(w)) + reservoir
        dedupReservoir()
        capReservoir()
        markAsSurfaced(visibleItems)
    }

    // MARK: - Append new items from fetch

    func append(_ items: [FeedItem]) {
        let visibleIDs = Set(visibleItems.map(\.id))
        let trulyNew = items.filter { !visibleIDs.contains($0.id) }
        guard !trulyNew.isEmpty else { return }
        // Interleave only the NEW items among themselves and append them to the
        // tail; do not re-interleave the whole reservoir. Re-interleaving here
        // reordered items the user was about to scroll into, so content shifted
        // under them right before a tap. dedupReservoir is order-preserving
        // (keeps the first occurrence), so the existing front stays put.
        reservoir.append(contentsOf: interleave(trulyNew, presetMultipliers: presetMultipliers))
        dedupReservoir()
        capReservoir()
    }

    // MARK: - Scroll: move from reservoir to visible

    func moveToVisible(count: Int) {
        guard !reservoir.isEmpty else { return }
        // No periodic reshuffle here. Re-interleaving the reservoir every few
        // pages reordered upcoming items as the user scrolled toward them —
        // content shifted before they could tap. Diversity comes from
        // seed()/append(); order stays stable once set.
        let visibleIDs = Set(visibleItems.map(\.id))
        // Remove items already in visible to prevent duplicates
        reservoir.removeAll { visibleIDs.contains($0.id) }
        guard !reservoir.isEmpty else { return }
        let toMove = min(count, reservoir.count)
        let batch = Array(reservoir.prefix(toMove))
        visibleItems.append(contentsOf: batch)
        reservoir.removeFirst(toMove)
        markAsSurfaced(batch)
    }

    // MARK: - Trim buffer

    func trimBuffer(currentVisibleIndex: Int) {
        guard visibleItems.count > Self.maxBuffer else { return }
        let excess = visibleItems.count - Self.maxBuffer
        let toDiscard = min(Self.discardBatchSize, excess)
        // Only ever trim from the TAIL, and only items safely BELOW the viewport
        // (beyond the safety zone). Removing from the HEAD of a
        // ScrollView+LazyVStack shifts the scroll offset and makes the feed jump
        // under the reader — never do that. Tail items are ahead of the user and
        // get re-supplied from the reservoir when scrolled into. The head (already
        // seen) grows with scroll depth; that memory cost is accepted so that what
        // the user has scrolled past never moves. (Feed is sacred.)
        let safeEnd = min(visibleItems.count, currentVisibleIndex + Self.safetyZoneRadius)
        guard safeEnd < visibleItems.count else { return }
        let belowToDiscard = min(toDiscard, visibleItems.count - safeEnd)
        if belowToDiscard > 0 {
            // Return trimmed tail to the front of the reservoir so items are
            // re-supplied when the user scrolls into them. The old code
            // permanently discarded them, causing the feed to dead-end
            // mid-session at the trim point (review finding H3).
            let trimmed = visibleItems.suffix(belowToDiscard)
            visibleItems.removeLast(belowToDiscard)
            reservoir.insert(contentsOf: trimmed, at: 0)
        }
    }

    // MARK: - Remove a single source (toggle one feed OFF)

    /// Remove only the items belonging to one feed URL, then top up the visible
    /// page from the reservoir if it fell below a full page. Unlike
    /// `removeRegion`, this leaves sibling feeds in the same region untouched —
    /// disabling one feed must not empty the whole region from the buffer.
    func removeSource(_ sourceURL: String) {
        let isDisabled: (FeedItem) -> Bool = { $0.sourceURL == sourceURL }
        visibleItems.removeAll(where: isDisabled)
        reservoir.removeAll(where: isDisabled)
        if visibleItems.count < Self.pageSize && !reservoir.isEmpty {
            let needed = min(Self.pageSize - visibleItems.count, reservoir.count)
            let batch = Array(reservoir.prefix(needed))
            visibleItems.append(contentsOf: batch)
            reservoir.removeFirst(needed)
            markAsSurfaced(batch)
        }
    }

    // MARK: - Remove region (toggle OFF)

    func removeRegion(_ region: String) {
        removeRegions([region])
    }

    /// Remove several region trees in one pass. Bulk country toggles used to
    /// call `removeRegion` once per country, repeatedly scanning the entire
    /// reservoir before the switch could redraw.
    func removeRegions(_ regions: Set<String>) {
        guard !regions.isEmpty else { return }
        // Pre-compute all ancestor paths for disabled regions so the per-item
        // check is a single Set.contains — no String slicing in the hot loop.
        var disabledWithAncestors = regions
        for region in regions {
            var candidate = region
            while let sep = candidate.lastIndex(of: "/") {
                candidate = String(candidate[..<sep])
                disabledWithAncestors.insert(candidate)
            }
        }
        let isDisabled: (FeedItem) -> Bool = { [self] item in
            let itemRegion = sourceRegionMap[item.sourceURL] ?? "global"
            if disabledWithAncestors.contains(itemRegion) { return true }
            // Descendants of a disabled region must go too — the same
            // hasPrefix(region + "/") pattern applyFilters uses (e.g.
            // disabling countries/brazil also removes
            // countries/brazil/sao-paulo). Check the originally disabled
            // regions only: the ancestor expansion above would otherwise
            // sweep sibling sub-regions (disabling countries/brazil/sao-paulo
            // must not remove countries/brazil/rio items).
            for disabled in regions where itemRegion.hasPrefix(disabled + "/") {
                return true
            }
            return false
        }
        visibleItems.removeAll(where: isDisabled)
        reservoir.removeAll(where: isDisabled)
        if visibleItems.count < Self.pageSize && !reservoir.isEmpty {
            let needed = min(Self.pageSize - visibleItems.count, reservoir.count)
            let batch = Array(reservoir.prefix(needed))
            visibleItems.append(contentsOf: batch)
            reservoir.removeFirst(needed)
            markAsSurfaced(batch)
        }
    }

    // MARK: - Clear + emergency

    func clear() {
        visibleItems.removeAll()
        reservoir.removeAll()
        surfacedTimestamps.removeAll()
    }

    func emergencyTrim() {
        let safeCount = Self.safetyZoneRadius * 2
        if visibleItems.count > safeCount {
            visibleItems = Array(visibleItems.suffix(safeCount))
        }
        reservoir.removeAll()
    }

    /// Shake-to-refresh: dump visible items back into reservoir, re-interleave,
    /// and pull a fresh page. Items already surfaced get pushed to the back.
    func shakeReshuffle() {
        guard !visibleItems.isEmpty || !reservoir.isEmpty else { return }
        reservoir.append(contentsOf: visibleItems)
        visibleItems.removeAll()
        // Offload interleave to background — same pattern as seed().
        // The synchronous interleave() on MainActor was blocking for 10-100ms.
        Task.detached { [reservoir, presetMultipliers, sourceRegionMap, readItemIDs, surfacedTimestamps] in
            let interleaved = Self.interleaveOffMain(
                reservoir,
                readItemIDs: readItemIDs,
                surfacedTimestamps: surfacedTimestamps,
                sourceRegionMap: sourceRegionMap,
                presetMultipliers: presetMultipliers
            )
            await MainActor.run {
                let result = interleaved
                self.reservoir = result
                self.capReservoir()
                let w = min(Self.pageSize, self.reservoir.count)
                self.visibleItems = Array(self.reservoir.prefix(w))
                self.reservoir.removeFirst(w)
                self.markAsSurfaced(self.visibleItems)
            }
        }
    }

    // MARK: - Interleave

    private func interleave(_ items: [FeedItem], presetMultipliers: [String: Double] = [:]) -> [FeedItem] {
        // Instance path: full diversity with country spreading on MainActor.
        // Pass sourceRegionMap so slots are spread by country.
        return Self.interleaveImpl(
            items,
            readItemIDs: readItemIDs,
            surfacedTimestamps: surfacedTimestamps,
            sourceRegionMap: sourceRegionMap,
            useCountrySpreading: true,
            presetMultipliers: presetMultipliers
        )
    }

    /// Pure interleave computation — no instance state, safe to call from any thread.
    /// Takes snapshots of the mutable state it needs.
    nonisolated static func interleaveOffMain(
        _ items: [FeedItem],
        readItemIDs: Set<String>,
        surfacedTimestamps: [String: Date],
        sourceRegionMap: [String: String],
        presetMultipliers: [String: Double] = [:]
    ) -> [FeedItem] {
        // Off-main path: full diversity with country spreading.
        // sourceRegionMap is now actually used (was accepted but ignored).
        return interleaveImpl(
            items,
            readItemIDs: readItemIDs,
            surfacedTimestamps: surfacedTimestamps,
            sourceRegionMap: sourceRegionMap,
            useCountrySpreading: true,
            presetMultipliers: presetMultipliers
        )
    }

    /// Single shared interleave implementation. Both on-main and off-main
    /// paths use this, guaranteeing identical ordering behavior.
    private nonisolated static func interleaveImpl(
        _ items: [FeedItem],
        readItemIDs: Set<String>,
        surfacedTimestamps: [String: Date],
        sourceRegionMap: [String: String],
        useCountrySpreading: Bool,
        presetMultipliers: [String: Double] = [:]
    ) -> [FeedItem] {
        guard items.count > 1 else { return items }
        var bySource: [String: [FeedItem]] = [:]
        for item in items {
            bySource[item.sourceURL, default: []].append(item)
        }
        guard bySource.count > 1 else {
            return interleaveByTypeCategoryImpl(items)
        }
        // Within each source: surfaced → stale → recent, each spread by type+category
        let surfacedCutoff = Date().addingTimeInterval(-surfacedCooldown)
        let staleNewsCutoff = Date().addingTimeInterval(-86400)
        let staleEvergreenCutoff = Date().addingTimeInterval(-604800)
        for key in bySource.keys {
            let bucket = bySource[key]!
            let readIDs = bucket.filter { readItemIDs.contains($0.id) }.map(\.id)
            let surfacedIDs = Set(bucket.filter { item in
                guard let ts = surfacedTimestamps[item.id] else { return false }
                return ts > surfacedCutoff
            }.map(\.id))
            let staleIDs = Set(bucket.filter { item in
                if surfacedIDs.contains(item.id) || readIDs.contains(item.id) { return false }
                let cutoff = item.isTimeless ? staleEvergreenCutoff : staleNewsCutoff
                return item.publishedAt < cutoff
            }.map(\.id) + readIDs)
            let recent = interleaveByTypeCategoryImpl(bucket.filter { !surfacedIDs.contains($0.id) && !staleIDs.contains($0.id) }.shuffled())
            let stale = interleaveByTypeCategoryImpl(bucket.filter { staleIDs.contains($0.id) }.shuffled())
            let surfaced = interleaveByTypeCategoryImpl(bucket.filter { surfacedIDs.contains($0.id) }.shuffled())
            bySource[key] = recent + stale + surfaced
        }
        // Weighted slots — boost by preset multiplier so higher-scored
        // sources get more slots in the round-robin, appearing earlier.
        let minCount = max(1, bySource.values.map(\.count).min() ?? 1)
        let weights: [String: Int] = bySource.mapValues { items in
            let baseWeight = min(5, max(1, items.count / minCount))
            let mult = presetMultipliers[items.first?.sourceURL ?? ""] ?? 1.0
            let adjusted = Int(Double(baseWeight) * mult)
            return min(10, max(1, adjusted))
        }
        var slots: [String] = []
        for (sourceURL, srcItems) in bySource where !srcItems.isEmpty {
            let w = weights[sourceURL] ?? 1
            for _ in 0..<w { slots.append(sourceURL) }
        }
        // Spread slots to avoid consecutive same-source and same-country
        slots = spreadSlotsImpl(slots)
        if useCountrySpreading {
            slots = spreadSlotsByCountryImpl(slots, sourceRegionMap: sourceRegionMap)
        }
        // Round-robin
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        var indices: [String: Int] = Dictionary(uniqueKeysWithValues: bySource.keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for sourceURL in slots {
                guard let list = bySource[sourceURL], indices[sourceURL]! < list.count else { continue }
                result.append(list[indices[sourceURL]!])
                indices[sourceURL]! += 1
                added = true
            }
        }
        let fresh = spreadForFreshnessImpl(result, sourceRegionMap: sourceRegionMap, presetMultipliers: presetMultipliers)
        return frontLoadUniqueProvidersImpl(fresh, count: initialUniqueSourceTarget)
    }

    /// The first screen is the app's promise of breadth. When enough providers
    /// are available, reserve one slot per provider before any provider gets a
    /// second card; the remainder keeps the freshness pass order unchanged.
    private nonisolated static func frontLoadUniqueProvidersImpl(
        _ items: [FeedItem],
        count: Int
    ) -> [FeedItem] {
        guard count > 1, items.count > 1 else { return items }
        let target = min(count, Set(items.map(providerKey)).count)
        guard target > 1 else { return items }

        var selectedIndices = Set<Int>()
        var selectedProviders = Set<String>()
        var prefix: [FeedItem] = []
        prefix.reserveCapacity(target)

        for (index, item) in items.enumerated() {
            guard selectedProviders.insert(providerKey(item)).inserted else { continue }
            prefix.append(item)
            selectedIndices.insert(index)
            if prefix.count == target { break }
        }

        guard prefix.count == target else { return items }
        prefix.append(contentsOf: items.enumerated().compactMap { index, item in
            selectedIndices.contains(index) ? nil : item
        })
        return prefix
    }

    private nonisolated static func interleaveByTypeCategoryImpl(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 1 else { return items }
        var buckets: [String: [FeedItem]] = [:]
        for item in items {
            let type = item.isPodcast ? "audio" : (item.isYouTube ? "video" : "text")
            buckets["\(type):\(item.category)", default: []].append(item)
        }
        guard buckets.count > 1 else { return items.shuffled() }
        for key in buckets.keys { buckets[key] = buckets[key]?.shuffled() }
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        var indices = Dictionary(uniqueKeysWithValues: buckets.keys.map { ($0, 0) })
        let keys = buckets.keys.shuffled()
        var added = true
        while added {
            added = false
            for key in keys {
                guard let list = buckets[key], indices[key]! < list.count else { continue }
                result.append(list[indices[key]!])
                indices[key]! += 1
                added = true
            }
        }
        return result
    }

    private nonisolated static func spreadSlotsImpl(_ slots: [String]) -> [String] {
        var groups: [String: [String]] = [:]
        for slot in slots { groups[slot, default: []].append(slot) }
        guard groups.count > 1 else { return slots }
        for key in groups.keys { groups[key] = groups[key]?.shuffled() }
        var result: [String] = []
        result.reserveCapacity(slots.count)
        let keys = groups.keys.shuffled()
        var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for key in keys {
                guard let list = groups[key], indices[key]! < list.count else { continue }
                result.append(list[indices[key]!])
                indices[key]! += 1
                added = true
            }
        }
        return result
    }

    private nonisolated static func spreadSlotsByCountryImpl(_ slots: [String], sourceRegionMap: [String: String]) -> [String] {
        guard slots.count > 2 else { return slots }
        var result = slots
        var pass = 0
        var swapped = true
        while swapped && pass < 3 {
            swapped = false; pass += 1
            for i in 0..<(result.count - 1) {
                let countryA = sourceRegionMap[result[i]] ?? "global"
                let countryB = sourceRegionMap[result[i + 1]] ?? "global"
                guard countryA == countryB else { continue }
                var swapIdx: Int?
                for j in (i + 2)..<result.count {
                    if (sourceRegionMap[result[j]] ?? "global") != countryA { swapIdx = j; break }
                }
                if swapIdx == nil {
                    for j in stride(from: i - 1, through: 0, by: -1) {
                        if (sourceRegionMap[result[j]] ?? "global") != countryA { swapIdx = j; break }
                    }
                }
                if let j = swapIdx { result.swapAt(i + 1, j); swapped = true }
            }
        }
        return result
    }

    /// Keep the next screenful fresh. Provider repetition is the strongest
    /// signal, followed by subject, geography, and media type. Each choice is
    /// made from a bounded look-ahead window so recency tiers stay broadly in
    /// place and the pass remains cheap for large fetches.
    private nonisolated static func spreadForFreshnessImpl(
        _ items: [FeedItem],
        sourceRegionMap: [String: String],
        presetMultipliers: [String: Double] = [:]
    ) -> [FeedItem] {
        guard items.count > 2 else { return items }

        // Taken positions are marked instead of removed. `remove(at:)` inside the search window shifted every
        // later element on every step, so a large batch paid quadratic element movement for a pass that only
        // ever looks at the first 96 live candidates (S14). What the loop sees is unchanged: a candidate's
        // rank is still its position among the candidates not yet taken, in the input's order.
        let pool = items
        var consumed = [Bool](repeating: false, count: items.count)
        var liveCount = items.count
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)

        let providerVariety = Set(items.map(providerKey)).count
        let categoryVariety = Set(items.map(\.category)).count
        let regionVariety = Set(items.map { sourceRegionMap[$0.sourceURL] ?? $0.region }).count
        let mediaVariety = Set(items.map(mediaKey)).count
        let providerWindow = min(6, max(0, providerVariety - 1))
        let categoryWindow = min(10, max(0, categoryVariety - 1))
        let regionWindow = min(6, max(0, regionVariety - 1))
        let mediaWindow = min(4, max(0, mediaVariety - 1))

        while liveCount > 0 {
            let searchCount = min(96, liveCount)
            let recentProviders = Set(result.suffix(providerWindow).map(providerKey))
            let recentCategories = Set(result.suffix(categoryWindow).map(\.category))
            let recentRegions = Set(result.suffix(regionWindow).map {
                sourceRegionMap[$0.sourceURL] ?? $0.region
            })
            let recentMedia = Set(result.suffix(mediaWindow).map(mediaKey))

            var bestIndex = -1
            var bestPenalty = Int.max
            var rank = 0
            for index in pool.indices {
                if rank == searchCount { break }
                guard !consumed[index] else { continue }
                let candidate = pool[index]
                let position = rank
                rank += 1
                let region = sourceRegionMap[candidate.sourceURL] ?? candidate.region
                var penalty = position
                if recentProviders.contains(providerKey(candidate)) {
                    let sourceMult = presetMultipliers[candidate.sourceURL] ?? 1.0
                    penalty += Int(100_000.0 / max(1.0, sourceMult))
                }
                if recentCategories.contains(candidate.category) { penalty += 50_000 }
                if recentRegions.contains(region) { penalty += 15_000 }
                if recentMedia.contains(mediaKey(candidate)) { penalty += 30_000 }
                if penalty < bestPenalty {
                    bestPenalty = penalty
                    bestIndex = index
                    if penalty == position { break }
                }
            }
            guard bestIndex >= 0 else { break }

            consumed[bestIndex] = true
            liveCount -= 1
            result.append(pool[bestIndex])
        }
        return result
    }

    /// A catalogue can contain many generated feeds backed by one aggregator.
    /// Those URLs are distinct fetch targets, but they are not distinct content
    /// providers and must not occupy several diversity slots on the same screen.
    nonisolated static func providerKey(_ item: FeedItem) -> String {
        providerKey(forSourceURL: item.sourceURL)
    }

    /// Same key, for callers that hold a URL and not an item — the fetch's own stop condition measures
    /// diversity in the publication gate's unit, so both sides count the same thing.
    nonisolated static func providerKey(forSourceURL sourceURL: String) -> String {
        guard let host = URLComponents(string: sourceURL)?.host?.lowercased() else {
            return sourceURL
        }
        if host == "news.google.com" || host.hasSuffix(".news.google.com") {
            // Separate queries are still one Google News provider. Treating
            // their generated feed labels as publishers made a long run of
            // near-identical candidate cards look artificially diverse.
            return "aggregator:news.google.com"
        }
        return sourceURL
    }

    private nonisolated static func mediaKey(_ item: FeedItem) -> String {
        if item.isPodcast { return "audio" }
        if item.isYouTube { return "video" }
        if item.isForum { return "forum" }
        return "text"
    }

    private func dedupReservoir() {
        var seen = Set<String>()
        reservoir = reservoir.filter { seen.insert($0.id).inserted }
    }

    private func capReservoir() {
        guard reservoir.count > Self.maxReservoirSize else { return }
        var bySource: [String: [FeedItem]] = [:]
        for item in reservoir { bySource[item.sourceURL, default: []].append(item) }
        let sourceCount = bySource.count
        guard sourceCount > 1 else {
            reservoir = Array(reservoir.prefix(Self.maxReservoirSize))
            return
        }
        let floorPerSource = 1
        let floorSlots = min(sourceCount * floorPerSource, Self.maxReservoirSize)
        let proportionalSlots = Self.maxReservoirSize - floorSlots
        var selected: [FeedItem] = []
        var remainingBySource: [String: [FeedItem]] = [:]
        for (sourceURL, items) in bySource {
            let take = min(floorPerSource, items.count)
            selected.append(contentsOf: items.prefix(take))
            if items.count > take { remainingBySource[sourceURL] = Array(items.dropFirst(take)) }
        }
        // The floor is one item per source and the loop above honours it for *every* source, so a catalogue
        // with more sources than `maxReservoirSize` (a page of generated feeds, each with a couple of items)
        // put the reservoir over its cap in one pass: `floorSlots` was clamped to the cap but the allocation
        // was not (S14). The cap is absolute, so the surplus is dropped here; `proportionalSlots` is already
        // zero in this case, so nothing downstream can add items back.
        if selected.count > Self.maxReservoirSize {
            selected = Array(selected.prefix(Self.maxReservoirSize))
        }
        if proportionalSlots > 0, !remainingBySource.isEmpty {
            let totalRemaining = remainingBySource.values.map(\.count).reduce(0, +)
            for (sourceURL, items) in remainingBySource {
                let fraction = Double(items.count) / Double(max(1, totalRemaining))
                let extra = min(Int(fraction * Double(proportionalSlots)), items.count)
                if extra > 0 {
                    selected.append(contentsOf: items.prefix(extra))
                    if items.count > extra {
                        remainingBySource[sourceURL] = Array(items.dropFirst(extra))
                    } else {
                        remainingBySource.removeValue(forKey: sourceURL)
                    }
                }
            }
        }
        if selected.count < Self.maxReservoirSize, !remainingBySource.isEmpty {
            let keys = remainingBySource.keys.shuffled()
            var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
            while selected.count < Self.maxReservoirSize {
                var added = false
                for key in keys {
                    guard let list = remainingBySource[key],
                          indices[key]! < list.count,
                          selected.count < Self.maxReservoirSize else { continue }
                    selected.append(list[indices[key]!])
                    indices[key]! += 1
                    added = true
                }
                if !added { break }
            }
        }
        // Keep the selected diverse subset, but in the reservoir's existing
        // order — re-interleaving here would reorder items near the viewport,
        // the same instability fixed in append()/moveToVisible().
        let keepIDs = Set(selected.map(\.id))
        reservoir = reservoir.filter { keepIDs.contains($0.id) }
    }

    private func markAsSurfaced(_ items: [FeedItem]) {
        let now = Date()
        for item in items {
            if surfacedTimestamps[item.id] == nil {
                surfacedTimestamps[item.id] = now
            }
        }
        // Two-tier cleanup: first remove expired (older than cooldown),
        // then cap at 1500 most recent if still over threshold.
        if surfacedTimestamps.count > 1500 {
            let cutoff = now.addingTimeInterval(-Self.surfacedCooldown)
            surfacedTimestamps = surfacedTimestamps.filter { $0.value > cutoff }
        }
        // If still too many (all within cooldown), keep only the 1500 newest
        if surfacedTimestamps.count > 1500 {
            let sorted = surfacedTimestamps.sorted { $0.value > $1.value }
            surfacedTimestamps = Dictionary(uniqueKeysWithValues: sorted.prefix(1500).map { ($0.key, $0.value) })
        }
    }

    // MARK: - Off-Main-Actor Interleave

    /// Append items that have already been interleaved off the main actor.
    /// Skips the interleave step — just dedup and cap.
    func appendPreInterleaved(_ items: [FeedItem]) {
        let visibleIDs = Set(visibleItems.map(\.id))
        let trulyNew = items.filter { !visibleIDs.contains($0.id) }
        guard !trulyNew.isEmpty else { return }
        reservoir.append(contentsOf: trulyNew)
        dedupReservoir()
        capReservoir()
    }

}
