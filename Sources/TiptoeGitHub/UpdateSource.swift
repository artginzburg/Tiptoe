#if GitHubSupport
import AppUpdater
import Foundation

/// One prepared update, reduced to the two things Tiptoe needs from it.
struct PreparedInstall {
    let version: String
    let install: @MainActor @Sendable () async throws -> Void
    let discard: @MainActor @Sendable () async -> Void
}

/// What a check found.
///
/// The two halves of a check cost wildly different things — one API call for
/// release metadata, against downloading and verifying a disk image — and
/// there are two reasons to stop after the cheap half: the release found is
/// the one already waiting, and a host that has been told not to install
/// anything by itself. Either way the version was learned, and a host that
/// only wants to *say* a new version exists needs nothing more than that.
enum CheckOutcome {
    /// Nothing newer than the running app.
    case upToDate
    /// A newer release exists, and nothing was downloaded.
    case available(String)
    /// A newer release exists, downloaded and verified, one call short of
    /// replacing the app.
    case prepared(PreparedInstall)
}

/// Where updates come from. A protocol so the check loop can be tested without
/// a network, a GitHub repository or a signed build.
@MainActor
protocol UpdateSource {
    /// - Parameters:
    ///   - version: the version Tiptoe is already sitting on, if any — so a
    ///     source that finds the same release again can skip the expensive
    ///     part rather than downloading a DMG it is about to throw away.
    ///   - prepare: whether the download may happen at all. False for a host
    ///     that is only reporting what exists, which has no business spending
    ///     somebody's bandwidth on a disk image it will never install.
    func check(alreadyHolding version: String?, prepare: Bool) async throws -> CheckOutcome
}

/// The real one: mxcl/AppUpdater, which checks GitHub Releases, downloads the
/// DMG, verifies the Team ID against the running app and prepares the swap —
/// stopping one call short of performing it. That last call is what Tiptoe holds.
@MainActor
struct AppUpdaterSource: UpdateSource {
    let updater: AppUpdater

    func check(alreadyHolding version: String?, prepare: Bool) async throws -> CheckOutcome {
        guard let update = try await updater.check() else { return .upToDate }
        // Checking is cheap — it is one API call for release metadata.
        // Preparing downloads and verifies the DMG. Without the second
        // condition, a release that is already waiting gets re-downloaded on
        // every tick for as long as it waits, only to be discarded each time.
        guard prepare, update.version != version else {
            await update.discard()
            return .available(update.version)
        }
        let prepared = try await update.prepareInstallation()
        return .prepared(PreparedInstall(
            version: update.version,
            install: { try await prepared.installAndRelaunch() },
            discard: { await prepared.discard() }
        ))
    }
}
#endif
