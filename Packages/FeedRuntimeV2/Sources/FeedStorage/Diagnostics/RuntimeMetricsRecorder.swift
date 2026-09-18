import Foundation

/// One measured operation (plan §16): an operation ID, the edition and epoch it ran under, how long it
/// took and how it ended.
///
/// There is deliberately no URL and no payload field. §16 asks for instrumentation "by operation
/// ID/edition/epoch, without sensitive URLs", and the cheapest way to keep that promise is for the
/// sample type to have nowhere to put one.
public struct OperationSample: Hashable, Sendable {
    public let operation: RuntimeOperation
    /// Opaque identifier of the operation instance: a batch ID, an operation ID, a run ID.
    public let operationID: String
    public let editionID: Int64?
    public let epoch: Int64?
    public let durationMilliseconds: Double
    /// How the operation ended, as a kind name (`admitted`, `duplicate`, `published`, `refused`, …).
    public let outcome: String

    public init(
        operation: RuntimeOperation,
        operationID: String,
        editionID: Int64? = nil,
        epoch: Int64? = nil,
        durationMilliseconds: Double,
        outcome: String
    ) {
        self.operation = operation
        self.operationID = operationID
        self.editionID = editionID
        self.epoch = epoch
        self.durationMilliseconds = durationMilliseconds
        self.outcome = outcome
    }
}

/// The operations §16 names that this package actually performs. The list is intentionally short: an
/// operation nobody performs is a name for a future slice, not instrumentation.
public enum RuntimeOperation: String, Hashable, Sendable, CaseIterable {
    case admission
    case selectionQuery = "selection_query"
    case publicationCommit = "publication_commit"
    case restore
    case retentionRun = "retention_run"
}

/// The counters §16 requires, as events rather than as fields, so a caller can only add to the ones
/// that exist.
///
/// Two counters §16 names are deliberately absent, because this package does not produce them: a
/// **shadow drop** is the app's parity lane (`ShadowComparator`'s own accounting) and a **rollback** is
/// a launch-mode flip, whose observation is `RuntimeMode`'s resolution plus the engine counts in
/// baseline §8.13.1. A counter nobody increments would read as a measure that is always zero.
///
/// The warm/cold split §16 asks for is not a counter either: it is `StartupReport.classification`, one
/// value per launch, because that is the unit the distribution is computed over.
public enum RuntimeCounterEvent: String, Hashable, Sendable, CaseIterable {
    /// A batch that was already admitted: zero canonical mutation, zero supply increment.
    case noOpBatch = "no_op_batch"
    /// A refusal because the target, the checkpoint or the lease had moved on.
    case staleRejection = "stale_rejection"
    /// Any other admission refusal, including the audited conflicts.
    case admissionRefusal = "admission_refusal"
    /// A publication commit that was attempted again after a storage failure.
    case publicationRetry = "publication_retry"
    /// A temporary asset file an interrupted commit left behind, reclaimed by GC.
    case orphanAssetCollected = "orphan_asset_collected"
    case gcRun = "gc_run"
}

/// How one operation behaved, over every sample of it.
public struct OperationSummary: Hashable, Sendable {
    public let operation: RuntimeOperation
    public let count: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let maxMilliseconds: Double
    /// The outcomes seen, with how often each occurred. Counts only, never content.
    public let outcomes: [String: Int]

    /// Nearest-rank percentiles over the samples, which is the definition this report uses everywhere:
    /// the p95 is a measurement that occurred, not an interpolation between two that did.
    static func summarize(_ operation: RuntimeOperation, _ samples: [OperationSample]) -> OperationSummary? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.durationMilliseconds).sorted()
        var outcomes: [String: Int] = [:]
        for sample in samples { outcomes[sample.outcome, default: 0] += 1 }
        return OperationSummary(
            operation: operation,
            count: sorted.count,
            p50Milliseconds: Self.percentile(sorted, 0.50),
            p95Milliseconds: Self.percentile(sorted, 0.95),
            maxMilliseconds: sorted[sorted.count - 1],
            outcomes: outcomes
        )
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

