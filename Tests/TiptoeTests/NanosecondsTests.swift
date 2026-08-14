import Foundation
import Testing

@testable import Tiptoe

/// `UInt64(TimeInterval.infinity * …)` traps, and every interval this package
/// sleeps on comes from the host.
@Test func anInfiniteIntervalDoesNotTrap() {
    #expect(nanoseconds(.infinity, fallback: 2) == 2 * NSEC_PER_SEC)
}

/// The dangerous one. `max(0, .nan)` is `0`, so the arithmetic that looks like
/// a clamp silently turns a garbage interval into "immediately" — every gate
/// timing out forever, an app that never updates, and a log full of timeouts
/// blaming the host's gates.
@Test func aNotANumberIntervalBecomesTheFallbackRatherThanZero() {
    #expect(nanoseconds(.nan, fallback: 3) == 3 * NSEC_PER_SEC)
    #expect(nanoseconds(.signalingNaN, fallback: 3) == 3 * NSEC_PER_SEC)
}

@Test func nonPositiveIntervalsBecomeTheFallbackRatherThanAHotLoop() {
    #expect(nanoseconds(0, fallback: 60) == 60 * NSEC_PER_SEC)
    #expect(nanoseconds(-5, fallback: 60) == 60 * NSEC_PER_SEC)
}

/// A positive interval can still truncate to a sleep of zero, which is the
/// same hot loop by another route — and `QuietPolicy(pollInterval: 1e-12, …)`
/// passes the `> 0` precondition on its way there.
@Test func aSubNanosecondIntervalStillSleeps() {
    #expect(nanoseconds(1e-12) > 0)
    #expect(nanoseconds(0.000_000_1) > 0)
}

@Test func anOrdinaryIntervalIsLeftAlone() {
    #expect(nanoseconds(0.05) == 50 * NSEC_PER_MSEC)
    #expect(nanoseconds(4 * 3600) == 4 * 3600 * NSEC_PER_SEC)
}

/// Longer than a day is either a mistake or an interval nothing here needs;
/// capping it keeps the conversion far inside `UInt64` either way.
@Test func anAbsurdlyLongIntervalIsCappedAtADay() {
    #expect(nanoseconds(400 * 86400) == 24 * 3600 * NSEC_PER_SEC)
}
