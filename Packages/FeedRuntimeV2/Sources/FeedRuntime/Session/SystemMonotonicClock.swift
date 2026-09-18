import Foundation
import FeedDomain

/// The system's monotonic clock (plan §11, ADR-007).
///
/// Readings come from `ProcessInfo.systemUptime`, which does not move when the wall clock is adjusted —
/// an exposure interval measured against `Date()` would jump on a time-zone change, a manual
/// correction or a leap second, and a dwell measured with a jump is not a dwell.
///
/// The boot session is derived rather than read: subtracting the uptime from the wall clock gives the
/// boot instant to within the clock's own drift, and rounding it to the second makes two launches in
/// one boot agree. Reading `kern.boottime` directly would need `Darwin`, which this module is not
/// allowed to import (plan §3), and the value is used to group readings, not to schedule anything.
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func nowMillis() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded())
    }

    public var bootSessionID: String {
        let bootInstant = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        return "boot-\(Int64(bootInstant.rounded()))"
    }
}
