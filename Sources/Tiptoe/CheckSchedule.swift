import Foundation

/// When a periodic background check should fire, so that every install of an
/// app fires at the same moments instead of each on its own phase.
///
/// The problem it solves belongs to the server, not the Mac. An updater checks
/// at `lastCheck + interval`; the interval is shared but the phase is not, so
/// whichever moment an install first ran is the moment it asks in for the rest
/// of its life. Across an install base those accidents spread the fleet evenly
/// over all 24 hours, which is the worst shape a feed server can be handed. A
/// CDN in front of the appcast almost never sees a second request inside one
/// TTL, because arrivals fragment across points of presence faster than they
/// accumulate; a scale-to-zero backend is worse, billed by the wall clock and
/// asleep on an idle timeout, so a hundred arrivals at a hundred unrelated
/// moments buy a hundred full timeouts where one clump would have bought one.
///
/// Snapping to a grid costs the person one grid step of latency at most, and
/// tends to give some of it back: only the first request in a clump pays for a
/// cold start.
///
/// `nonisolated` on the type for the same reason `QuietPolicy` carries it —
/// this is a `Sendable` value with no isolation to inherit, and these sources
/// are compiled *inside* hosts that may default to MainActor isolation.
nonisolated public struct CheckSchedule: Sendable, Equatable {
    /// How much time must pass between checks.
    public var period: TimeInterval
    /// The wall-clock grid to snap to. Must stay well under `period`, and small
    /// enough that a waking Mac finds a slot soon: an hour is both. A daily
    /// grid would be cheaper for the server and would be missed forever by a
    /// Mac that sleeps at the same hour every night.
    public var alignment: TimeInterval
    /// How far into a slot a check may be scattered, so a large fleet does not
    /// open every connection in the same second. Keep it far below whatever
    /// idle timeout the server has, or the clump the grid just made is spread
    /// back out again.
    public var jitter: TimeInterval
    /// How far ahead of the fallback timer to aim. Only has to outrun the
    /// moment between a check firing and being recorded; the grid supplies the
    /// rest.
    public var margin: TimeInterval
    /// A check is not attempted this soon after a wake — the minutes right
    /// after one are when the network is least likely to be back.
    public var wakeDelay: TimeInterval

    public init(
        period: TimeInterval = 86400,
        alignment: TimeInterval = 3600,
        jitter: TimeInterval = 60,
        margin: TimeInterval = 60,
        wakeDelay: TimeInterval = 60
    ) {
        self.period = period
        self.alignment = alignment
        self.jitter = jitter
        self.margin = margin
        self.wakeDelay = wakeDelay
    }

    /// Once a day, on the hour.
    public static let daily = CheckSchedule()

    /// The instant the next check should fire.
    ///
    /// - Parameters:
    ///   - lastCheck: When a check last happened, or nil if none ever has.
    ///   - fallbackInterval: The period of the timer this check has to beat —
    ///     the updater's own, which stays armed underneath as the backstop for
    ///     a Mac that was asleep for both. The shorter of it and `period` wins,
    ///     because that timer is the person's preference and is not ours to
    ///     move.
    ///   - now: The current instant.
    ///
    /// The result is the last grid instant that still precedes the fallback by
    /// `margin`. Deliberately not "the first slot after a period one step
    /// short", which reads as equivalent and is not: a check landing on a slot
    /// puts the next one a whole period later, exactly where the fallback timer
    /// already was, leaving only the moment it took to record the check — a
    /// race for a margin.
    ///
    /// A slot already behind us is one the Mac slept through, and resolves to
    /// the next one minutes from now rather than to a whole period later. That
    /// is the guarantee worth stating plainly: this only ever *delays* a check
    /// by up to one grid step, and never skips a period.
    public func next(after lastCheck: Date?, beating fallbackInterval: TimeInterval, now: Date) -> Date {
        let due = (lastCheck ?? .distantPast).addingTimeInterval(min(period, fallbackInterval))
        let target = Self.slot(onOrBefore: due.addingTimeInterval(-margin), alignment: alignment)
        let soonest = now.addingTimeInterval(wakeDelay)
        return target > soonest ? target : Self.slot(onOrAfter: soonest, alignment: alignment)
    }

    /// The first grid instant at or after `earliest`.
    ///
    /// Absolute time, deliberately not `Calendar`: every install has to compute
    /// the same set of instants, and a grid that drifts with the host's time
    /// zone is not a shared grid.
    public static func slot(onOrAfter earliest: Date, alignment: TimeInterval) -> Date {
        guard alignment > 0 else { return earliest }
        return Date(timeIntervalSince1970:
            (earliest.timeIntervalSince1970 / alignment).rounded(.up) * alignment)
    }

    /// The last grid instant at or before `latest`.
    public static func slot(onOrBefore latest: Date, alignment: TimeInterval) -> Date {
        guard alignment > 0 else { return latest }
        return Date(timeIntervalSince1970:
            (latest.timeIntervalSince1970 / alignment).rounded(.down) * alignment)
    }
}