/// What one run measured, with the world it was measured in.
///
/// `world` is not decoration: §16's numbers are initial targets, and a measurement without the device,
/// build configuration and dataset beside it cannot be compared with anything (baseline §8.17.1).
public struct RunMetricsReport: Hashable, Sendable {
    public let world: String
    public let counters: [String: Int]
    public let operations: [OperationSummary]

    public static func summarizing(
        world: String,
        samples: [OperationSample],
        counters: [RuntimeCounterEvent: Int]
    ) -> RunMetricsReport {
        var byOperation: [RuntimeOperation: [OperationSample]] = [:]
        for sample in samples { byOperation[sample.operation, default: []].append(sample) }
        return RunMetricsReport(
            world: world,
            counters: Dictionary(
                uniqueKeysWithValues: counters.map { ($0.key.rawValue, $0.value) }
            ),
            operations: RuntimeOperation.allCases.compactMap { operation in
                byOperation[operation].flatMap { OperationSummary.summarize(operation, $0) }
            }
        )
    }

    public func summary(for operation: RuntimeOperation) -> OperationSummary? {
        operations.first { $0.operation == operation }
    }

    public func count(of event: RuntimeCounterEvent) -> Int {
        counters[event.rawValue] ?? 0
    }

    /// Stable text, one line per measure. Counts and durations only: there is no field for a URL, and
    /// this is what a report copies from.
    public func serialized() -> String {
        var lines = ["world=\(world)"]
        for operation in operations {
            lines.append(
                "\(operation.operation.rawValue) n=\(operation.count) "
                    + "p50=\(String(format: "%.3f", operation.p50Milliseconds))ms "
                    + "p95=\(String(format: "%.3f", operation.p95Milliseconds))ms "
                    + "max=\(String(format: "%.3f", operation.maxMilliseconds))ms "
                    + "outcomes=\(operation.outcomes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
            )
        }
        for name in counters.keys.sorted() {
            lines.append("\(name)=\(counters[name] ?? 0)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Collects the samples and counters of one run.
///
/// An actor because it is written from several places at once (admission, selection, publication, GC)
/// and read by a report; the alternative shapes are a lock in a `Sendable` box or a global, and both
/// hide the sharing instead of stating it.
public actor RuntimeMetricsRecorder {
    private var samples: [OperationSample] = []
    private var counters: [RuntimeCounterEvent: Int] = [:]

    public init() {}

    public func record(_ sample: OperationSample) {
        samples.append(sample)
    }

    public func count(_ event: RuntimeCounterEvent, by amount: Int = 1) {
        counters[event, default: 0] += amount
    }

    /// Times `body` and records it as one sample of `operation`, whatever it returns or throws.
    public func measure<T>(
        _ operation: RuntimeOperation,
        operationID: String,
        editionID: Int64? = nil,
        epoch: Int64? = nil,
        outcome: @Sendable (T) -> String,
        _ body: () throws -> T
    ) rethrows -> T {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let result = try body()
            let elapsed = Double(ProcessInfo.processInfo.systemUptime - started) * 1_000
            samples.append(
                OperationSample(
                    operation: operation,
                    operationID: operationID,
                    editionID: editionID,
                    epoch: epoch,
                    durationMilliseconds: elapsed,
                    outcome: outcome(result)
                )
            )
            return result
        } catch {
            let elapsed = Double(ProcessInfo.processInfo.systemUptime - started) * 1_000
            samples.append(
                OperationSample(
                    operation: operation,
                    operationID: operationID,
                    editionID: editionID,
                    epoch: epoch,
                    durationMilliseconds: elapsed,
                    outcome: "threw"
                )
            )
            throw error
        }
    }

    public func report(world: String) -> RunMetricsReport {
        RunMetricsReport.summarizing(world: world, samples: samples, counters: counters)
    }
}
