import Foundation
import Observation

enum NodeStatus: Equatable {
    case on
    case off
    case partial(activeCount: Int)
}

/// Manages feed source toggles with a two-set model.
///
/// `disabled` tracks what's explicitly OFF (a feed, region, country, or
/// category key). `enabledOverrides` tracks individual feeds explicitly turned
/// ON so they show even while a parent group is OFF — without this, a single
/// `disabled` set cannot represent "country off, but keep this one feed."
///
/// Three states per group node:
/// - ON — not in disabled
/// - OFF — in disabled, zero active children
/// - PARTIAL — in disabled, but has ≥1 active child (an enabledOverride)
///
/// Resolution for a feed (O(1) — a handful of Set lookups):
/// 1. Feed's own key in disabled? → OFF (explicit off wins over everything)
/// 2. Feed's own key in enabledOverrides? → ON (explicit on beats a parent off)
/// 3. Feed's region / country / category key in disabled? → OFF
/// 4. Otherwise → ON
@MainActor
@Observable
final class SourceRegistry {
    struct LookupSnapshot: Sendable {
        let sourcesByNormalizedURL: [String: FeedSource]
        let explicitlyDisabledURLs: Set<String>
    }
    struct LanguageCountSnapshot {
        let sourceRevision: UInt64
        let enablementRevision: UInt64
        let enabled: [String: Int]
        let total: [String: Int]
    }
    var sources: [FeedSource] = [] {
        didSet {
            // A caller that derived the caches off the main actor (the OPML
            // startup path, where the rebuild costs seconds over 77k sources)
            // hands them over here instead of paying for them twice.
            if let prepared = preparedCaches {
                preparedCaches = nil
                sharedCountrySourceURLs = prepared.sharedCountrySourceURLs
                applyCaches(prepared)
                return
            }
            // Source replacements must not leave stale exclusions for URLs
            // that no longer exist in the current catalog.
            sharedCountrySourceURLs.formIntersection(Set(sources.map {
                OPMLParser.normalizeURL($0.url)
            }))
            // Skip rebuild when sources haven't changed — prevents redundant
            // 7,500-entry dictionary allocation during startup when
            // loadFromOPML then restoreImportedSources both assign.
            // Compare by count first (fast reject), then by element-wise
            // equality (O(n), no allocation). The old implementation built
            // two 11,000-entry joined-string Sets per assignment (~150-800ms
            // on the main actor); FeedSource is now Equatable so the exact
            // comparison is allocation-free. Language/category/region/title
            // edits must refresh derived caches used by filter sheets and
            // fetch scheduling.
            guard sources.count != oldValue.count
                    || !sources.elementsEqual(oldValue) else { return }
            rebuildCaches()
        }
    }
    var disabled: Set<String> = []
    /// Captured before OPML URL deduplication. A shared syndicated feed is
    /// still fetchable once, but cannot be shown as a country-local source.
    private(set) var sharedCountrySourceURLs: Set<String> = []
    /// Feed URL keys explicitly turned ON despite a disabled parent group.
    var enabledOverrides: Set<String> = []

    /// Cached count of active sources under each region/category key.
    /// Recomputed after every toggle.
    private var activeCount: [String: Int] = [:]

    private(set) var sourceRevision: UInt64 = 0
    private(set) var enablementRevision: UInt64 = 0
    private(set) var totalLanguageCounts: [String: Int] = [:]
    private(set) var enabledLanguageCounts: [String: Int] = [:]
    private(set) var availableLanguageCodes: Set<String> = []
    private(set) var availableCategories: [String] = []

    @ObservationIgnored private var _enabledSources: [FeedSource]?
    @ObservationIgnored private var _allTopicRegions: [String]?
    @ObservationIgnored private var _availableCountries: [Country]?
    @ObservationIgnored private var _sourcesByRegion: [String: [FeedSource]]?
    @ObservationIgnored private var _uniqueRegions: Set<String>?
    @ObservationIgnored private var _countrySources: [FeedSource]?
    @ObservationIgnored private var _countryRegionKeys: Set<String>?
    @ObservationIgnored private var _countrySourceKeys: Set<String>?
    @ObservationIgnored private var _topicSourceKeys: Set<String>?
    @ObservationIgnored private var _sourceKeysByCategory: [String: Set<String>] = [:]
    @ObservationIgnored private var activeCountsAreCurrent = false
    @ObservationIgnored private var saveStateTask: Task<Void, Never>?
    @ObservationIgnored private var activeCountsGeneration: UInt64 = 0
    /// Normalised URL per source, in `sources` order, from the last derivation. Kept so
    /// eligibility can be recomputed without normalising 77k URLs (regex) on the main actor.
    @ObservationIgnored private var normalizedSourceURLs: [String] = []
    /// Caches derived off the main actor by
    /// `deriveCaches(from:sharedCountrySourceURLs:)` and consumed by the next
    /// `sources` assignment, so the 77k-entry rebuild never runs on the main actor
    /// during startup.
    @ObservationIgnored private var preparedCaches: DerivedCaches?
    /// Group states changed in a bulk action. They can render immediately
    /// while the full derived-count snapshot is rebuilt after the interaction.
    @ObservationIgnored private var pendingDisabledGroupKeys: Set<String> = []

