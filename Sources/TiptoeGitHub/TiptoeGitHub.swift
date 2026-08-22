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
///
/// Owning the loop is also what lets it answer a question the engine cannot:
/// ``availableVersion``, the newest version published — a weaker and far more
/// available fact than `tiptoe.pending`, which means downloaded and verified.
/// A release that exists but cannot be fetched appears in the first and never
/// in the second, and that is precisely when a host has something worth
/// saying. ``installsAutomatically(_:)`` is the mode where saying it is all
/// the host wants.
@MainActor
public final class TiptoeGitHub {
    public let tiptoe: Tiptoe

    /// The newest published version when it is newer than the running app;
    /// `nil` when this app is the newest there is, and until the first check
    /// has finished. Set by every successful check, in both modes, whether or
    /// not anything was downloaded.
    ///
    /// Deliberately a weaker claim than `tiptoe.pending`, which says the DMG
    /// is downloaded, verified and waiting for a quiet moment. A host drawing
    /// "a new version is out" wants this one: it is true from the moment the
    /// release exists, and it stays true when the download cannot be made —
    /// the case where a host reporting from `pending` alone falls silent
    /// exactly when it had something to report.
    ///
    /// Read it when you draw, the way `pending` and `justUpdatedTo` are read.
    /// Nothing here pushes.
    public private(set) var availableVersion: String?

    private let source: any UpdateSource
    private let checkInterval: TimeInterval
    private let log: Logger
    private var checkTask: Task<Void, Never>?
    private var waiting: PreparedInstall?
    /// Set by `stop()`, cleared by `start()`. `checkNow()` checks it before
    /// and after the (possibly long) network round trip, so a check already
    /// in flight when the host stops cannot land a `hold()` afterward.
    private var stopped = false
    /// Whether a found update is downloaded and handed to the engine, or only
    /// reported. See ``installsAutomatically(_:)``.
    private var installsAuto = true
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

    /// Whether an update the check loop finds is downloaded and installed at a
    /// quiet moment, or only reported through ``availableVersion``.
    ///
    /// For the app that offers "install updates automatically" as a setting.
    /// With it off the loop keeps running, and that is the whole point: the
    /// app can still say a new version exists, out of the same request it was
    /// already making, rather than standing up a second updater beside this
    /// one to answer the same question. Nothing is downloaded and nothing is
    /// ever swapped except through ``updateNow()``, which is a person asking.
    ///
    /// Chainable before ``start()``, and settable at any time after it — this
    /// is a setting somebody can change while the app runs.
    @discardableResult
    public func installsAutomatically(_ enabled: Bool) -> Self {
        guard enabled != installsAuto else { return self }
        installsAuto = enabled
        // Not running: the mode is recorded, and `start()` applies it.
        guard checkTask != nil else { return self }
        applyInstallMode()
        if enabled {
            // The loop's next tick can be most of a day away, and nothing was
            // downloaded while the setting was off — so somebody who just
            // turned this on would watch nothing happen for hours. Ask now.
            Task { await checkNow() }
        }
        return self
    }

    /// The engine follows the mode. Stopped rather than merely never started,
    /// so the `hold()` inside ``updateNow()`` cannot nudge an idle engine into
    /// installing on its own something the host said it would not install on
    /// its own.
    ///
    /// A download already made is left alone either way: a stopped engine
    /// installs nothing, and ``updateNow()`` can still use it if asked.
    private func applyInstallMode() {
        if installsAuto {
            tiptoe.start()
        } else {
            tiptoe.stop()
        }
    }

    @discardableResult
    public func start() -> Self {
        guard checkTask == nil else { return self }
        stopped = false
        TiptoeRegistry.retain(self)
        applyInstallMode()
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
            let outcome = try await source.check(
                alreadyHolding: waiting?.version, prepare: installsAuto
            )
            // Reached the source and got an answer — "nothing newer" included.
            consecutiveFailures = 0
            hasReportedFailures = false
            // The check above is a network round trip; `stop()` may have
            // landed while it was in flight. A stopped host must see no state
            // change from a check it never asked to be running — not a held
            // install, and not the version either.
            guard !stopped else {
                if case .prepared(let prepared) = outcome {
                    await prepared.discard()
                }
                return
            }
            switch outcome {
            case .upToDate:
                availableVersion = nil
            case .available(let version):
                availableVersion = version
            case .prepared(let prepared):
                availableVersion = prepared.version
                await handOver(prepared)
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

    /// Give a fresh download to the engine, throwing away the one it replaces.
    private func handOver(_ prepared: PreparedInstall) async {
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
    }

    /// Download the newest release if it is not downloaded already, then
    /// install it right now, whatever the Mac is doing. For a host acting on
    /// an explicit request from a person, and only then: no quiet moment is
    /// waited out and no gate is asked, because somebody asked.
    ///
    /// This is how a host that reports without installing acts on what
    /// ``availableVersion`` told it, and the reason that mode is a mode rather
    /// than a dead end. It is also the one to call from an "Update Now" button
    /// in either mode — `tiptoe.installNow()` installs what is already held,
    /// which in the reporting mode is nothing.
    ///
    /// Returns false when there was nothing newer to install, or when the
    /// download could not be prepared: the two outcomes a host can still say
    /// something useful about. A successful install replaces the process, so
    /// nothing meaningful comes back on that path.
    @discardableResult
    public func updateNow() async -> Bool {
        if waiting == nil {
            guard !isChecking else {
                log.debug("a check is already running; not starting a second one for an explicit install")
                return false
            }
            isChecking = true
            defer { isChecking = false }
            do {
                let outcome = try await source.check(alreadyHolding: nil, prepare: true)
                // Reaching the repository says as much here as it does from
                // the loop. A failure does not count the other way, though:
                // the streak is calibrated to a day of ticks, and somebody
                // pressing a button on a train would otherwise spend it.
                consecutiveFailures = 0
                hasReportedFailures = false
                switch outcome {
                case .upToDate:
                    availableVersion = nil
                    return false
                case .available(let version):
                    availableVersion = version
                    return false
                case .prepared(let prepared):
                    availableVersion = prepared.version
                    await handOver(prepared)
                }
            } catch {
                log.error("preparing an update somebody asked for failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        await tiptoe.installNow().value
        return true
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
