import Foundation

/// A condition only the host app can evaluate — "no agents are working", "the
/// tour is not open". Gates are a veto rather than a preference: unlike the
/// package's own signals, they never relax with time.
public struct Gate: Sendable {
    public let name: String
    let isSatisfied: @Sendable () async -> Bool

    public init(_ name: String, isSatisfied: @escaping @Sendable () async -> Bool) {
        self.name = name
        self.isSatisfied = isSatisfied
    }
}

enum GateAnswer: Sendable, Equatable {
    case satisfied
    case blocked
    /// The gate did not answer in time. Treated as a refusal, but reported
    /// loudly: an app whose gate has died must look broken, not merely quiet.
    case timedOut
}

/// Settles the race between a gate and its timeout exactly once. Isolated to
/// the main actor so "has this already been answered?" needs no separate
/// lock. Whichever side answers first wins the continuation; the loser's
/// answer, whenever it eventually arrives, is discarded.
@MainActor
private final class GateRace: Sendable {
    private var continuation: CheckedContinuation<GateAnswer, Never>?
    private var settled = false
    private var gateTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    nonisolated init(continuation: CheckedContinuation<GateAnswer, Never>) {
        self.continuation = continuation
    }

    func register(gateTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        self.gateTask = gateTask
        self.timeoutTask = timeoutTask
    }

    func settle(_ answer: GateAnswer) {
        guard !settled else { return }
        settled = true
        continuation?.resume(returning: answer)
        continuation = nil
        // Best effort: a gate that checks `Task.isCancelled` stops promptly;
        // one that doesn't (an XPC call into a dead daemon, say) is left to
        // finish on its own time rather than holding `ask` open for it.
        gateTask?.cancel()
        timeoutTask?.cancel()
    }
}

/// Gates are async because the answer often lives elsewhere — behind XPC, in
/// a daemon. That also means one can hang, so nothing here waits on the gate
/// structurally: `withTaskGroup` cannot return until every child task
/// finishes, and cancellation is cooperative — a gate that never checks
/// `Task.isCancelled` would hold this open regardless. Racing two
/// unstructured tasks against a settle-once continuation avoids that:
/// whichever answers first resumes `ask`, and the loser keeps running,
/// unobserved, on its own time.
func ask(_ gate: Gate, timeout: TimeInterval) async -> GateAnswer {
    await withCheckedContinuation { (continuation: CheckedContinuation<GateAnswer, Never>) in
        Task { @MainActor in
            let race = GateRace(continuation: continuation)
            let gateTask = Task {
                let answer = await gate.isSatisfied() ? GateAnswer.satisfied : .blocked
                race.settle(answer)
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: nanoseconds(timeout))
                race.settle(.timedOut)
            }
            race.register(gateTask: gateTask, timeoutTask: timeoutTask)
        }
    }
}