    // Debug counters
    private(set) var opmlFileCount = 0
    private(set) var invalidSourceCount = 0
    private(set) var duplicateSourceCount = 0
    private(set) var opmlErrorCount = 0

    // MARK: - Key constructors

    nonisolated static func regionKey(_ path: String) -> String { "region:\(path)" }
    nonisolated static func categoryKey(_ name: String) -> String { "cat:\(name)" }
    nonisolated static func sourceKey(_ url: String) -> String { "url:\(OPMLParser.normalizeURL(url))" }

    // MARK: - Feed resolution (O(1) — all Dict/Set lookups)

    /// url → FeedSource, rebuilt when sources change
    private var sourceByURL: [String: FeedSource] = [:]

    /// Derived state that is a pure function of `sources` and the shared-country
    /// URL set. `deriveCaches` computes it (off the main actor when the caller can
    /// afford it) and `applyCaches` installs it; the synchronous path uses both in
    /// sequence, so there is exactly one implementation of the derivation.
    struct DerivedCaches: Sendable {
        var sourceByURL: [String: FeedSource] = [:]
        var languageCounts: [String: Int] = [:]
        var topicRegions: [String] = []
        var countrySourceKeys: Set<String> = []
        var topicSourceKeys: Set<String> = []
        var sourceKeysByCategory: [String: Set<String>] = [:]
        /// Normalised URL of each source, in `sources` order. The derivation already
        /// computes them, so anything that would otherwise re-normalise the whole
        /// catalogue (regex work) can look them up here instead.
        var normalizedURLs: [String] = []
        var sharedCountrySourceURLs: Set<String> = []
    }

    /// Pure and `nonisolated`, so a caller may run it in a detached task. Walks
    /// every source — 77,443 entries in the bundled catalogue — together with the
    /// URL normalisation that goes with each, which is why the startup path must
    /// not run it on the main actor.
    nonisolated static func deriveCaches(
        from sources: [FeedSource],
        sharedCountrySourceURLs: Set<String>
    ) -> DerivedCaches {
        var byURL: [String: FeedSource] = [:]
        var languageCounts: [String: Int] = [:]
        var topicRegions = Set<String>()
        var countrySourceKeys = Set<String>()
        var topicSourceKeys = Set<String>()
        var sourceKeysByCategory: [String: Set<String>] = [:]
        var normalizedURLs: [String] = []
        byURL.reserveCapacity(sources.count)
        normalizedURLs.reserveCapacity(sources.count)
        for source in sources {
            let normalizedURL = OPMLParser.normalizeURL(source.url)
            normalizedURLs.append(normalizedURL)
            if byURL[normalizedURL] == nil { byURL[normalizedURL] = source }
            // `sourceKey` is exactly "url:" + the normalised URL, so build it from the
            // value just computed instead of normalising the same URL a second time —
            // this runs on the startup path, over 77k URLs.
            let sourceKey = "url:" + normalizedURL
            sourceKeysByCategory[source.category, default: []].insert(sourceKey)
            if source.isCountryFeed { countrySourceKeys.insert(sourceKey) }
            if source.region.hasPrefix("topic/") { topicSourceKeys.insert(sourceKey) }
            if let language = FeedStore.normalizedLanguageCode(source.language) {
                languageCounts[language, default: 0] += 1
            }
            if source.region.hasPrefix("topic/") {
                topicRegions.insert(source.region)
            }
        }
        // Source replacements must not leave stale exclusions for URLs that no
        // longer exist in the current catalog. `byURL`'s keys are exactly the set of
        // normalised URLs just collected, so this costs nothing extra.
        var sharedCountryURLs = sharedCountrySourceURLs
        sharedCountryURLs.formIntersection(byURL.keys)
        return DerivedCaches(
            sourceByURL: byURL,
            languageCounts: languageCounts,
            topicRegions: topicRegions.sorted(),
            countrySourceKeys: countrySourceKeys,
            topicSourceKeys: topicSourceKeys,
            sourceKeysByCategory: sourceKeysByCategory,
            normalizedURLs: normalizedURLs,
            sharedCountrySourceURLs: sharedCountryURLs
        )
    }

