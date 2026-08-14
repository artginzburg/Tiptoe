#if SparkleSupport
import AppKit
import Sparkle
import os

// Conditional because this file is also meant to be compiled *into* a host's
// own target, source-level, by an app that cannot link the product — one that
// ships to the App Store from the same target, where linking anything Sparkle
// would be fatal, and SwiftPM cannot vary linkage per build configuration.
// Compiled that way there is no separate Tiptoe module to import, and the
// types are already in scope.
#if canImport(Tiptoe)
import Tiptoe
#endif

/// Tiptoe for a sandboxed app.
///
/// A sandboxed app cannot replace its own bundle, which rules out every
/// lightweight updater — they all say "non-sandboxed only" — and leaves the one
/// framework whose answer is an XPC service running outside the sandbox.
///
/// Sparkle would install a downloaded update the next time the app quits, which
/// for a login-item agent can be never. This adapter takes that decision over
/// and gives it to ``Tiptoe``.
@MainActor
public final class TiptoeSparkle: NSObject {
    public let tiptoe: Tiptoe
    private var controller: SPUStandardUpdaterController?
    private let log: Logger

    public init(tiptoe: Tiptoe? = nil) {
        // Not a default argument of `Tiptoe()`: evaluating one inside a
        // `@MainActor` initializer is a Swift 6 rule, and this file is also
        // compiled straight into hosts whose target is still Swift 5.
        self.tiptoe = tiptoe ?? Tiptoe()
        log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tiptoe", category: "tiptoe")
        super.init()
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

    /// Starting the updater schedules the first background check on Sparkle's
    /// own cycle — nothing is checked at launch, so a fresh install spends its
    /// first seconds on the person rather than on a network call.
    ///
    /// This adapter is inert unless the host's Info.plist enables automatic
    /// downloads: everything here hangs on `willInstallUpdateOnQuit`, which
    /// Sparkle only calls once it has downloaded an update by itself. See the
    /// README's "Sparkle setup".
    @discardableResult
    public func start() -> Self {
        guard controller == nil else { return self }
        TiptoeRegistry.retain(self)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        // Reported rather than corrected: Sparkle's own documentation is
        // explicit that an app must not override this at launch, because it is
        // the person's preference to make. Without it, though, nothing here
        // ever runs and the log would otherwise be empty — which is the worst
        // possible symptom for a package whose whole job is to be invisible.
        if !controller.updater.automaticallyDownloadsUpdates {
            log.error("Sparkle is not downloading updates automatically, so Tiptoe will never be handed one: set SUAutomaticallyUpdate (and SUEnableAutomaticChecks) to true in the app's Info.plist")
        }
        tiptoe.start()
        return self
    }

    public func stop() {
        tiptoe.stop()
        controller = nil
        TiptoeRegistry.release(self)
    }

    /// For a "Check for Updates…" menu row. Deliberately routed through
    /// Sparkle's own UI: a check somebody asked for is the one moment where a
    /// window, a progress bar and the release notes are the point rather than
    /// an interruption.
    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// False while a check is already running — what such a menu row disables
    /// itself on.
    public var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }
}

extension TiptoeSparkle: SPUUpdaterDelegate {
    /// Returning true is a contract: Sparkle runs no further update cycles
    /// until this block is called, so it must not be dropped on the floor.
    nonisolated public func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping @Sendable () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            tiptoe.hold(version: item.displayVersionString) {
                immediateInstallHandler()
            }
        }
        return true
    }

    nonisolated public func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard let error else { return }
        // "No update found" is reported as an error on a check somebody asked
        // for; Sparkle has already said so, and it is not a fault.
        guard (error as NSError).code != Int(SUError.noUpdateError.rawValue) else { return }
        MainActor.assumeIsolated {
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension TiptoeSparkle: SPUStandardUserDriverDelegate {
    /// Declares this app as one that should never have an update alert steal
    /// focus. It rarely comes up — holding the install stalls Sparkle's own
    /// scheduling too, so there is nothing left for it to nag about — but a
    /// critical update can still be pushed through, and when it is, it should
    /// arrive behind whatever the person is doing.
    nonisolated public var supportsGentleScheduledUpdateReminders: Bool { true }
}
#endif
