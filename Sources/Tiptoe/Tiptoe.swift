import AppKit
import Foundation
import os

/// Holds a downloaded update back until the Mac is quiet and the host says yes,
/// then installs it with no UI at all.
///
/// Tiptoe decides *when*. Something else — Sparkle, mxcl/AppUpdater — has
/// already worked out *how*, and hands the last step over through
/// ``hold(version:retryable:install:)``.
@MainActor
public final class Tiptoe {

    public struct Pending: Sendable, Equatable {
        public let version: String
        /// When the *current continuous wait* began, not when this version
        /// arrived: a newer version replacing a waiting one inherits the clock.
        public let waitingSince: Date
    }

    private let policyBase: QuietPolicy
    private var policy: QuietPolicy
    private let environment: Environment
    private let store: Store
    private let log: Logger

    private var gates: [Gate] = []
    private var installAction: (@MainActor @Sendable () async throws -> Void)?
    /// Whether `installAction` may be attempted again after it throws. Set
    /// alongside `installAction` by every `hold()` call; only meaningful
    /// while `installAction` is non-nil.
    private var installRetryable = true
    /// Runs only while something is ``pending``: with nothing to install there
    /// is nothing to ask the sensors, and a timer that wakes the process once
    /// a minute to learn exactly that costs a wake-up every app shipping this
    /// package pays, all day, for the 99% of the time no update is waiting.
    private var pollTask: Task<Void, Never>?
    private var isStarted = false
    /// Each observer with the center it came from: the screen-lock notification
    /// is distributed, the rest are the workspace's, and an observer must be
    /// removed from the center that registered it.
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    /// Set by `stop()`, cleared by `start()`. `evaluate()` checks it so an
    /// already-queued tick — the one `hold()` spawns, or one that was mid-gate-
    /// await when `stop()` was called — cannot land an install a host believes
    /// is paused.
    private var stopped = false

    public private(set) var pending: Pending? {
        didSet { pollWhilePending() }
    }

    /// Called just before the app is replaced. The process may not survive the
    /// next line, so a host that wants to record something records it here.
    public var onWillInstall: ((Pending) -> Void)?

    /// Fired once, when a wait has run past ``QuietPolicy/escalateAfter``. The
    /// package's own signals always yield eventually, so in practice this means
    /// a host gate has been refusing for weeks — worth surfacing, and the host
    /// decides whether that becomes a line of UI.
    public var onWaitingTooLong: ((Pending) -> Void)?

    public init(
        policy: QuietPolicy = .default,
        environment: Environment = .live,
        defaults: UserDefaults = .standard,
        subsystem: String = Bundle.main.bundleIdentifier ?? "Tiptoe"
    ) {
        policyBase = policy
        self.policy = policy
        self.environment = environment
        store = Store(defaults: defaults)
        log = Logger(subsystem: subsystem, category: "tiptoe")
        reconcileRecordedWait()
        reconcileRecordedNotice()
    }

    /// A wait only means something if the app it was recorded against is still
    /// the app that is running.
    ///
    /// Sparkle installs a pending update when the app quits — its own header
    /// says so — and Homebrew, a downloaded DMG or a reinstall do the same on
    /// the GitHub path. Every one of those routes replaces the app without
    /// this package ever calling `install()`, which is the only place that
    /// clears the wait. Left alone, the clock would keep running for months
    /// and the next update to arrive would inherit it: a first evaluation
    /// landing straight on the most permissive rung, swapping the app out
    /// from under somebody who paused for six seconds with a window open.
    ///
    /// So the wait is reconciled once, here, against two facts that cannot be
    /// trusted to have stood still while the process was not running.
    private func reconcileRecordedWait() {
        guard let waitingSince = store.waitingSince else { return }

        let running = environment.appVersion()
        if store.appVersion != running {
            if let pending = store.pendingVersion, sameVersion(pending, running) {
                // The very update this wait was for landed some other way.
                // Which also means the host's "Updated to X" line is owed —
                // nothing else in the package is in a position to notice.
                store.justUpdatedTo = running
                log.debug("update \(running, privacy: .public) landed without us; the wait is over")
            } else {
                log.debug("the app changed to \(running, privacy: .public) under a waiting update; starting the clock over")
            }
            store.clearWait()
            return
        }

        // A Mac that boots with a wrong clock — the battery that keeps it is
        // the one part of this that ages — can put `waitingSince` far enough
        // back that NTP correcting it seconds later leaves a wait nobody
        // served. Ninety days is well past any honest wait this package's own
        // escalation admits to.
        let waited = environment.now().timeIntervalSince(waitingSince)
        if waited > 90 * 86400 {
            log.debug("a wait \(Int(waited / 86400)) days old is not a wait; starting the clock over")
            store.clearWait()
        }
    }