    private func rebuildCaches() {
        applyCaches(Self.deriveCaches(
            from: sources,
            sharedCountrySourceURLs: sharedCountrySourceURLs
        ))
    }

    private func applyCaches(_ derived: DerivedCaches) {
        sourceByURL = derived.sourceByURL
        normalizedSourceURLs = derived.normalizedURLs
        totalLanguageCounts = derived.languageCounts
        availableLanguageCodes = Set(derived.languageCounts.keys)
        _allTopicRegions = derived.topicRegions
        _regionMap = nil
        _languageMap = nil
        _enabledSources = nil
        _availableCountries = nil
        _sourcesByRegion = nil
        _uniqueRegions = nil
        _countrySources = nil
        _countryRegionKeys = nil
        _countrySourceKeys = derived.countrySourceKeys
        _topicSourceKeys = derived.topicSourceKeys
        _sourceKeysByCategory = derived.sourceKeysByCategory
        activeCount.removeAll()
        activeCountsAreCurrent = false
        activeCountsGeneration &+= 1
        pendingDisabledGroupKeys.removeAll()
        sourceRevision &+= 1
        enablementRevision &+= 1
    }

    private var sourcesByRegion: [String: [FeedSource]] {
        if let cached = _sourcesByRegion { return cached }
        let grouped = Dictionary(grouping: sources, by: \.region)
        _sourcesByRegion = grouped
        return grouped
    }

    private var uniqueRegions: Set<String> {
        if let cached = _uniqueRegions { return cached }
        let regions = Set(sources.map(\.region))
        _uniqueRegions = regions
        return regions
    }

    private var countrySources: [FeedSource] {
        if let cached = _countrySources { return cached }
        let country = sources.filter(\.isCountryFeed)
        _countrySources = country
        return country
    }

    private var countryRegionKeys: Set<String> {
        if let cached = _countryRegionKeys { return cached }
        // Derive from every region under countries/ (not just isCountryFeed
        // sources) so countries represented only by sub-regions or by
        // media-only sources can still be bulk-disabled. Each country is keyed
        // by its top-level region (region:countries/<slug>), which is the key
        // isSourceEnabled checks for both direct and sub-region sources.
        let keys = Set(
            uniqueRegions.lazy
                .filter { $0.hasPrefix("countries/") }
                .map { region -> String in
                    let parts = region.split(separator: "/").map(String.init)
                    return Self.regionKey(parts.prefix(2).joined(separator: "/"))
                }
        )
        _countryRegionKeys = keys
        return keys
    }

    private var countrySourceKeys: Set<String> {
        if let cached = _countrySourceKeys { return cached }
        let keys = Set(countrySources.map { Self.sourceKey($0.url) })
        _countrySourceKeys = keys
        return keys
    }

    private var topicSourceKeys: Set<String> {
        if let cached = _topicSourceKeys { return cached }
        let keys = Set(sources.lazy
            .filter { $0.region.hasPrefix("topic/") }
            .map { Self.sourceKey($0.url) })
        _topicSourceKeys = keys
        return keys
    }

    func sources(inRegionTree region: String) -> [FeedSource] {
        let prefix = "\(region)/"
        return uniqueRegions
            .filter { $0 == region || $0.hasPrefix(prefix) }
            .flatMap { sourcesByRegion[$0] ?? [] }
    }

    func sourceURLs(inRegionTree region: String) -> [String] {
        sources(inRegionTree: region).map(\.url)
    }

    /// True only when the source itself is explicitly turned off via its own
    /// `url:<sourceURL>` key — NOT because of a parent region or category.
    /// Used by taxonomy override: a taxonomy selection should bypass inherited
    /// disables but still respect per-source opt-outs.
    /// URLs are normalized so trailing-slash, http/https, and www. variants
    /// all map to the same key.
    func isSourceExplicitlyDisabled(_ sourceURL: String) -> Bool {
        disabled.contains(Self.sourceKey(sourceURL))
    }

