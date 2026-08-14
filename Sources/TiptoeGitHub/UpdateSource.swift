#if GitHubSupport
import AppUpdater
import Foundation

/// One prepared update, reduced to the two things Tiptoe needs from it.
struct PreparedInstall {
    let version: String
    let install: @MainActor @Sendable () async throws -> Void
    let discard: @MainActor @Sendable () async -> Void
}

/// Where updates come from. A protocol so the check loop can be tested without
/// a network, a GitHub repository or a signed build.
///
/// `alreadyHolding` is the version Tiptoe is already sitting on, if any — so a
/// source that finds the same release again can skip the expensive part
/// rather than downloading a DMG it is about to throw away.
@MainActor
protocol UpdateSource {
    func prepareLatest(alreadyHolding version: String?) async throws -> PreparedInstall?
}

/// The real one: mxcl/AppUpdater, which checks GitHub Releases, downloads the
/// DMG, verifies the Team ID against the running app and prepares the swap —
/// stopping one call short of performing it. That last call is what Tiptoe holds.
@MainActor
struct AppUpdaterSource: UpdateSource {
    let updater: AppUpdater

    func prepareLatest(alreadyHolding version: String?) async throws -> PreparedInstall? {
        guard let update = try await updater.check() else { return nil }
        // Checking is cheap — it is one API call for release metadata.
        // Preparing downloads and verifies the DMG. Without this, a release
        // that is already waiting gets re-downloaded on every tick for as
        // long as it waits, only to be discarded each time.
        guard update.version != version else {
            await update.discard()
            return nil
        }
        let prepared = try await update.prepareInstallation()
        return PreparedInstall(
            version: update.version,
            install: { try await prepared.installAndRelaunch() },
            discard: { await prepared.discard() }
        )
    }
}
#endif