    /// "Updated to X" is only true while X is the version that is running.
    ///
    /// The notice is written just before the swap and cleared by the host's
    /// ``acknowledge()`` — and a person who never opens the place the host
    /// shows it in never acknowledges. The record then outlives the next
    /// Homebrew upgrade, the next dragged-in DMG, a downgrade: 1.12 launches
    /// announcing "Updated to 1.11", at every launch, for as long as that
    /// person keeps not looking. Checked once, here, against the bundle, the
    /// way the wait is just above; a notice the wait reconciliation has only
    /// just written names the running version by construction and passes.
    private func reconcileRecordedNotice() {
        guard let noticed = store.justUpdatedTo else { return }
        let running = environment.appVersion()
        if sameVersion(noticed, running) { return }
        log.debug("the \(noticed, privacy: .public) notice outlived its version; the app is now \(running, privacy: .public)")
        store.justUpdatedTo = nil
    }

    // MARK: - Setting up

    /// A condition only this app can evaluate. Several may be added; any one of
    /// them refusing is enough to hold the update back.
    @discardableResult
    public func gate(_ name: String, _ isSatisfied: @escaping @Sendable () async -> Bool) -> Self {
        gates.append(Gate(name, isSatisfied: isSatisfied))
        return self
    }

    /// Keep open windows blocking however long the wait runs.
    @discardableResult
    public func windowsAlwaysBlock() -> Self {
        policy = policyBase.windowsAlwaysBlock()
        return self
    }

    @discardableResult
    public func start() -> Self {
        guard !isStarted else { return self }
        isStarted = true
        stopped = false
        TiptoeRegistry.retain(self)
        observeQuietMoments()
        if pending != nil {
            // Held while stopped: the evaluation `hold()` spawned found the
            // instance stopped and did nothing, so nobody has looked yet.
            Task { await evaluate() }
        }
        pollWhilePending()
        return self
    }

    public func stop() {
        isStarted = false
        stopped = true
        stopPolling()
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        TiptoeRegistry.release(self)
    }

    /// Whether the poll loop is running. For this package's own tests.
    var isPolling: Bool { pollTask != nil }

