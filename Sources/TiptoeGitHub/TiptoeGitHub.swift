#if GitHubSupport
import AppUpdater
import Foundation
import os

// Conditional for the same reason as in TiptoeSparkle: compiled into a host's
// own target rather than linked as a product, there is no separate Tiptoe
// module and the types are already in scope.
#if canImport(Tiptoe)
import Tiptoe
#endif

/// Tiptoe for an app that ships notarized DMGs through GitHub Releases and is
/// not sandboxed — which is the only way an app may replace its own bundle
/// without an XPC service outside the sandbox.
///
/// Unlike Sparkle, mxcl/AppUpdater has no scheduler of its own, so this owns the
/// check loop as well as the handover.
@MainActor
public final class TiptoeGitHub {
    public let tiptoe: Tiptoe
    private let source: any UpdateSource
    private let checkInterval: TimeInterval
    private let log: Logger
    private var checkTask: Task<Void, Never>?
    private var waiting: PreparedInstall?
    /// Set by `stop()`, cleared by `start()`. `checkNow()` checks it before
    /// and after the (possibly long) network round trip, so a check already
    /// in flight when the host stops cannot land a `hold()` afterward.
    private var stopped = false
    /// `checkNow()` is public *and* driven by the poll loop, so two can
    /// overlap. Both would see `waiting == nil`, defeating the `alreadyHolding`
    /// dedup and downloading the same DMG twice — and then one could `discard()`
    /// a `PreparedInstall` whose install was already running.
    private var isChecking = false
    /// How many checks in a row have thrown. A permanently wrong `owner`/`repo`
    /// is otherwise the one silent-never-updates path with nothing reporting
    /// it: `hold()` is never reached, so `onWaitingTooLong` cannot fire either.
    private var consecutiveFailures = 0
    private var hasReportedFailures = false

    /// Fired once when checks have been failing for about a day, with the most
    /// recent error. A wrong repository name, a repository gone private, a
    /// release layout upstream stopped recognising: all of them look exactly
    /// like "no update available" from the outside, forever.
    public var onChecksFailing: ((any Error) -> Void)?

    public convenience init(
        owner: String,
        repo: String,
        checkInterval: TimeInterval = 4 * 3600,
        tiptoe: Tiptoe? = nil
    ) {
        self.init(
            updater: AppUpdater(owner: owner, repo: repo),
            checkInterval: checkInterval,
            tiptoe: tiptoe ?? Tiptoe()
        )
    }

    /// Takes a ready-made updater, for a host that wants anything upstream
    /// offers beyond a repository name — `Configuration.attestationPolicy`
    /// above all, which checks GitHub's artifact attestation on the binary
    /// about to replace the running app.
    ///
    /// A whole `AppUpdater` rather than a `Configuration` parameter, because
    /// `allowPrereleases` is a property on the updater and not part of
    /// `Configuration`: passing the object carries both, and carries whatever
    /// upstream adds next without this package growing a parameter for it.
    ///
    /// ```swift
    /// let updater = AppUpdater(
    ///     owner: "kageroumado", repo: "adrafinil",
    ///     configuration: .init(attestationPolicy: GitHubAttestationPolicy(
    ///         workflow: ".github/workflows/release.yml", sourceRef: "refs/heads/main")))
    /// TiptoeGitHub(updater: updater).start()
    /// ```
    public convenience init(
        updater: AppUpdater,
        checkInterval: TimeInterval = 4 * 3600,
        tiptoe: Tiptoe? = nil
    ) {
        // See TiptoeSparkle's initializer: a `Tiptoe()` default argument would
        // shut this file out of hosts whose target is still Swift 5.
        self.init(
            source: AppUpdaterSource(updater: updater),
            checkInterval: checkInterval,
            tiptoe: tiptoe ?? Tiptoe()
        )
    }

    init(source: any UpdateSource, checkInterval: TimeInterval, tiptoe: Tiptoe) {
        self.source = source
        self.checkInterval = checkInterval
        self.tiptoe = tiptoe
        log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tiptoe", category: "tiptoe")
    }

