import Foundation

/// Owns the final editorial order — the one place where the sequence the reader sees is decided.
///
/// The Reservoir already interleaves providers, countries and freshness, and `CardPreparationPipeline` preserves that
/// order verbatim ("same order as the input array so the reservoir's diversity order [holds]"). Neither is an invariant of
/// what gets *published*: filters, reloads, appends, balancing and context changes all sit between them, so any one of
/// them can hand the reader five consecutive cards from the same provider — the release review's "Gato Galáctico" case.
///
/// This type repairs that sequence and is the only place the policy lives. Callers hand it candidates and publish what it
/// returns; they do not sort, group or re-balance for diversity themselves.
///
/// The repair is deliberately conservative: it is a *stable* pass that only pulls an item forward when a run has to be
/// broken, so the Reservoir's editorial intent (what should lead) survives. When no alternative provider remains further
/// down the list, a run is left alone — the rule is "no repetition while there are alternatives", never "manufacture
/// diversity that the candidate set cannot supply".
enum EditorialSequencer {

    /// How many times one provider may appear in a row while another provider still has candidates later in the list.
    static let maxConsecutivePerProvider = 1

    /// The provider identity used for the rule: the *same* one the Reservoir interleaves and front-loads by
    /// (`Reservoir.providerKey`), which resolves the publisher behind a URL — generated aggregator feeds
    /// included.
    ///
    /// It used to be a normalized URL here and an aggregator-aware key there. Two identities for one concept
    /// means a candidate set can satisfy the limit in one layer and violate it in the other, because the
    /// layers disagree about who the provider is (S15). There is one definition, in `Reservoir`, and every
    /// policy that ranks by provider resolves through it.
    static func providerKey(_ item: FeedItem) -> String {
        Reservoir.providerKey(item)
    }

    /// The sequence to publish: `items`, spread across providers so that no provider appears twice in a row while another
    /// provider still has candidates.
    ///
    /// The rule is **least-used round-robin**: each step takes the provider that has given the fewest items so far,
    /// tie-broken by whose next unused item came earliest in the input, and never the provider taken immediately before
    /// while any other provider still has candidates. Within one provider the input order is preserved, so the Reservoir's
    /// within-provider intent survives; across providers the sequence is rebuilt, which is the point — a first page of
    /// twenty cards must carry every provider that has candidates.
    ///
    /// Two rules that looked reasonable both failed this, and their failures are the reason for the one above:
    ///   * pulling the *nearest* different provider forward alternates only the first two providers (measured:
    ///     `leadingProviderCount(…, 20) == 2` for four providers);
    ///   * preferring the provider whose *next item came earliest* reproduces the input's clustering for the same reason —
    ///     the providers further down never catch up while the first two still have items at lower indices.
    static func sequence(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 2 else { return items }

        var buckets: [String: [(index: Int, item: FeedItem)]] = [:]
        var providerOrder: [String] = []
        for (index, item) in items.enumerated() {
            let key = providerKey(item)
            if buckets[key] == nil { providerOrder.append(key) }
            buckets[key, default: []].append((index, item))
        }

        var output: [FeedItem] = []
        output.reserveCapacity(items.count)
        // Cursors instead of `removeFirst()`: that is O(n) per step, and this runs over hundreds of candidates on every
        // composition. Counting per provider is what makes the rotation fair.
        var cursor = [String: Int](minimumCapacity: providerOrder.count)
        var taken = [String: Int](minimumCapacity: providerOrder.count)
        var lastProvider: String?

        while output.count < items.count {
            var best: String?
            var bestTaken = Int.max
            var bestIndex = Int.max
            for key in providerOrder {
                let position = cursor[key] ?? 0
                guard let entries = buckets[key], position < entries.count else { continue }
                if key == lastProvider,
                   providerOrder.contains(where: { other in
                       other != key && (cursor[other] ?? 0) < (buckets[other]?.count ?? 0)
                   }) {
                    continue
                }
                let used = taken[key] ?? 0
                if used < bestTaken || (used == bestTaken && entries[position].index < bestIndex) {
                    best = key
                    bestTaken = used
                    bestIndex = entries[position].index
                }
            }
            guard let chosen = best else { break }  // unreachable: `best` is nil only when every bucket is exhausted
            let position = cursor[chosen] ?? 0
            output.append(buckets[chosen]![position].item)
            cursor[chosen] = position + 1
            taken[chosen] = (taken[chosen] ?? 0) + 1
            lastProvider = chosen
        }
        return output
    }

    /// Runs of one provider that survived even though a different provider existed later in the list.
    ///
    /// Empty means the invariant holds. This is what the pipeline boundary asserts and what the tests read: it is
    /// computed from the sequence itself, not from the sequencer's intent.
    static func consecutiveRunIssues(in items: [FeedItem]) -> [String] {
        var issues: [String] = []
        var index = 1
        while index < items.count {
            let provider = providerKey(items[index])
            guard provider == providerKey(items[index - 1]) else { index += 1; continue }
            var runEnd = index
            while runEnd + 1 < items.count, providerKey(items[runEnd + 1]) == provider { runEnd += 1 }
            let runLength = runEnd - index + 2
            if runLength > maxConsecutivePerProvider,
               items[(runEnd + 1)...].contains(where: { providerKey($0) != provider }) {
                issues.append("\(runLength)×\(provider) at \(index - 1) with alternatives later")
            }
            index = runEnd + 1
        }
        return issues
    }

    /// Whether `items` satisfies the published-order invariant.
    static func isDiversityRespected(_ items: [FeedItem]) -> Bool {
        consecutiveRunIssues(in: items).isEmpty
    }

    /// Distinct providers in the first `count` items — the breadth a first page actually delivers.
    static func leadingProviderCount(_ items: [FeedItem], count: Int = Reservoir.pageSize) -> Int {
        Set(items.prefix(count).map(providerKey)).count
    }
}
