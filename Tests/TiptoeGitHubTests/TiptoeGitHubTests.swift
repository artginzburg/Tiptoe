#if GitHubSupport
import Foundation
import Testing

@testable import Tiptoe
@testable import TiptoeGitHub

private struct StubInstallFailure: Error {}
private struct StubCheckFailure: Error {}

/// A repository name that is simply wrong, or one that went private: every
/// check throws, forever, and nothing else in the package is in a position to
/// notice, because no update is ever handed over to wait.
@MainActor
private final class FailingSource: UpdateSource {
    var checks = 0
    var error: any Error = StubCheckFailure()
    /// Set to stop throwing: the repository came back, or the Mac came off
    /// the aeroplane. Answers "nothing newer", which is a successful check.
    var succeeds = false

    func prepareLatest(alreadyHolding version: String?) async throws -> PreparedInstall? {
        checks += 1
        guard succeeds else { throw error }
        return nil
    }
}

@MainActor
private final class StubSource: UpdateSource {
    var version = "2.0.0"
    var installs = 0
    var discards = 0
    var checks = 0
    /// How many times a `PreparedInstall` was actually handed back, as
    /// opposed to `checks`, which counts every call including the ones the
    /// `alreadyHolding` dedup turns away.
    var prepares = 0
    var failInstall = false
    /// Run from inside `prepareLatest`, before it returns — lets a test act
    /// as though something happened while the "network" round trip was in
    /// flight, without a real race or a sleep.
    var onPrepare: (@MainActor () async -> Void)?
    /// How deep `prepareLatest` is currently nested, and the depth past which
    /// `onPrepare` stops being run. A `checkNow()` that had lost its
    /// reentrancy guard would recurse through `onPrepare` until the process
    /// died; the cap turns that into a failed expectation instead.
    private(set) var depth = 0
    var deepestReentry = 4

    func prepareLatest(alreadyHolding heldVersion: String?) async throws -> PreparedInstall? {
        checks += 1
        depth += 1
        defer { depth -= 1 }
        if depth <= deepestReentry {
            await onPrepare?()
        }
        guard version != heldVersion else { return nil }
        prepares += 1
        return PreparedInstall(
            version: version,
            install: { @MainActor [self] in
                installs += 1
                if failInstall { throw StubInstallFailure() }
            },
            discard: { @MainActor [self] in discards += 1 }
        )
    }
}

@MainActor
private func harness(_ source: any UpdateSource, checkInterval: TimeInterval = 3600) -> (TiptoeGitHub, Tiptoe) {
    let suite = "TiptoeGitHubTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let box = QuietBox()
    let tiptoe = Tiptoe(
        policy: .default,
        environment: Tiptoe.Environment(
            now: { box.now },
            secondsSinceInput: { box.idle },
            windows: { WindowSnapshot(hasVisibleMainCapableWindow: false, hasUnsavedWork: false) }
        ),
        defaults: defaults
    )
    return (TiptoeGitHub(source: source, checkInterval: checkInterval, tiptoe: tiptoe), tiptoe)
}

private final class QuietBox: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var idle: TimeInterval = 9999
}

@MainActor
@Test func aFoundUpdateIsHandedToTiptoeRatherThanInstalledOnTheSpot() async {
    let source = StubSource()
    let (github, tiptoe) = harness(source)

    await github.checkNow()

    #expect(source.installs == 0)
    #expect(tiptoe.pending?.version == "2.0.0")
}

@MainActor
@Test func theQuietMomentIsWhatInstallsIt() async {
    let source = StubSource()
    let (github, tiptoe) = harness(source)

    await github.checkNow()
    await tiptoe.evaluate()

    #expect(source.installs == 1)
}

@MainActor
@Test func aNewerVersionReplacesTheWaitingOneAndThrowsItsDownloadAway() async {
    let source = StubSource()
    let (github, tiptoe) = harness(source)

    await github.checkNow()
    source.version = "2.0.1"
    await github.checkNow()

    #expect(source.discards == 1)
    #expect(tiptoe.pending?.version == "2.0.1")
}

/// Task 6 review, defect 1: `checkNow()` used to call `prepareLatest()`
/// unconditionally, so a release that was already waiting got re-downloaded
/// — and thrown away — on every tick for as long as it waited.
@MainActor
@Test func checkingAgainAtTheSameVersionDoesNotPrepareItTwice() async {
    let source = StubSource()
    let (github, _) = harness(source)

    await github.checkNow()
    await github.checkNow()
    #expect(source.prepares == 1)

    source.version = "2.0.1"
    await github.checkNow()
    #expect(source.prepares == 2)
}

