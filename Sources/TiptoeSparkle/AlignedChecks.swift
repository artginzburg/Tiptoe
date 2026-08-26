#if SparkleSupport
import AppKit
import Sparkle

#if canImport(Tiptoe)
import Tiptoe
#endif

// Putting background update checks on a wall-clock grid: the Sparkle half.
//
// Everything about *when* lives in `CheckSchedule`, which is pure, has no idea
// Sparkle exists, and is tested. What is left here is the part that cannot be:
// a timer, a wake notification, and two calls into `SPUUpdater`.

extension TiptoeSparkle {
    /// A check with no window, no progress bar and no "you are up to date" —
    /// the same thing Sparkle's own timer fires, exposed so a host can decide
    /// *when* it happens. Sparkle records it as the last check either way, so
    /// its own timer restarts from here.
    ///
    /// Does nothing if the person has turned automatic checks off: their
    /// preference outranks any schedule a host asks for.
    public func checkForUpdatesInBackground() {
        guard let updater, updater.automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Puts background checks on a wall-clock grid shared by every install,
    /// instead of each one keeping its own free-running phase. See
    /// ``CheckSchedule`` for what that buys and what it costs.
    ///
    /// Nothing here writes to Sparkle's settings. `updateCheckInterval` may be
    /// the person's own preference, and Sparkle's header is explicit that an
    /// app must not set it on launch — the same rule ``start()`` already obeys
    /// by reporting `automaticallyDownloadsUpdates` rather than correcting it.
    /// So the aligned check is timed to land inside Sparkle's window rather
    /// than to move it, and Sparkle's timer stays armed underneath as the
    /// backstop for a Mac that was asleep for both.
    ///
    /// Call before or after ``start()``; either order arms it.
    @discardableResult
    public func alignChecks(_ schedule: CheckSchedule = .daily) -> Self {
        alignedChecks = AlignedChecks(schedule: schedule, owner: self)
        alignedChecks?.arm()
        return self
    }
}

/// Owns the timer and the wake notification for aligned checks, so that
/// ``TiptoeSparkle`` needs one stored property rather than three.
@MainActor
final class AlignedChecks {
    private let schedule: CheckSchedule
    private weak var owner: TiptoeSparkle?
    private var workItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    init(schedule: CheckSchedule, owner: TiptoeSparkle) {
        self.schedule = schedule
        self.owner = owner
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.arm() }
        }
    }

    /// No `deinit` counterpart, matching ``Tiptoe`` itself: a nonisolated
    /// deinit may not touch the observer token under Swift 6 concurrency, and
    /// there is nothing to gain by fighting that. Both types live for as long
    /// as the process does — the README says outright that never calling
    /// `stop()` is the normal case — so the only path that really tears one
    /// down is the one that goes through here.
    func stop() {
        workItem?.cancel()
        workItem = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Arms the next check. Safe to call repeatedly — a wake does exactly that,
    /// because `asyncAfter` counts on the uptime clock, which stops while the
    /// Mac sleeps, so any deadline set before a sleep is wrong after it.
    func arm() {
        guard let updater = owner?.updater else { return }
        workItem?.cancel()

        let at = schedule
            .next(after: updater.lastUpdateCheckDate,
                  beating: updater.updateCheckInterval,
                  now: Date())
            .addingTimeInterval(schedule.jitter > 0 ? Double.random(in: 0..<schedule.jitter) : 0)

        let item = DispatchWorkItem { [weak self] in
            self?.owner?.checkForUpdatesInBackground()
            self?.arm()
        }
        workItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, at.timeIntervalSinceNow), execute: item)
    }
}
#endif
