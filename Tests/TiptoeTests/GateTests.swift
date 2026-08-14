import Foundation
import Testing

@testable import Tiptoe

@Test func aSatisfiedGateLetsTheUpdateThrough() async {
    let gate = Gate("agents are working") { true }
    #expect(await ask(gate, timeout: 1) == .satisfied)
}

@Test func aRefusingGateBlocks() async {
    let gate = Gate("agents are working") { false }
    #expect(await ask(gate, timeout: 1) == .blocked)
}

@Test func aGateThatNeverAnswersTimesOutRatherThanHangingForever() async {
    let gate = Gate("dead daemon") {
        try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
        return true
    }
    #expect(await ask(gate, timeout: 0.05) == .timedOut)
}

/// The timeout reaches `ask` from the host's `QuietPolicy`, so it can be
/// anything a `TimeInterval` can hold. `.nan` is the quiet one: the obvious
/// `max(0, timeout)` clamp turns it into zero, and a zero timeout refuses
/// every gate the instant it is asked — an app that never updates while its
/// log blames gates that were about to say yes. This gate answers in a tenth
/// of a second, comfortably inside the fallback the conversion substitutes,
/// so it can only pass if `ask` goes through that conversion.
@Test func aTimeoutThatIsNotANumberDoesNotRefuseAHealthyGate() async {
    let gate = Gate("unhurried daemon") {
        try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
        return true
    }
    #expect(await ask(gate, timeout: .nan) == .satisfied)
}

/// The predecessor of `ask` waited on the gate's own task to finish before it
/// could return, so a gate that never checks `Task.isCancelled` — an XPC
/// bridge, say — held the timeout open indefinitely. This gate models that:
/// the only thing that ever resumes it is a timer set far beyond the timeout
/// given to `ask` below, standing in for a daemon that ignores cancellation
/// entirely. `ask` must still return around the timeout, not around however
/// long the gate takes.
@Test func aGateThatIgnoresCancellationTimesOutAnyway() async {
    let gate = Gate("wedged xpc bridge") {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task {
                try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
                continuation.resume(returning: true)
            }
        }
    }
    let start = Date()
    #expect(await ask(gate, timeout: 0.05) == .timedOut)
    // Comfortably above the 0.05 s timeout to absorb scheduling jitter, but
    // far short of the gate's real 2 s answer — a version of `ask` that
    // structurally waits for the gate would fail this, not merely run slow.
    #expect(Date().timeIntervalSince(start) < 0.3)
}