    /// Sleeps first: whatever made something pending — `hold()`, `start()`,
    /// or a failed install putting its update back — has just evaluated, or
    /// is about to.
    ///
    /// The loop retires itself once nothing is pending, rather than being
    /// cancelled when `pending` clears: that happens inside `install()`, and
    /// when the tick doing the installing is this loop's own, cancelling it
    /// would hand the install a cancelled task — which any `Task.sleep` in
    /// it (mxcl/AppUpdater's relaunch has one) answers by throwing.
    private func pollWhilePending() {
        guard isStarted, pollTask == nil, pending != nil else { return }
        pollTask = Task { [weak self, interval = policy.pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds(interval, fallback: 60))
                guard let self, !Task.isCancelled else { return }
                guard pending != nil else {
                    pollTask = nil
                    return
                }
                await evaluate()
            }
        }
    }

    /// For `stop()` alone; see `pollWhilePending()` for why.
    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Being handed an update

    /// Called by an adapter once an update is downloaded and ready to install.
    ///
    /// Replacing a still-waiting update is normal and does not restart the
    /// clock — otherwise an app that ships weekly would never reach the later
    /// rungs of the ladder.
    ///
    /// A throw from `install` is a failed *attempt*, not a failed update. A
    /// `retryable` install (the default — right for Sparkle, whose block can
    /// be invoked again) is put back exactly as it stood — same version, same
    /// clock, same closure — so the next quiet moment simply tries again. A
    /// one-shot install (`retryable: false` — right for an adapter like
    /// mxcl/AppUpdater, whose prepared update is spent the moment `install`
    /// runs, success or failure) is discarded instead: the wait keeps
    /// running, but nothing is left to retry until a fresh `hold()` replaces
    /// it.
    public func hold(
        version: String,
        retryable: Bool = true,
        install: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        let since = store.waitingSince ?? environment.now()
        store.waitingSince = since
        store.pendingVersion = version
        // Recorded with the wait, so the next launch can tell a wait that is
        // still running from one whose update landed some other way. See
        // `reconcileRecordedWait()`.
        store.appVersion = environment.appVersion()
        installAction = install
        installRetryable = retryable
        pending = Pending(version: version, waitingSince: since)
        log.info("update \(version, privacy: .public) is ready; waiting for a quiet moment")
        Task { await evaluate() }
    }

    /// Install right now, whatever the Mac is doing. For a host acting on an
    /// explicit request from a person.
    ///
    /// Returns the task so a caller that needs to know when the install has
    /// happened — this package's own tests, chiefly — can `await` its `value`;
    /// an ordinary caller fires and forgets it.
    @discardableResult
    public func installNow() -> Task<Void, Never> {
        Task { await install() }
    }

    // MARK: - What the host can show

    /// The version this app last installed silently, until ``acknowledge()``.
    public var justUpdatedTo: String? { store.justUpdatedTo }

    public func acknowledge() {
        store.justUpdatedTo = nil
    }

    // MARK: - The tick

    func evaluate() async {
        guard !stopped else {
            log.debug("not evaluating: the host has stopped this instance")
            return
        }
        guard let pending else { return }

        let waited = environment.now().timeIntervalSince(pending.waitingSince)
        escalateIfOverdue(pending, waited: waited)

        let verdict = policy.verdict(
            waitedFor: waited,
            secondsSinceInput: environment.secondsSinceInput(),
            windows: environment.windows()
        )
        if case .wait(let reason) = verdict {
            log.debug("holding \(pending.version, privacy: .public): \(reason, privacy: .public)")
            return
        }

        for gate in gates {
            switch await ask(gate, timeout: policy.gateTimeout) {
            case .satisfied:
                continue
            case .blocked:
                log.debug("holding \(pending.version, privacy: .public): gate: \(gate.name, privacy: .public)")
                return
            case .timedOut:
                log.error("gate '\(gate.name, privacy: .public)' did not answer in \(self.policy.gateTimeout, privacy: .public) s; holding the update")
                return
            }
        }

        // The verdict above was read before the gates were asked, and each
        // gate may take up to `policy.gateTimeout` to answer — long enough for
        // the Mac to stop being quiet, or for a host to call `stop()`. Recheck
        // both on fresh sensors before committing to the install; the next
        // tick will simply try again.
        guard !stopped else {
            log.debug("holding \(pending.version, privacy: .public): the host stopped this instance while a gate was answering")
            return
        }
        let recheckedWaited = environment.now().timeIntervalSince(pending.waitingSince)
        let recheckedVerdict = policy.verdict(
            waitedFor: recheckedWaited,
            secondsSinceInput: environment.secondsSinceInput(),
            windows: environment.windows()
        )
        if case .wait(let reason) = recheckedVerdict {
            log.debug("holding \(pending.version, privacy: .public): \(reason, privacy: .public) (became true while a gate was answering)")
            return
        }

        await install()
    }

    private func escalateIfOverdue(_ pending: Pending, waited: TimeInterval) {
        guard waited >= policy.escalateAfter, !store.hasEscalated else { return }
        store.hasEscalated = true
        log.error("update \(pending.version, privacy: .public) has been waiting \(Int(waited / 86400)) days")
        onWaitingTooLong?(pending)
    }

    private func install() async {
        // Reads `self.pending` fresh rather than reusing the snapshot
        // `evaluate()` validated: deliberate, so that a version bump from
        // `hold()` arriving mid-check installs the newer version, not the
        // one that was actually checked.
        guard let pending, let action = installAction else { return }
        log.info("installing \(pending.version, privacy: .public) while nobody is looking")
        onWillInstall?(pending)

        // Written before the swap, because the process is about to be replaced:
        // this is the only moment that knows an update — rather than somebody
        // dragging a new build in — is what changed the version. Captured
        // separately so a throw below can put it back exactly as it was.
        let hadEscalated = store.hasEscalated
        let recordedAppVersion = store.appVersion
        let retryable = installRetryable
        store.justUpdatedTo = pending.version
        store.clearWait()
        self.pending = nil
        installAction = nil

        do {
            try await action()
        } catch {
            // The process survived, so nothing actually changed to the wait
            // itself: undo the bookkeeping above regardless of `retryable` —
            // the whole record of the wait goes back, so the clock keeps
            // running either way, and the next launch still recognizes it as
            // this app's own unfinished wait rather than a stale one.
            store.justUpdatedTo = nil
            store.waitingSince = pending.waitingSince
            store.pendingVersion = pending.version
            store.appVersion = recordedAppVersion
            store.hasEscalated = hadEscalated
            if retryable {
                // The closure itself can still be invoked again: put it back
                // too, so the next quiet moment simply tries it once more.
                log.error("installing \(pending.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public); will retry")
                self.pending = pending
                installAction = action
            } else {
                // The closure is spent — retrying it would only throw again,
                // every poll tick, until something replaces it. Leave both
                // nil: the poll loop has nothing to hammer, and the wait
                // stands ready for whatever `hold()` call comes next.
                log.error("installing \(pending.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public); the download was one-shot and is spent, waiting for a fresh one")
            }
        }
    }

    /// A sleeping display, a locked screen, a session switched away from: all
    /// quiet by definition, and there is no reason to wait out the rest of the
    /// poll interval to notice. Every one of these is best-effort — the lock
    /// notification in particular is undocumented, and none of them is
    /// guaranteed to arrive — so the poll remains what guarantees progress;
    /// these only make the common cases prompt.
    private func observeQuietMoments() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(name, on: workspace)
        }
        // Locking the screen — the deliberate "I am leaving" — posts nothing
        // through the workspace center; it is a distributed notification, and
        // an undocumented one, which is why it is watched alongside the two
        // above rather than instead of them.
        observe(Notification.Name("com.apple.screenIsLocked"), on: DistributedNotificationCenter.default())
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let _: Task<Void, Never> = Task { await self?.evaluate() }
            }
        }
        observers.append((center: center, token: token))
    }
}
