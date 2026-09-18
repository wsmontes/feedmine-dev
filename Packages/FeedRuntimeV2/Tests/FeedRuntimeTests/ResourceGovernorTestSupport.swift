import FeedDomain
import FeedRuntime
import Foundation
import XCTest

/// A clock that never moves, so a governor test states instants instead of waiting for them.
struct GovernorClock: EditorialClock {
    let now: Date
}

enum GovernorInstant {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
}

/// A stand-in for the media caches: it scripts what each handler releases and records every call, so
/// a test can prove *which* classes a pressure application asked for.
actor PressureSpy {
    private(set) var discardCalls = 0
    private(set) var trimCalls = 0
    private(set) var collectionCalls = 0
    private(set) var collectionInstants: [Date] = []
    private var discardReleases: [Int]
    private var trimReleases: [Int]
    private var collectionReleases: [Int]

    /// Each list is consumed one call at a time; the last value repeats once the script runs out.
    init(discardReleases: [Int] = [], trimReleases: [Int] = [], collectionReleases: [Int] = []) {
        self.discardReleases = discardReleases
        self.trimReleases = trimReleases
        self.collectionReleases = collectionReleases
    }

    func makeHandlers() -> MediaCachePressureHandlers {
        MediaCachePressureHandlers(
            discardDecodedMaterial: { [weak self] in await self?.discard() ?? 0 },
            trimUnpublishedDownloads: { [weak self] in await self?.trim() ?? 0 },
            runRetentionCollection: { [weak self] now in await self?.collect(asOf: now) ?? 0 }
        )
    }

    private func discard() -> Int {
        discardCalls += 1
        return next(&discardReleases)
    }

    private func trim() -> Int {
        trimCalls += 1
        return next(&trimReleases)
    }

    private func collect(asOf now: Date) -> Int {
        collectionCalls += 1
        collectionInstants.append(now)
        return next(&collectionReleases)
    }

    private func next(_ script: inout [Int]) -> Int {
        guard script.count > 1 else { return script.first ?? 0 }
        return script.removeFirst()
    }
}

/// Counts how many bodies are inside a section at the same time, and can hold them open so a test
/// observes the live concurrency instead of guessing at it.
actor ConcurrencyProbe {
    private(set) var peak = 0
    private(set) var active = 0
    private var entered = 0
    private var entryWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false

    func enter() {
        active += 1
        entered += 1
        peak = max(peak, active)
        let satisfied = entryWaiters.filter { entered >= $0.threshold }
        entryWaiters.removeAll { entered >= $0.threshold }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    func leave() {
        active -= 1
    }

    /// Holds every body that reaches `wait()` until `release()`.
    func hold() { holding = true }

    func release() {
        holding = false
        let pending = held
        held = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        let shouldHold = holding
        guard shouldHold else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            held.append(continuation)
        }
    }

    /// Waits until at least `count` bodies have entered, without polling or sleeping.
    func waitUntilEntered(_ count: Int) async {
        guard entered < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            entryWaiters.append((count, continuation))
        }
    }

    var peakConcurrency: Int { peak }
    var activeCount: Int { active }
}

/// A speculative body that honours cancellation the way a real prefetch must: it suspends until it
/// is cancelled, then records that it observed the cancellation.
actor CancellationProbe {
    private(set) var cancellationsObserved = 0
    private var cancelled = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func run() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if cancelled {
                    continuation.resume()
                } else {
                    held.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
        cancellationsObserved += 1
    }

    private func observeCancellation() {
        cancelled = true
        let pending = held
        held = []
        for waiter in pending { waiter.resume() }
    }
}

// MARK: - Awaited expectations

// `XCTAssert*` takes its operands as autoclosures, and an autoclosure cannot await. Awaited
// observations are bound and asserted through these instead, which keeps the assertion readable.

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual, expected, message, file: file, line: line)
}

func expectTrue(
    _ actual: Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(actual, message, file: file, line: line)
}

func expectFalse(
    _ actual: Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(actual, message, file: file, line: line)
}

func expectNil<T>(
    _ actual: T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNil(actual, message, file: file, line: line)
}

func expectNotNil<T>(
    _ actual: T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNotNil(actual, message, file: file, line: line)
}
