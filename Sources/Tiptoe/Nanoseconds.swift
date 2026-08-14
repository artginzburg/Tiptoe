import Foundation

/// Seconds → nanoseconds for `Task.sleep(nanoseconds:)`, which the macOS 12
/// floor makes the only sleep available — `Duration`, which would refuse these
/// inputs on its own, arrived in macOS 13.
///
/// Every interval this package sleeps on is host-supplied, so the three ways
/// one can be unusable are handled here once rather than at each call site:
///
/// - `.infinity` traps the `UInt64` conversion outright;
/// - `.nan` is worse than a trap, because `max(0, .nan)` is `0` — a gate that
///   times out instantly, forever, so the app silently never updates while
///   logging a timeout every tick;
/// - zero or negative is a hot loop on the main actor.
///
/// Anything unusable becomes `fallback`. Anything usable is held between a
/// millisecond and a day: the ceiling keeps the conversion comfortably inside
/// `UInt64` and is longer than any interval that makes sense here, and the
/// floor is the other half of the same guarantee — `0.000_000_000_1` is
/// positive, and truncates to a sleep of zero, which is the hot loop this
/// exists to prevent wearing a different hat.
package func nanoseconds(_ seconds: TimeInterval, fallback: TimeInterval = 1) -> UInt64 {
    let shortest: TimeInterval = 0.001
    let longest: TimeInterval = 24 * 3600
    let usable = seconds.isFinite && seconds > 0 ? min(max(seconds, shortest), longest) : fallback
    return UInt64(usable * Double(NSEC_PER_SEC))
}
