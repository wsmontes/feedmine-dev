import FeedDomain
import Foundation
import XCTest
import FeedRuntime

/// The minimal resource governor: bounded media work, and the two pressure applications the app will
/// drive from the memory-warning and maintenance paths (plan §14 PR-08).
final class ResourceGovernorTests: XCTestCase {
    private let clock = GovernorClock(now: GovernorInstant.epoch)

    private func limits(
        downloads: Int = 4,
        decodes: Int = 3,
        pressureDownloads: Int = 1,
        pressureDecodes: Int = 1,
        diskBudgetBytes: Int = 1_000
    ) -> ResourceLimits {
        ResourceLimits(
            downloadConcurrency: downloads,
            decodeConcurrency: decodes,
            pressureDownloadConcurrency: pressureDownloads,
            pressureDecodeConcurrency: pressureDecodes,
            diskBudgetBytes: diskBudgetBytes
        )
    }

    // MARK: bounded concurrency

    func testDownloadConcurrencyIsBounded() async {
        let governor = ResourceGovernor(limits: limits(downloads: 4), clock: clock)
        let probe = ConcurrencyProbe()
        await probe.hold()

        let tasks = (0 ..< 8).map { _ in
            Task {
                try await governor.withDownloadPermit {
                    await probe.enter()
                    await probe.wait()
                    await probe.leave()
                }
            }
        }
        await probe.waitUntilEntered(4)

        await expectEqual(probe.activeCount, 4, "exactly the permit count is inside")
        await expectEqual(probe.peakConcurrency, 4)

        await probe.release()
        for task in tasks { _ = try? await task.value }

        await expectEqual(probe.peakConcurrency, 4, "the bound held for the whole batch")
        await expectEqual(governor.downloadsInFlight, 0, "every permit came back")
    }

    func testDecodeConcurrencyIsBoundedIndependentlyOfDownloads() async {
        let governor = ResourceGovernor(limits: limits(downloads: 8, decodes: 2), clock: clock)
        let probe = ConcurrencyProbe()
        await probe.hold()

        let tasks = (0 ..< 6).map { _ in
            Task {
                try await governor.withDecodePermit {
                    await probe.enter()
                    await probe.wait()
                    await probe.leave()
                }
            }
        }
        await probe.waitUntilEntered(2)

        await expectEqual(probe.activeCount, 2)
        await expectEqual(governor.downloadsInFlight, 0, "decodes do not consume download permits")

        await probe.release()
        for task in tasks { _ = try? await task.value }
        await expectEqual(probe.peakConcurrency, 2)
        await expectEqual(governor.decodesInFlight, 0)
    }

    func testAFailingBodyStillReturnsItsPermit() async {
        let governor = ResourceGovernor(limits: limits(downloads: 1), clock: clock)

        struct Boom: Error {}
        let error = await awaitFailure {
            try await governor.withDownloadPermit { throw Boom() }
        }

        XCTAssertNotNil(error)
        await expectEqual(governor.downloadsInFlight, 0)

        // The permit came back, so the next body runs instead of waiting forever.
        do {
            try await governor.withDownloadPermit {}
        } catch {
            XCTFail("the permit was not returned: \(error)")
        }
        await expectEqual(governor.downloadsInFlight, 0)
    }

    // MARK: memory pressure

    func testMemoryPressureTrimsOnlyTheEvictableClassesAndLowersConcurrency() async {
        let spy = PressureSpy(discardReleases: [4_096], trimReleases: [2_048], collectionReleases: [1])
        let governor = ResourceGovernor(limits: limits(downloads: 4, decodes: 3), clock: clock, mediaCache: await spy.makeHandlers())

        let outcome = await governor.applyMemoryPressure()

        XCTAssertEqual(outcome.pressure, .memory)
        XCTAssertEqual(outcome.discardedDecodedBytes, 4_096)
        XCTAssertEqual(outcome.trimmedUnpublishedBytes, 2_048)
        XCTAssertEqual(outcome.freedBytes, 6_144)
        XCTAssertEqual(outcome.downloadConcurrency, 1)
        XCTAssertEqual(outcome.decodeConcurrency, 1)
        await expectEqual(governor.downloadConcurrency, 1)
        await expectEqual(governor.decodeConcurrency, 1)
        await expectEqual(spy.collectionCalls, 0, "memory pressure never runs collection")
        await expectEqual(spy.discardCalls, 1)
        await expectEqual(spy.trimCalls, 1)
    }

    func testTheLoweredBoundAppliesToNewWorkAndIsRestoredAfterwards() async {
        let governor = ResourceGovernor(limits: limits(downloads: 4), clock: clock)
        _ = await governor.applyMemoryPressure()

        let probe = ConcurrencyProbe()
        await probe.hold()
        let tasks = (0 ..< 4).map { _ in
            Task {
                try await governor.withDownloadPermit {
                    await probe.enter()
                    await probe.wait()
                    await probe.leave()
                }
            }
        }
        await probe.waitUntilEntered(1)

        await expectEqual(probe.activeCount, 1, "the pressure bound is one")

        await probe.release()
        await governor.endMemoryPressure()
        for task in tasks { _ = try? await task.value }

        await expectEqual(governor.downloadConcurrency, 4, "the configured bound is back")
        await expectFalse(governor.isUnderPressure)
    }

