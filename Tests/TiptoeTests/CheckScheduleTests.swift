import Foundation
import Testing

@testable import Tiptoe

private let day: TimeInterval = 86400
private let hour: TimeInterval = 3600
private let schedule = CheckSchedule.daily

private func at(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

/// A check delivered mid-hour comes due on an hour boundary, not on its own
/// anniversary — that snapping is the entire point.
@Test func aMidHourCheckSnapsToTheGrid() {
    let next = schedule.next(after: at("2026-08-25T13:12:00Z"), beating: day,
                             now: at("2026-08-26T09:00:00Z"))
    #expect(next.timeIntervalSince1970.truncatingRemainder(dividingBy: hour) == 0)
}

/// Two installs whose phases have nothing to do with each other land on the
/// same instant. Everything else here is in service of this one line.
@Test func unrelatedPhasesConverge() {
    let now = at("2026-08-26T09:00:00Z")
    let a = schedule.next(after: at("2026-08-25T13:02:11Z"), beating: day, now: now)
    let b = schedule.next(after: at("2026-08-25T13:47:59Z"), beating: day, now: now)
    #expect(a == b)
}

/// A Mac asleep through its slot checks at the following one, minutes after
/// waking — never a whole period later. Without this the grid would quietly
/// cost a day of updates to anyone whose Mac sleeps at the wrong hour.
@Test func aSleptThroughSlotResolvesToTheNextOne() {
    let woke = at("2026-08-26T14:37:00Z")
    let next = schedule.next(after: at("2026-08-25T03:10:00Z"), beating: day, now: woke)
    #expect(next == at("2026-08-26T15:00:00Z"))
    #expect(next.timeIntervalSince(woke) < hour)
}

/// The delay the grid adds is bounded by one step plus the post-wake grace, in
/// every phase — the promise the doc comment makes to the person waiting for an
/// update.
@Test func theDelayNeverExceedsOneGridStep() {
    for offset in stride(from: 0.0, to: hour, by: 137) {
        let woke = at("2026-08-26T14:00:00Z").addingTimeInterval(offset)
        let next = schedule.next(after: at("2026-08-01T00:00:00Z"), beating: day, now: woke)
        let delay = next.timeIntervalSince(woke)
        #expect(delay >= schedule.wakeDelay)
        #expect(delay <= hour + schedule.wakeDelay)
    }
}

/// The aligned check has to beat the fallback timer by a real margin, not by
/// the moment it takes to record it. An earlier version aimed at "the first
/// slot after a period one grid step short", which settles into firing a hair
/// before the fallback and races it every day.
@Test func theMarginAheadOfTheFallbackIsSubstantial() {
    var last = at("2026-08-26T04:31:07Z")
    var worst = TimeInterval.infinity
    for _ in 0..<60 {
        let fallbackDue = last.addingTimeInterval(day)
        let next = schedule.next(after: last, beating: day, now: last.addingTimeInterval(60))
        worst = min(worst, fallbackDue.timeIntervalSince(next))
        // The check is recorded a moment after it fires.
        last = next.addingTimeInterval(3)
    }
    #expect(worst > 20 * 60)
}

/// The fallback's period wins when it is the shorter one: it belongs to the
/// person, and this schedule is not allowed to stretch it.
@Test func theShorterPeriodWins() {
    let weekly = CheckSchedule(period: 7 * day)
    let last = at("2026-08-26T00:00:00Z")
    let next = weekly.next(after: last, beating: day, now: last.addingTimeInterval(60))
    #expect(next < last.addingTimeInterval(day))
}

/// A fresh install with no check on record is due immediately, and still lands
/// on the grid rather than at whatever second it happened to launch.
@Test func aFirstEverCheckIsDueAtTheNextSlot() {
    let now = at("2026-08-26T14:37:00Z")
    let next = schedule.next(after: nil, beating: day, now: now)
    #expect(next == at("2026-08-26T15:00:00Z"))
}

@Test func slotsRoundTheWayTheySay() {
    let onGrid = at("2026-08-26T14:00:00Z")
    #expect(CheckSchedule.slot(onOrAfter: onGrid, alignment: hour) == onGrid)
    #expect(CheckSchedule.slot(onOrBefore: onGrid, alignment: hour) == onGrid)
    let past = onGrid.addingTimeInterval(1)
    #expect(CheckSchedule.slot(onOrAfter: past, alignment: hour) == onGrid.addingTimeInterval(hour))
    #expect(CheckSchedule.slot(onOrBefore: past, alignment: hour) == onGrid)
}

/// An alignment of zero is "no grid at all" rather than a division by zero.
@Test func aZeroAlignmentIsInert() {
    let moment = at("2026-08-26T14:31:07Z")
    #expect(CheckSchedule.slot(onOrAfter: moment, alignment: 0) == moment)
    #expect(CheckSchedule.slot(onOrBefore: moment, alignment: 0) == moment)
}