/// Task 6 review, defect 2: `Tiptoe.install()` wrote `justUpdatedTo` and
/// cleared the wait before awaiting the install closure — correct for
/// Sparkle, where the process does not survive success, but wrong once that
/// closure can throw and the process keeps running. A failed install must
/// leave the wait exactly as it was, not a false "updated" notice.
///
/// Round 2: `checkNow()` now passes `retryable: false` to `hold`, since
/// mxcl/AppUpdater's `PreparedUpdate` is spent the moment `install` runs,
/// success or failure — unlike Sparkle's block, it cannot be handed back for
/// another attempt. So the wait itself survives (the app is still waiting
/// for an update), but this particular download does not: no `pending`, no
/// false "updated" notice. Built without `harness()` so the same
/// `UserDefaults` suite backing `tiptoe` can be reopened afterward as a
/// fresh `Store`, the way `StoreTests.swift` verifies persistence.
@MainActor
@Test func aFailedInstallDropsTheSpentDownloadButKeepsTheWaitGoing() async {
    let suite = "TiptoeGitHubTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let box = QuietBox()
    let tiptoe = Tiptoe(
        policy: .default,
        environment: Tiptoe.Environment(
            now: { box.now },
            secondsSinceInput: { box.idle },
            windows: { WindowSnapshot(hasVisibleMainCapableWindow: false, hasUnsavedWork: false) }
        ),
        defaults: defaults
    )
    let source = StubSource()
    source.failInstall = true
    let github = TiptoeGitHub(source: source, checkInterval: 3600, tiptoe: tiptoe)

    await github.checkNow()
    let waitingSince = tiptoe.pending?.waitingSince
    await tiptoe.evaluate()

    #expect(source.installs == 1)
    #expect(tiptoe.pending == nil)
    #expect(tiptoe.justUpdatedTo == nil)
    #expect(Store(defaults: defaults).waitingSince == waitingSince)
}

/// Task 6 review, defect 3: `stop()` cancelled the poll loop, but a check
/// already in flight had nothing observing cancellation, so its download
/// could still land a `hold()` — mutating persisted state — after the host
/// had explicitly stopped. `source.onPrepare` stands in for "the host called
/// stop() while the network round trip was in flight," without a real race.
@MainActor
@Test func stoppingMidCheckDiscardsTheDownloadAndHoldsNothing() async {
    let source = StubSource()
    let (github, tiptoe) = harness(source)
    source.onPrepare = { [weak github] in github?.stop() }

    await github.checkNow()

    #expect(tiptoe.pending == nil)
    #expect(source.discards == 1)
}

/// `checkNow()` is public *and* driven by the poll loop, so two really can
/// overlap. Both would see `waiting == nil` — defeating the `alreadyHolding`
/// dedup that keeps the same DMG from being downloaded twice — and the second
/// could then `discard()` a prepared install whose install was already
/// running. `onPrepare` reenters from inside the first check, which is exactly
/// the window that matters, without a real race.
///
/// What is asserted is that the second call never reaches the source at all:
/// one check, one download, nothing discarded, and the one update held. The
/// stub stops recursing after a few levels, so a `checkNow()` without its
/// guard fails these expectations rather than exhausting the process.
@MainActor
@Test func aSecondCheckArrivingMidCheckDoesNothing() async {
    let source = StubSource()
    let (github, tiptoe) = harness(source)
    source.onPrepare = { [weak github] in
        guard let github else { return }
        await github.checkNow()
    }

    await github.checkNow()

    #expect(source.checks == 1)
    #expect(source.prepares == 1)
    #expect(source.discards == 0)
    #expect(tiptoe.pending?.version == "2.0.0")
}

/// A permanently wrong `owner`/`repo` looks exactly like "no update available"
/// from the outside, forever — and because nothing is ever handed to `Tiptoe`,
/// the long-wait escalation cannot report it either. Told once, after about a
/// day of ticks, and not again until a check succeeds.
@MainActor
@Test func checksThatKeepFailingAreReportedOnceAfterADay() async {
    let source = FailingSource()
    // 12 h between checks, so a day's worth is two ticks.
    let (github, _) = harness(source, checkInterval: 12 * 3600)
    var reported = 0
    github.onChecksFailing = { _ in reported += 1 }

    await github.checkNow()
    #expect(reported == 0)

    await github.checkNow()
    await github.checkNow()
    #expect(reported == 1)
    #expect(source.checks == 3)
}

/// One check reaching the repository says everything before it was weather,
/// not a fault — so the streak starts over, and a fault that comes back later
/// is worth reporting again.
@MainActor
@Test func aCheckThatSucceedsStartsTheFailureCountOver() async {
    let source = FailingSource()
    let (github, _) = harness(source, checkInterval: 12 * 3600)
    var reported = 0
    github.onChecksFailing = { _ in reported += 1 }

    await github.checkNow()
    await github.checkNow()
    #expect(reported == 1)

    source.succeeds = true
    await github.checkNow()

    source.succeeds = false
    await github.checkNow()
    // Would already be the third failure in a row, and reported, if the
    // successful check had not cleared the count.
    #expect(reported == 1)

    await github.checkNow()
    #expect(reported == 2)
}

/// `stop()` cancels a check in flight, and the cancellation surfaces as a
/// throw like any other. Counting it would let a host that stops and starts
/// often — a menu bar app following a preference, say — drift into a report
/// about checks that were never allowed to finish.
@MainActor
@Test func aCancelledCheckIsNotHeldAgainstTheRepository() async {
    let source = FailingSource()
    let (github, _) = harness(source, checkInterval: 12 * 3600)
    var reported = 0
    github.onChecksFailing = { _ in reported += 1 }

    source.error = CancellationError()
    for _ in 0..<5 { await github.checkNow() }
    #expect(reported == 0)

    source.error = URLError(.cancelled)
    for _ in 0..<5 { await github.checkNow() }
    #expect(reported == 0)

    // A real fault still counts, from a streak of zero.
    source.error = StubCheckFailure()
    await github.checkNow()
    #expect(reported == 0)
    await github.checkNow()
    #expect(reported == 1)
}
#endif