    @discardableResult
    public func gate(_ name: String, _ isSatisfied: @escaping @Sendable () async -> Bool) -> Self {
        tiptoe.gate(name, isSatisfied)
        return self
    }

    @discardableResult
    public func windowsAlwaysBlock() -> Self {
        tiptoe.windowsAlwaysBlock()
        return self
    }

    @discardableResult
    public func start() -> Self {
        guard checkTask == nil else { return self }
        stopped = false
        TiptoeRegistry.retain(self)
        tiptoe.start()
        checkTask = Task { [weak self, interval = checkInterval] in
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(nanoseconds: nanoseconds(interval, fallback: 4 * 3600))
            }
        }
        return self
    }

    public func stop() {
        stopped = true
        checkTask?.cancel()
        checkTask = nil
        tiptoe.stop()
        TiptoeRegistry.release(self)
    }

    /// Check now, download and prepare anything newer, and hand the last step
    /// to ``Tiptoe``. Downloading is invisible, so it needs no quiet moment —
    /// only the swap does.
    public func checkNow() async {
        guard !stopped else { return }
        guard !isChecking else {
            log.debug("a check is already running; leaving it to finish")
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            let latest = try await source.prepareLatest(alreadyHolding: waiting?.version)
            // Reached the source and got an answer — "nothing newer" included.
            consecutiveFailures = 0
            hasReportedFailures = false
            guard let prepared = latest else { return }
            // The check above is a network round trip; `stop()` may have
            // landed while it was in flight. Discard rather than hold —
            // a stopped host must see no state change from a check it
            // never asked to be running.
            guard !stopped else {
                await prepared.discard()
                return
            }
            if let previous = waiting {
                await previous.discard()
            }
            waiting = prepared
            // `false`: mxcl/AppUpdater's `PreparedUpdate` is spent the moment
            // `installAndRelaunch()` is called, success or failure, so it
            // cannot be handed back for a retry the way Sparkle's block can.
            tiptoe.hold(version: prepared.version, retryable: false) { [weak self] in
                try await self?.perform(prepared)
            }
        } catch {
            // A check cancelled by `stop()` is neither a success nor a
            // failure: nothing was learned about the repository, and counting
            // it would let a host that stops and starts often drift into a
            // report about checks that were never allowed to finish.
            guard !isCancellation(error) else {
                log.debug("update check was cancelled")
                return
            }
            // Offline, rate-limited, or the release shape changed. Stay quiet
            // and try again on the next tick.
            log.debug("update check failed: \(error.localizedDescription, privacy: .public)")
            noteFailedCheck(error)
        }
    }

    /// Cancellation reaches here by two spellings: structured concurrency's
    /// own, and `URLError.cancelled` from the `URLSession` task upstream was
    /// waiting on when it was torn down.
    private func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// One failed check is a train tunnel. A day of them is a fault, and the
    /// only one this package can neither wait out nor report through
    /// `Tiptoe` — nothing was ever handed over, so there is no wait to grow
    /// too long.
    private func noteFailedCheck(_ error: any Error) {
        consecutiveFailures += 1
        guard consecutiveFailures >= failureThreshold, !hasReportedFailures else { return }
        hasReportedFailures = true
        log.error("\(self.consecutiveFailures) update checks in a row have failed; the latest: \(error.localizedDescription, privacy: .public)")
        onChecksFailing?(error)
    }

    /// A day's worth of ticks, whatever the host set the interval to.
    private var failureThreshold: Int {
        guard checkInterval.isFinite, checkInterval > 0 else { return 1 }
        return max(1, Int((86400 / checkInterval).rounded()))
    }

    /// Errors propagate rather than being handled here: `Tiptoe` is told, via
    /// `retryable: false` on the `hold` call in `checkNow()`, that a spent
    /// `PreparedInstall` cannot be attempted again — it keeps the wait
    /// running but drops the pending install itself. This only needs to stop
    /// treating the download as still-waiting once an attempt has been made.
    private func perform(_ prepared: PreparedInstall) async throws {
        defer { waiting = nil }
        try await prepared.install()
    }
}
#endif