    func testLoweringTheBoundDoesNotStrandQueuedWork() async {
        let governor = ResourceGovernor(limits: limits(downloads: 4), clock: clock)
        let probe = ConcurrencyProbe()
        await probe.hold()
        let tasks = (0 ..< 4).map { _ in
            Task {
                try await governor.withDownloadPermit {
                    await probe.enter()
                    await probe.wait()
                    await probe.leave()
                }
            }
        }
        await probe.waitUntilEntered(4)

        // Four are inside; the warning lowers the bound to one. They must all still finish.
        _ = await governor.applyMemoryPressure()
        await probe.release()
        for task in tasks { _ = try? await task.value }

        await expectEqual(probe.activeCount, 0)
        await expectEqual(governor.downloadsInFlight, 0)
    }

    // MARK: speculative work

    func testMemoryPressureCancelsSpeculativeWork() async {
        let governor = ResourceGovernor(limits: limits(), clock: clock)
        let probe = CancellationProbe()
        _ = await governor.startSpeculative { await probe.run() }
        _ = await governor.startSpeculative { await probe.run() }
        await expectEqual(governor.speculativeWorkCount, 2)

        let outcome = await governor.applyMemoryPressure()

        XCTAssertEqual(outcome.cancelledSpeculativeWork, 2)
        await expectEqual(governor.speculativeWorkCount, 0)
        await expectEqual(probe.cancellationsObserved, 2, "the bodies observed the cancellation")
    }

    func testSpeculativeWorkThatFinishesOnItsOwnIsNoLongerInFlight() async {
        let governor = ResourceGovernor(limits: limits(), clock: clock)
        _ = await governor.startSpeculative {}
        for _ in 0 ..< 10_000 {
            if await governor.speculativeWorkCount == 0 { break }
            await Task.yield()
        }

        await expectEqual(governor.speculativeWorkCount, 0)
        await expectEqual(governor.cancelSpeculativeWork(), 0)
    }

    // MARK: disk budget

    func testDiskPressureCollectsUnpinnedEntriesUntilTheBudgetIsMet() async {
        let spy = PressureSpy(trimReleases: [0], collectionReleases: [300, 100, 0])
        let governor = ResourceGovernor(
            limits: limits(diskBudgetBytes: 400),
            clock: clock,
            mediaCache: await spy.makeHandlers()
        )

        let outcome = await governor.enforceDiskBudget(usedBytes: 1_000)

        XCTAssertEqual(outcome.pressure, .disk)
        XCTAssertEqual(outcome.collectedBytes, 400)
        XCTAssertEqual(outcome.freedBytes, 400)
        await expectEqual(spy.collectionCalls, 3, "it stops as soon as nothing more can be released")
        let instants = await spy.collectionInstants
        XCTAssertEqual(Set(instants), [GovernorInstant.epoch], "retention runs at the injected instant")
        await expectEqual(spy.discardCalls, 0, "disk pressure does not discard decoded material")
    }

    func testDiskPressureBelowTheCeilingAsksTheCachesForNothing() async {
        let spy = PressureSpy(collectionReleases: [500])
        let governor = ResourceGovernor(
            limits: limits(diskBudgetBytes: 1_000),
            clock: clock,
            mediaCache: await spy.makeHandlers()
        )

        let outcome = await governor.enforceDiskBudget(usedBytes: 999)

        XCTAssertEqual(outcome.freedBytes, 0)
        await expectEqual(spy.collectionCalls, 0)
        await expectEqual(spy.trimCalls, 0)
    }

    func testDiskPressureStopsWhenTheCachesReleaseNothing() async {
        let spy = PressureSpy(trimReleases: [0], collectionReleases: [0])
        let governor = ResourceGovernor(
            limits: limits(diskBudgetBytes: 0),
            clock: clock,
            mediaCache: await spy.makeHandlers()
        )

        let outcome = await governor.enforceDiskBudget(usedBytes: 10)

        XCTAssertEqual(outcome.freedBytes, 0)
        await expectEqual(spy.collectionCalls, 1, "one attempt, not a loop against a full disk")
    }

    // MARK: composition

    func testAGovernorWithoutAMediaCacheStillAppliesPressure() async {
        let governor = ResourceGovernor(limits: limits(), clock: clock)

        let outcome = await governor.applyMemoryPressure()

        XCTAssertEqual(outcome.freedBytes, 0)
        XCTAssertEqual(outcome.downloadConcurrency, 1)
        await expectEqual(governor.enforceDiskBudget(usedBytes: 10_000).freedBytes, 0)
    }
}

/// Runs an operation that must fail and returns the error, or fails the test when it succeeds.
private func awaitFailure<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Error? {
    do {
        _ = try await operation()
        XCTFail("expected the operation to fail", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
