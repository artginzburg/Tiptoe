import Foundation
import Testing

@testable import Tiptoe

private let busy = WindowSnapshot(hasVisibleMainCapableWindow: true, hasUnsavedWork: false)
private let clear = WindowSnapshot(hasVisibleMainCapableWindow: false, hasUnsavedWork: false)
private let unsaved = WindowSnapshot(hasVisibleMainCapableWindow: true, hasUnsavedWork: true)

@Test func freshWaitNeedsTwoMinutesOfStillness() {
    let policy = QuietPolicy.default
    #expect(policy.verdict(waitedFor: 0, secondsSinceInput: 119, windows: clear) != .go)
    #expect(policy.verdict(waitedFor: 0, secondsSinceInput: 120, windows: clear) == .go)
}

@Test func anOpenWindowBlocksTheFirstTwoRungs() {
    let policy = QuietPolicy.default
    #expect(policy.verdict(waitedFor: 0, secondsSinceInput: 600, windows: busy) != .go)
    #expect(policy.verdict(waitedFor: 3 * 86400, secondsSinceInput: 600, windows: busy) != .go)
}

@Test func afterTwoDaysThirtySecondsIsEnough() {
    let policy = QuietPolicy.default
    #expect(policy.verdict(waitedFor: 49 * 3600, secondsSinceInput: 31, windows: clear) == .go)
    #expect(policy.verdict(waitedFor: 47 * 3600, secondsSinceInput: 31, windows: clear) != .go)
}

@Test func afterAWeekAnOrdinaryWindowStopsMattering() {
    let policy = QuietPolicy.default
    #expect(policy.verdict(waitedFor: 8 * 86400, secondsSinceInput: 6, windows: busy) == .go)
}

@Test func unsavedWorkBlocksForever() {
    let policy = QuietPolicy.default
    #expect(policy.verdict(waitedFor: 400 * 86400, secondsSinceInput: 9999, windows: unsaved) != .go)
}

@Test func optingOutKeepsWindowsBlockingAtEveryRung() {
    let policy = QuietPolicy.default.windowsAlwaysBlock()
    #expect(policy.verdict(waitedFor: 8 * 86400, secondsSinceInput: 600, windows: busy) != .go)
    #expect(policy.verdict(waitedFor: 8 * 86400, secondsSinceInput: 600, windows: clear) == .go)
}

@Test func aRefusalSaysWhy() {
    let policy = QuietPolicy.default
    guard case .wait(let reason) = policy.verdict(waitedFor: 0, secondsSinceInput: 3, windows: clear) else {
        Issue.record("expected a refusal")
        return
    }
    #expect(reason.contains("120"))
}