    /// The enablement decision as a pure function of its inputs, so the main-actor check
    /// and the off-main derivation of the filter pass's eligibility sets cannot disagree.
    /// `inCatalogue` is false only for a URL the registry does not know, which the
    /// main-actor path answers as "not enabled".
    nonisolated static func isEnabled(
        source: FeedSource,
        ownKey: String,
        inCatalogue: Bool,
        disabled: Set<String>,
        enabledOverrides: Set<String>
    ) -> Bool {
        guard inCatalogue else { return false }
        if disabled.contains(ownKey) { return false }          // explicit OFF wins
        if enabledOverrides.contains(ownKey) { return true }   // explicit ON beats a disabled parent
        if !source.defaultEnabled { return false }              // curated freshness default
        // Region/country/category disable applies to ALL source types.
        // YouTube and podcasts are not exempt — disabling a country hides
        // its local-language media alongside its text content.
        if disabled.contains(regionKey(source.region)) { return false }
        // Country check — parent of region
        let parts = source.region.split(separator: "/")
        if parts.count >= 2, parts[0] == "countries" {
            let countryKey = regionKey(parts.prefix(2).joined(separator: "/"))
            if disabled.contains(countryKey) { return false }
        }
        if disabled.contains(categoryKey(source.category)) { return false }
        return true
    }

    func isSourceEnabled(_ sourceURL: String) -> Bool {
        let normalized = OPMLParser.normalizeURL(sourceURL)
        guard let source = sourceByURL[normalized] else { return false }
        return Self.isEnabled(
            source: source,
            ownKey: Self.sourceKey(sourceURL),
            inCatalogue: true,
            disabled: disabled,
            enabledOverrides: enabledOverrides
        )
    }

