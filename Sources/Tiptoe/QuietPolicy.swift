import Foundation

/// What the app's own windows look like at this instant.
public struct WindowSnapshot: Sendable, Equatable {
    /// Any visible window that could become main. The status item's window
    /// cannot, so a menu bar app with nothing open reports `false`.
    public var hasVisibleMainCapableWindow: Bool
    /// Any window with unsaved changes (the dot in the close button), or a
    /// sheet or modal being up.
    public var hasUnsavedWork: Bool

    public init(hasVisibleMainCapableWindow: Bool, hasUnsavedWork: Bool) {
        self.hasVisibleMainCapableWindow = hasVisibleMainCapableWindow
        self.hasUnsavedWork = hasUnsavedWork
    }
}

/// The answer to "may the update land right now?", carrying the reason when it
/// may not — that reason is the whole content of the log this package keeps.
public enum QuietVerdict: Sendable, Equatable {
    case go
    case wait(String)
}

/// How still the Mac has to be before a downloaded update may replace the app.
///
/// The requirement loosens as the wait grows. A Mac that is never perfectly
/// quiet would otherwise never be updated at all — and under Sparkle it is
/// worse than never, because holding one installation stalls the whole update
/// cycle, so a stale pending update blocks the fix that would have replaced it.
public struct QuietPolicy: Sendable, Equatable {

    /// Which of the app's own windows stand in the way.
    public enum WindowRule: Sendable, Equatable {
        /// Any visible window that can become main blocks the install.
        case anyVisibleBlocks
        /// Only unsaved work blocks — an ordinary window is allowed to be open.
        case onlyUnsavedBlocks
    }

    public struct Rung: Sendable, Equatable {
        /// This rung applies once the app has been waiting at least this long.
        public var after: TimeInterval
        /// Seconds the Mac must have gone without input of any kind.
        public var idleSeconds: TimeInterval
        public var windows: WindowRule

        public init(after: TimeInterval, idleSeconds: TimeInterval, windows: WindowRule) {
            self.after = after
            self.idleSeconds = idleSeconds
            self.windows = windows
        }
    }

    /// Ascending by ``Rung/after``; the first rung starts at zero — an
    /// invariant ``rung(waitedFor:)`` relies on, which is why the ladder is
    /// only ever replaced through an initialiser that checks it.
    public private(set) var rungs: [Rung]
    /// How long a wait has to run before the host is told about it, once.
    public var escalateAfter: TimeInterval
    public var pollInterval: TimeInterval
    /// A gate that has not answered within this long counts as a refusal.
    public var gateTimeout: TimeInterval

    public init(
        rungs: [Rung],
        escalateAfter: TimeInterval,
        pollInterval: TimeInterval,
        gateTimeout: TimeInterval
    ) {
        precondition(rungs.first?.after == 0, "the first rung must apply from the start")
        // A zero interval is a poll loop spinning on the main actor, which
        // costs the person the very attention this package exists to protect.
        precondition(pollInterval > 0, "the poll interval must be positive")
        self.rungs = rungs
        self.escalateAfter = escalateAfter
        self.pollInterval = pollInterval
        self.gateTimeout = gateTimeout
    }

    /// Two minutes is past "paused to read something" and well short of "left
    /// for lunch"; the check repeats, so guessing low costs at worst a relaunch
    /// nobody sees.
    public static let `default` = QuietPolicy(
        rungs: [
            Rung(after: 0, idleSeconds: 120, windows: .anyVisibleBlocks),
            Rung(after: 48 * 3600, idleSeconds: 30, windows: .anyVisibleBlocks),
            Rung(after: 7 * 86400, idleSeconds: 5, windows: .onlyUnsavedBlocks),
        ],
        escalateAfter: 14 * 86400,
        pollInterval: 60,
        gateTimeout: 5
    )

    public func rung(waitedFor waited: TimeInterval) -> Rung {
        rungs.last { waited >= $0.after } ?? rungs[0]
    }

    /// Keep every rung's window rule strict, for a host whose windows hold
    /// state it never marks as unsaved — a SwiftUI app, typically.
    public func windowsAlwaysBlock() -> QuietPolicy {
        var copy = self
        copy.rungs = rungs.map {
            Rung(after: $0.after, idleSeconds: $0.idleSeconds, windows: .anyVisibleBlocks)
        }
        return copy
    }

    /// The whole decision, as a pure function of three measurements.
    public func verdict(
        waitedFor waited: TimeInterval,
        secondsSinceInput: TimeInterval,
        windows: WindowSnapshot
    ) -> QuietVerdict {
        if windows.hasUnsavedWork {
            return .wait("a window has unsaved work")
        }
        let rung = rung(waitedFor: waited)
        if rung.windows == .anyVisibleBlocks, windows.hasVisibleMainCapableWindow {
            return .wait("a window is open")
        }
        guard secondsSinceInput >= rung.idleSeconds else {
            return .wait("input \(Int(secondsSinceInput)) s ago, needs \(Int(rung.idleSeconds)) s")
        }
        return .go
    }
}