    /// The two URL sets the off-main filter pass needs, as a pure function of the
    /// catalogue and the enablement state.
    ///
    /// It is `nonisolated` on purpose: callers that can suspend run it in a detached
    /// task, because the per-source URL normalisation is regex work that measured
    /// **1,599 ms** over the 77,443-source catalogue on the main actor. `sources` and
    /// `normalizedURLs` are copy-on-write, so handing them to another task costs a retain.
    nonisolated static func eligibilitySets(
        sources: [FeedSource],
        normalizedURLs: [String],
        disabled: Set<String>,
        enabledOverrides: Set<String>
    ) -> (disabled: Set<String>, explicitlyDisabled: Set<String>) {
        let prefix = "url:"
        // Explicitly disabled URL keys, read straight off `disabled` — O(|disabled|)
        // instead of one key per source.
        let explicitlyDisabledURLs = Set(disabled.compactMap { key -> String? in
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count))
        })
        var disabledURLs = Set<String>()
        for (index, source) in sources.enumerated() {
            let url = index < normalizedURLs.count
                ? normalizedURLs[index]
                : OPMLParser.normalizeURL(source.url)
            if !Self.isEnabled(
                source: source,
                ownKey: prefix + url,
                inCatalogue: true,
                disabled: disabled,
                enabledOverrides: enabledOverrides
            ) {
                disabledURLs.insert(url)
            }
        }
        return (disabledURLs, explicitlyDisabledURLs)
    }

    /// Everything the off-main eligibility computation needs, so the caller can hand it to
    /// a detached task. `sources` and `normalizedURLs` are copy-on-write.
    func eligibilityInputs() -> (
        sources: [FeedSource],
        normalizedURLs: [String],
        disabled: Set<String>,
        enabledOverrides: Set<String>
    ) {
        (sources, normalizedSourceURLs, disabled, enabledOverrides)
    }

    func lookupSnapshot() -> LookupSnapshot {
        let prefix = "url:"
        let explicitlyDisabled = Set(disabled.compactMap { key -> String? in
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count))
        })
        return LookupSnapshot(
            sourcesByNormalizedURL: sourceByURL,
            explicitlyDisabledURLs: explicitlyDisabled
        )
    }

    func source(forURL sourceURL: String) -> FeedSource? {
        sourceByURL[OPMLParser.normalizeURL(sourceURL)]
    }

    /// Materializes lazy enablement caches before returning their revisions and
    /// language counts, so callers never cache an empty pre-materialization view.
    func languageCountSnapshot() -> LanguageCountSnapshot {
        ensureActiveCounts()
        return LanguageCountSnapshot(
            sourceRevision: sourceRevision,
            enablementRevision: enablementRevision,
            enabled: enabledLanguageCounts,
            total: totalLanguageCounts
        )
    }

    // MARK: - Group status (O(1) cached)

    func status(of key: String) -> NodeStatus {
        if !disabled.contains(key) { return .on }
        // A bulk action has already changed the source decision. Returning the
        // final off state here lets every row redraw before derived counts are
        // rebuilt in the background.
        if pendingDisabledGroupKeys.contains(key) { return .off }
        ensureActiveCounts()
        let count = activeCount[key] ?? 0
        return count > 0 ? .partial(activeCount: count) : .off
    }

    func activeCount(for key: String) -> Int {
        if pendingDisabledGroupKeys.contains(key) { return 0 }
        ensureActiveCounts()
        return activeCount[key] ?? 0
    }

    // MARK: - Toggle actions

    func toggleRegion(_ region: String) {
        let key = Self.regionKey(region)
        setRegionEnabled(region, enabled: disabled.contains(key))
    }

    func setRegionEnabled(_ region: String, enabled: Bool) {
        let key = Self.regionKey(region)
        let prefix = "\(region)/"
        let affectedRegions = uniqueRegions.filter { $0 == region || $0.hasPrefix(prefix) }
        let affectedRegionKeys = Set(affectedRegions.map(Self.regionKey)).union([key])
        if enabled {
            // Enabling — cascade down to sub-regions
            disabled.subtract(affectedRegionKeys)
            pendingDisabledGroupKeys.subtract(affectedRegionKeys)
        } else {
            // Disabling — cascade down to sub-regions
            disabled.formUnion(affectedRegionKeys)
            // Disabling a group clears per-feed overrides beneath it, so the
            // whole region really goes dark.
            for source in affectedRegions.flatMap({ sourcesByRegion[$0] ?? [] }) {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
            pendingDisabledGroupKeys.formUnion(affectedRegionKeys)
        }
        invalidateActiveCounts()
        scheduleSaveState()
    }

    func toggleCategory(_ category: String) {
        setCategoryEnabled(category, enabled: disabled.contains(Self.categoryKey(category)))
    }

    func setCategoryEnabled(_ category: String, enabled: Bool) {
        let key = Self.categoryKey(category)
        if enabled {
            disabled.remove(key)
            pendingDisabledGroupKeys.remove(key)
        } else {
            disabled.insert(key)
            enabledOverrides.subtract(_sourceKeysByCategory[category] ?? [])
            pendingDisabledGroupKeys.insert(key)
        }
        invalidateActiveCounts()
        scheduleSaveState()
    }

    func toggleSource(_ sourceURL: String) {
        ensureActiveCounts()
        let key = Self.sourceKey(sourceURL)
        let wasEnabled = isSourceEnabled(sourceURL)
        if isSourceEnabled(sourceURL) {
            // Turn OFF — drop any override, mark explicitly disabled.
            enabledOverrides.remove(key)
            disabled.insert(key)
        } else {
            // Turn ON — clear an explicit off first; if a parent group still
            // disables it, record an explicit override so it shows anyway.
            disabled.remove(key)
            if !isSourceEnabled(sourceURL) {
                enabledOverrides.insert(key)
            }
        }
        let isEnabled = isSourceEnabled(sourceURL)
        if wasEnabled != isEnabled, let source = sourceByURL[OPMLParser.normalizeURL(sourceURL)] {
            applyActiveCountDelta(for: source, delta: isEnabled ? 1 : -1)
            updateEnabledSourcesCache(source: source, isEnabled: isEnabled)
            if let language = FeedStore.normalizedLanguageCode(source.language) {
                let updated = (enabledLanguageCounts[language] ?? 0) + (isEnabled ? 1 : -1)
                if updated > 0 {
                    enabledLanguageCounts[language] = updated
                } else {
                    enabledLanguageCounts.removeValue(forKey: language)
                }
            }
            if isEnabled {
                if !availableCategories.contains(source.category) {
                    availableCategories.append(source.category)
                    availableCategories.sort()
                }
            } else if activeCount[Self.categoryKey(source.category)] == nil {
                availableCategories.removeAll { $0 == source.category }
            }
            enablementRevision &+= 1
        }
        scheduleSaveState()
    }

    /// Enable or disable all topic regions in a single batch — one recompute,
    /// one UserDefaults write, instead of N per-region toggles.
    func setTopicRegionsEnabled(_ enabled: Bool) {
        let topicKeys = allTopicRegions.map { Self.regionKey($0) }
        if enabled {
            disabled.subtract(topicKeys)
            pendingDisabledGroupKeys.subtract(topicKeys)
        } else {
            disabled.formUnion(topicKeys)
            // Clear per-feed overrides for all topic sources so the group
            // disable takes full effect.
            enabledOverrides.subtract(topicSourceKeys)
            pendingDisabledGroupKeys.formUnion(topicKeys)
        }
        // Also toggle legacy "global" region
        let globalKey = Self.regionKey("global")
        if enabled {
            disabled.remove(globalKey)
            pendingDisabledGroupKeys.remove(globalKey)
        } else {
            disabled.insert(globalKey)
            enabledOverrides.subtract(Set((sourcesByRegion["global"] ?? []).map { Self.sourceKey($0.url) }))
            pendingDisabledGroupKeys.insert(globalKey)
        }
        invalidateActiveCounts()
        scheduleSaveState()
    }

    /// Resets all per-source toggles: clears both disabled set and override set.
    func resetAllToggles() {
        disabled.removeAll()
        enabledOverrides.removeAll()
        // `ensureActiveCounts()` alone no-ops while `activeCountsAreCurrent` is
        // already true — the common state right after a previous change settled —
        // which would leave `_enabledSources`, the counts and `enablementRevision`
        // describing the authority from *before* the reset. Invalidate first so the
        // recompute below actually runs and publishes a revision that matches the
        // cleared sets.
        invalidateActiveCounts()
        ensureActiveCounts()
        scheduleSaveState()
    }

    func toggleAllCountries() {
        setAllCountriesEnabled(!isAnyCountryEnabled)
    }

    func setAllCountriesEnabled(_ enabled: Bool) {
        let countryKeys = countryRegionKeys
        if enabled {
            disabled.subtract(countryKeys)
            pendingDisabledGroupKeys.subtract(countryKeys)
        } else {
            disabled.formUnion(countryKeys)
            enabledOverrides.subtract(countrySourceKeys)
            pendingDisabledGroupKeys.formUnion(countryKeys)
        }
        invalidateActiveCounts()
        scheduleSaveState()
    }

    var isAnyCountryEnabled: Bool {
        countryRegionKeys.contains { !disabled.contains($0) }
            || !enabledOverrides.isDisjoint(with: countrySourceKeys)
    }

    // MARK: - Enabled sources

    var enabledSources: [FeedSource] {
        if let cached = _enabledSources { return cached }
        recomputeActiveCounts()
        return _enabledSources ?? []
    }

    var sourceCount: Int { sources.count }

    // MARK: - Cache

    private func ensureActiveCounts() {
        guard !activeCountsAreCurrent else { return }
        recomputeActiveCounts()
    }

    private func recomputeActiveCounts() {
        activeCount.removeAll()
        var enabled: [FeedSource] = []
        var languageCounts: [String: Int] = [:]
        var categories = Set<String>()
        enabled.reserveCapacity(sources.count)
        for source in sources where isSourceEnabled(source.url) {
            enabled.append(source)
            categories.insert(source.category)
            if let language = FeedStore.normalizedLanguageCode(source.language) {
                languageCounts[language, default: 0] += 1
            }
            applyActiveCountDelta(for: source, delta: 1)
        }
        _enabledSources = enabled
        enabledLanguageCounts = languageCounts
        availableCategories = categories.sorted()
        activeCountsAreCurrent = true
        pendingDisabledGroupKeys.removeAll()
        enablementRevision &+= 1
    }

    private func invalidateActiveCounts() {
        _enabledSources = nil
        activeCountsAreCurrent = false
        activeCountsGeneration &+= 1
        // NOTE: `enablementRevision` is deliberately NOT bumped here. It is bumped by
        // `recomputeActiveCounts()`, which publishes it together with the counts it
        // describes — and `LanguageCountSnapshot` hands both to callers. Bumping here
        // would advertise a new revision while `enabledLanguageCounts`/`availableCategories`
        // still hold the previous values, and a consumer pairing the two would read a
        // mixture. Callers that need an immediately-valid signal (the filter pass's
        // eligibility snapshot) compare the registry's own `disabled`/`enabledOverrides`
        // sets instead — that cannot lag, because it is the state itself.
        let generation = activeCountsGeneration
        // Coalesce rapid changes so the switch and haptic render immediately.
        // The full cached count rebuild is delayed until the user pauses.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, generation == self.activeCountsGeneration else { return }
            self.recomputeActiveCounts()
        }
    }

    private func applyActiveCountDelta(for source: FeedSource, delta: Int) {
        for key in activeCountKeys(for: source) {
            let updated = (activeCount[key] ?? 0) + delta
            if updated > 0 {
                activeCount[key] = updated
            } else {
                activeCount.removeValue(forKey: key)
            }
        }
    }

    private func activeCountKeys(for source: FeedSource) -> [String] {
        var keys = [Self.regionKey(source.region), Self.categoryKey(source.category)]
        let parts = source.region.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "countries" {
            // A source whose own region *is* the country (e.g. `countries/brazil`)
            // derives the same key twice; the delta must land once per key or the
            // country's active count depends on how deep the classification is.
            let countryKey = Self.regionKey(parts.prefix(2).joined(separator: "/"))
            if countryKey != keys[0] {
                keys.append(countryKey)
            }
        }
        return keys
    }

    private func updateEnabledSourcesCache(source: FeedSource, isEnabled: Bool) {
        guard var enabledSources = _enabledSources else { return }
        let normalizedURL = OPMLParser.normalizeURL(source.url)
        if isEnabled {
            guard !enabledSources.contains(where: { OPMLParser.normalizeURL($0.url) == normalizedURL }) else { return }
            enabledSources.append(source)
        } else {
            enabledSources.removeAll { OPMLParser.normalizeURL($0.url) == normalizedURL }
        }
        _enabledSources = enabledSources
    }

    // MARK: - Persistence

    private func saveState() {
        UserDefaults.standard.set(Array(disabled), forKey: Keys.toggleDisabled)
        UserDefaults.standard.set(Array(enabledOverrides), forKey: Keys.toggleEnabledOverrides)
    }

    private func scheduleSaveState() {
        saveStateTask?.cancel()
        saveStateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.saveState()
        }
    }

    func loadState() {
        if let arr = UserDefaults.standard.stringArray(forKey: Keys.toggleDisabled) {
            // Normalize legacy keys: old code stored raw URLs; new code uses
            // OPMLParser.normalizeURL. Re-create each key so trailing-slash,
            // http/https, and www. variants converge.
            disabled = Set(arr.map { key in
                if key.hasPrefix("url:") {
                    let raw = String(key.dropFirst(4))
                    return Self.sourceKey(raw)
                }
                if key.hasPrefix("cat:") || key.hasPrefix("region:") {
                    return key
                }
                // Legacy key: old code stored raw URLs without the "url:" prefix.
                return Self.sourceKey(key)
            })
        }
        if let arr = UserDefaults.standard.stringArray(forKey: "toggleEnabledOverrides") {
            enabledOverrides = Set(arr.map { key in
                if key.hasPrefix("url:") {
                    let raw = String(key.dropFirst(4))
                    return Self.sourceKey(raw)
                }
                if key.hasPrefix("cat:") || key.hasPrefix("region:") {
                    return key
                }
                // Legacy key: old code stored raw URLs without the "url:" prefix.
                return Self.sourceKey(key)
            })
        }
        recomputeActiveCounts()
    }

    // MARK: - Region lookup

    @ObservationIgnored private var _regionMap: [String: String]?
    var regionMap: [String: String] {
        if let cached = _regionMap { return cached }
        // Key by normalized URL so lookups match whether callers pass the
        // raw or the normalized form of a feed URL.
        let map = Dictionary(sources.map { (OPMLParser.normalizeURL($0.url), $0.region) }, uniquingKeysWith: { first, _ in first })
        _regionMap = map
        return map
    }

    func regionFor(sourceURL: String) -> String {
        regionMap[OPMLParser.normalizeURL(sourceURL)] ?? "global"
    }

    // MARK: - Language lookup

    @ObservationIgnored private var _languageMap: [String: String?]?
    var languageMap: [String: String?] {
        if let cached = _languageMap { return cached }
        // Key by normalized URL, mirroring regionMap above.
        let map = Dictionary(sources.map { (OPMLParser.normalizeURL($0.url), $0.language) }, uniquingKeysWith: { first, _ in first })
        _languageMap = map
        return map
    }

    func languageFor(sourceURL: String) -> String? {
        languageMap[OPMLParser.normalizeURL(sourceURL)] ?? nil
    }

    // MARK: - Topic regions

    /// All topic-based regions (non-country, non-imported, non-global).
    /// Used by Global Feeds toggle to batch-enable/disable all topic groups.
    var allTopicRegions: [String] {
        if let cached = _allTopicRegions { return cached }
        let regions = Set(sources.map(\.region))
        let topicRegions = regions
            .filter { $0.hasPrefix("topic/") }
            .sorted()
        _allTopicRegions = topicRegions
        return topicRegions
    }

    // MARK: - Countries

    var availableCountries: [Country] {
        if let cached = _availableCountries { return cached }
        let grouped = Dictionary(grouping: sources, by: \.region)
        let countryRegions = grouped.keys.filter { key in
            guard key.hasPrefix("countries/") else { return false }
            let remainder = key.replacingOccurrences(of: "countries/", with: "")
            return !remainder.contains("/")
        }
        let countries = countryRegions.compactMap { region -> Country? in
            let slug = region.replacingOccurrences(of: "countries/", with: "")
            let countryFeeds = grouped[region] ?? []
            let regionPrefix = "\(region)/"
            let subRegions = grouped
                .filter { $0.key.hasPrefix(regionPrefix) }
                .compactMap { subRegionPath, feeds -> Region? in
                    let regionSlug = subRegionPath.replacingOccurrences(of: regionPrefix, with: "")
                    guard !regionSlug.isEmpty else { return nil }
                    return Region(
                        path: subRegionPath,
                        countrySlug: slug,
                        slug: regionSlug,
                        name: regionSlug.replacingOccurrences(of: "-", with: " ").capitalized,
                        feedCount: feeds.count,
                        categories: Array(Set(feeds.map(\.category))).sorted()
                    )
                }
                .sorted { $0.name < $1.name }
            return Country(
                region: region,
                name: CountryStore.countryName(for: slug),
                flag: CountryStore.countryFlag(for: slug),
                feedCount: countryFeeds.count,
                categories: Array(Set(countryFeeds.map(\.category))).sorted(),
                regions: subRegions
            )
        }
        .sorted { $0.name < $1.name }
        _availableCountries = countries
        return countries
    }

    /// Materialize every derived model used by the filter sheet while the
    /// catalog is already in its loading phase. Reads during interaction are
    /// then dictionary/array lookups only.
    func prepareFilterCaches() {
        ensureActiveCounts()
        _ = allTopicRegions
        _ = availableCountries
    }

    // MARK: - Load

    func loadFromOPML() async {
        let result = await OPMLParser.parseAll()
        // The derived caches are a pure function of the parsed sources, and over
        // 77,443 entries they used to cost ~6.5 s on the main actor right after
        // the first page painted — the app looked ready and ignored taps for the
        // rest of startup. Derive them off the main actor and hand them to the
        // `sources` assignment, which installs them without recomputing.
        let parsedSources = result.sources
        let parsedSharedURLs = result.sharedCountrySourceURLs
        let deriveStarted = ContinuousClock().now
        let prepared = await Task.detached(priority: .userInitiated) {
            SourceRegistry.deriveCaches(
                from: parsedSources,
                sharedCountrySourceURLs: parsedSharedURLs
            )
        }.value
        let deriveElapsed = ContinuousClock().now - deriveStarted
        let deriveMs = Int(deriveElapsed.components.seconds * 1_000
            + deriveElapsed.components.attoseconds / 1_000_000_000_000_000)
        preparedCaches = prepared
        // This block is the prime suspect for the ~8,6 s that `OPML.load` spends *after* its cache read. It is
        // separated here because "I/O under a full volume" does not only show up in a file read: decoding and
        // deriving 77 443 objects allocates heavily and can spend its time in VM/page faults, which looks like
        // slow CPU. Measured beside `[PerfEnv] freeImportant=…` this line says which one it was.
        Log.feed.info("[PerfEnv] deriveCaches sources=\(parsedSources.count) ms=\(deriveMs)")
        sources = result.sources   // didSet installs the prepared caches
        opmlFileCount = result.fileCount
        opmlErrorCount = result.failedFileCount
        invalidSourceCount = result.invalidSourceCount
        duplicateSourceCount = result.duplicateSourceCount

        // Restore persisted toggle state
        loadState()

        // Countries off by default on first launch only.
        if !Settings.hasInitializedSourceDefaults {
            for source in sources where source.isCountryFeed {
                disabled.insert(Self.regionKey(source.region))
            }
            saveState()
            Settings.hasInitializedSourceDefaults = true
            // Only this branch needs a second pass: it changes `disabled` *after* `loadState()` already
            // published its counts, and publishing a stale count is a real defect (a source reads "off"
            // while the list says on). On every other launch the call here was a full walk of 77 443 sources
            // for nothing — `loadState()` ends in exactly this call, and it leaves
            // `activeCountsAreCurrent == true`.
            recomputeActiveCounts()
        }

        // `prepareFilterCaches()` warms the filter caches and calls `ensureActiveCounts()`, which is a
        // no-op when the counts are already current.
        prepareFilterCaches()
    }
}
