import Foundation
import Testing

@testable import Tiptoe

private struct HarnessInstallFailure: Error {}

/// The world the engine measures. A reference box because `Environment`'s
/// closures are `@Sendable` and must not capture the test's own state directly.
private final class Box: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var secondsSinceInput: TimeInterval = 9999
    var windows = WindowSnapshot(hasVisibleMainCapableWindow: false, hasUnsavedWork: false)
    var appVersion = "1.3.0"
}

@MainActor
private final class Harness {
    let box = Box()
    let tiptoe: Tiptoe
    let defaults: UserDefaults
    var installs = 0

    /// `seed` runs against the persisted store *before* the engine is built,
    /// standing in for a previous run of the app — which is the only way to
    /// reach the reconciliation that happens in `init`.
    init(
        policy: QuietPolicy = .default,
        appVersion: String = "1.3.0",
        seed: (Store) -> Void = { _ in }
    ) {
        let suite = "TiptoeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        box.appVersion = appVersion
        seed(Store(defaults: defaults))

        let box = box
        tiptoe = Tiptoe(
            policy: policy,
            environment: Tiptoe.Environment(
                now: { box.now },
                secondsSinceInput: { box.secondsSinceInput },
                windows: { box.windows },
                appVersion: { box.appVersion }
            ),
            defaults: defaults
        )
    }

    func hold(_ version: String = "1.4.0") {
        tiptoe.hold(version: version) { [weak self] in
            self?.installs += 1
        }
    }
}

@MainActor
@Test func installsAsSoonAsTheMacIsStill() async {
    let harness = Harness()
    harness.hold()
    #expect(harness.tiptoe.pending?.version == "1.4.0")

    await harness.tiptoe.evaluate()

    #expect(harness.installs == 1)
    #expect(harness.tiptoe.pending == nil)
    #expect(harness.tiptoe.justUpdatedTo == "1.4.0")
}

@MainActor
@Test func waitsWhileSomebodyIsUsingTheMac() async {
    let harness = Harness()
    harness.box.secondsSinceInput = 3
    harness.hold()

    await harness.tiptoe.evaluate()

    #expect(harness.installs == 0)
    #expect(harness.tiptoe.pending != nil)
}

@MainActor
@Test func aHostGateOverridesPerfectStillness() async {
    let harness = Harness()
    harness.tiptoe.gate("agents are working") { false }
    harness.hold()

    await harness.tiptoe.evaluate()

    #expect(harness.installs == 0)
}

@MainActor
@Test func aGateThatNeverAnswersBlocksTheInstall() async {
    var policy = QuietPolicy.default
    policy.gateTimeout = 0.05
    let harness = Harness(policy: policy)
    harness.tiptoe.gate("dead daemon") {
        try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
        return true
    }
    harness.hold()

    await harness.tiptoe.evaluate()

    #expect(harness.installs == 0)
}

/// `evaluate()` reads the sensors once, then awaits every gate — each of which
/// may take up to `policy.gateTimeout` to answer. This gate uses that window:
/// it reports quiet stillness, waits briefly, then makes the Mac busy right
/// before answering. The install must not go through on the stale reading.
@MainActor
@Test func stillnessIsRecheckedAfterAGateAnswers() async {
    let harness = Harness()
    let box = harness.box
    harness.tiptoe.gate("slow daemon") {
        try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
        box.secondsSinceInput = 0
        return true
    }
    harness.hold()

    await harness.tiptoe.evaluate()

    #expect(harness.installs == 0)
}

@MainActor
@Test func theClockKeepsRunningWhenANewerVersionReplacesTheWaitingOne() async {
    let harness = Harness()
    harness.box.secondsSinceInput = 3
    harness.hold("1.4.0")
    let started = harness.tiptoe.pending?.waitingSince

    harness.box.now = harness.box.now.addingTimeInterval(3 * 86400)
    harness.hold("1.4.1")

    #expect(harness.tiptoe.pending?.version == "1.4.1")
    #expect(harness.tiptoe.pending?.waitingSince == started)
}

@MainActor
@Test func afterAWeekOfWaitingAnOpenWindowStopsBlocking() async {
    let harness = Harness()
    harness.box.windows = WindowSnapshot(hasVisibleMainCapableWindow: true, hasUnsavedWork: false)
    harness.hold()
    await harness.tiptoe.evaluate()
    #expect(harness.installs == 0)

    harness.box.now = harness.box.now.addingTimeInterval(8 * 86400)
    harness.box.secondsSinceInput = 6
    await harness.tiptoe.evaluate()

    #expect(harness.installs == 1)
}

@MainActor
@Test func aVeryLongWaitTellsTheHostOnceAndKeepsWaiting() async {
    let harness = Harness()
    var told: [String] = []
    harness.tiptoe.onWaitingTooLong = { told.append($0.version) }
    harness.tiptoe.gate("agents are working") { false }
    harness.hold()

    await harness.tiptoe.evaluate()
    #expect(told.isEmpty)

    harness.box.now = harness.box.now.addingTimeInterval(15 * 86400)
    await harness.tiptoe.evaluate()
    await harness.tiptoe.evaluate()

    #expect(told == ["1.4.0"])
    #expect(harness.installs == 0)
}

@MainActor
@Test func aPersonWhoAsksGetsTheUpdateImmediately() async {
    let harness = Harness()
    harness.box.secondsSinceInput = 0
    harness.box.windows = WindowSnapshot(hasVisibleMainCapableWindow: true, hasUnsavedWork: true)
    harness.tiptoe.gate("agents are working") { false }
    harness.hold()

    await harness.tiptoe.installNow().value

    #expect(harness.installs == 1)
}

/// Covers the case where a tick was already queued — by `hold()`, or by the
/// poller — when the host called `stop()`. The tick still runs, but must not
/// install. (The narrower race, of `stop()` landing while a gate is being
/// awaited mid-`evaluate()`, cannot be driven deterministically without a
/// sleep, so it is not covered here; the same `stopped` check that this test
/// exercises is what guards that path too.)
@MainActor
@Test func stoppingPreventsAnInstallAlreadyQueuedByHold() async {
    let harness = Harness()
    harness.hold()
    harness.tiptoe.stop()

    await harness.tiptoe.evaluate()

    #expect(harness.installs == 0)
    #expect(harness.tiptoe.pending != nil)
}

@MainActor
@Test func acknowledgingClearsTheNotice() async {
    let harness = Harness()
    harness.hold()
    await harness.tiptoe.evaluate()

    #expect(harness.tiptoe.justUpdatedTo == "1.4.0")
    harness.tiptoe.acknowledge()
    #expect(harness.tiptoe.justUpdatedTo == nil)
}

/// A throwing `install` is a failed *attempt*: `retryable` (the default)
/// means the closure itself can still be invoked again, so the whole wait —
/// version, clock, closure — goes back exactly as it stood.
@MainActor
@Test func aThrowingRetryableInstallRestoresTheWaitForAnotherAttempt() async {
    let harness = Harness()
    harness.tiptoe.hold(version: "1.4.0") {
        throw HarnessInstallFailure()
    }
    let waitingSince = harness.tiptoe.pending?.waitingSince

    await harness.tiptoe.evaluate()

    #expect(harness.tiptoe.pending?.version == "1.4.0")
    #expect(harness.tiptoe.pending?.waitingSince == waitingSince)
    #expect(harness.tiptoe.justUpdatedTo == nil)
}

/// `retryable: false` is for a closure that is spent after one call, success
/// or failure — an adapter says so at handover time, so the core never needs
/// to be told afterward. The wait keeps running (nothing claims a false
/// "updated"), but nothing is left for the poll loop to retry.
@MainActor
@Test func aThrowingOneShotInstallLeavesNothingToRetry() async {
    let harness = Harness()
    harness.tiptoe.hold(version: "1.4.0", retryable: false) {
        throw HarnessInstallFailure()
    }
    let waitingSince = harness.tiptoe.pending?.waitingSince

    await harness.tiptoe.evaluate()

    #expect(harness.tiptoe.pending == nil)
    #expect(harness.tiptoe.justUpdatedTo == nil)

    // `pending` is nil now, so the persisted clock can only be read by
    // holding again — advance time first, so a clock that had actually been
    // reset (rather than merely left alone) would show up as a later value.
    harness.box.now = harness.box.now.addingTimeInterval(3 * 86400)
    harness.hold("1.4.0")
    #expect(harness.tiptoe.pending?.waitingSince == waitingSince)
}

// MARK: - A wait only counts while it is still this app's own wait

/// Sparkle installs a pending update when the app quits, and a person quitting
/// in the evening is the ordinary case, not the exception. Homebrew and a
/// hand-downloaded DMG do the same on the GitHub path. Nothing about those
/// routes goes through `install()`, so without reconciliation the clock keeps
/// running for months and the *next* update lands on the seven-day rung on its
/// first evaluation.
@MainActor
@Test func anUpdateThatLandedSomeOtherWayEndsTheWaitAndIsStillWorthShowing() {
    let harness = Harness(appVersion: "1.4.0") { store in
        store.waitingSince = Date(timeIntervalSince1970: 900_000)
        store.pendingVersion = "1.4.0"
        store.appVersion = "1.3.0"
    }

    #expect(harness.tiptoe.justUpdatedTo == "1.4.0")
    #expect(Store(defaults: harness.defaults).waitingSince == nil)
}

/// The app changed, but not to the version that was waiting — somebody dragged
/// a different build in, or downgraded. Nothing can be claimed as an update;
/// the only safe reading is that this wait is over.
@MainActor
@Test func anUnrelatedVersionChangeEndsTheWaitAndClaimsNothing() {
    let harness = Harness(appVersion: "1.2.0") { store in
        store.waitingSince = Date(timeIntervalSince1970: 900_000)
        store.pendingVersion = "1.4.0"
        store.appVersion = "1.3.0"
    }

    #expect(harness.tiptoe.justUpdatedTo == nil)
    #expect(Store(defaults: harness.defaults).waitingSince == nil)
}

@MainActor
@Test func aWaitBelongingToTheRunningAppSurvivesTheNextLaunch() {
    let started = Date(timeIntervalSince1970: 900_000)
    let harness = Harness(appVersion: "1.3.0") { store in
        store.waitingSince = started
        store.pendingVersion = "1.4.0"
        store.appVersion = "1.3.0"
    }

    #expect(Store(defaults: harness.defaults).waitingSince == started)
    // And the ladder still reads it as one continuous wait.
    harness.box.secondsSinceInput = 3
    harness.hold("1.4.0")
    #expect(harness.tiptoe.pending?.waitingSince == started)
}

/// The versions on either side of that comparison come from different places
/// — the tag through the adapter, the bundle through the environment — and
/// can spell one version two ways. `v1.4.0` landing where `1.4` now runs is
/// still the update that was waiting.
@MainActor
@Test func anUpdateThatLandedSomeOtherWayIsStillRecognisedAcrossSpellings() {
    let harness = Harness(appVersion: "1.4") { store in
        store.waitingSince = Date(timeIntervalSince1970: 900_000)
        store.pendingVersion = "v1.4.0"
        store.appVersion = "1.3"
    }

    #expect(harness.tiptoe.justUpdatedTo == "1.4")
    #expect(Store(defaults: harness.defaults).waitingSince == nil)
}

/// A Mac whose clock was wrong at boot — before NTP corrected it — can leave
/// behind a wait nobody served. Seven days of genuine waiting is what makes
/// the last rung defensible; 200 days that passed in a second is not.
@MainActor
@Test func aWaitFromAnImpossiblyLongAgoIsNotTrusted() {
    let harness = Harness(appVersion: "1.3.0") { store in
        store.waitingSince = Date(timeIntervalSince1970: 1_000_000 - 200 * 86400)
        store.pendingVersion = "1.4.0"
        store.appVersion = "1.3.0"
    }

    #expect(Store(defaults: harness.defaults).waitingSince == nil)
    #expect(harness.tiptoe.justUpdatedTo == nil)
}

// MARK: - A notice only counts while it names the running app

/// `justUpdatedTo` is cleared by `acknowledge()`, and a person who never opens
/// the place the host shows it in never acknowledges. Meanwhile the next
/// version arrives by Homebrew or a dragged-in DMG — nothing that goes through
/// `install()` — and 1.12 launches announcing "Updated to 1.11".
@MainActor
@Test func aNoticeForAVersionNoLongerRunningIsDropped() {
    let harness = Harness(appVersion: "1.5.0") { store in
        store.justUpdatedTo = "1.4.0"
    }

    #expect(harness.tiptoe.justUpdatedTo == nil)
    // Dropped from the store too, so the next launch has nothing to reconcile.
    #expect(Store(defaults: harness.defaults).justUpdatedTo == nil)
}

/// A downgrade is the same story told backwards: nothing was installed, so
/// nothing is announced.
@MainActor
@Test func aNoticeFromAVersionNewerThanTheRunningOneIsDropped() {
    let harness = Harness(appVersion: "1.3.0") { store in
        store.justUpdatedTo = "1.4.0"
    }

    #expect(harness.tiptoe.justUpdatedTo == nil)
}

@MainActor
@Test func aNoticeForTheRunningVersionWaitsToBeAcknowledged() {
    let harness = Harness(appVersion: "1.4.0") { store in
        store.justUpdatedTo = "1.4.0"
    }

    #expect(harness.tiptoe.justUpdatedTo == "1.4.0")
}

/// The notice is written from the tag's version and checked against the
/// bundle's, and a host whose bundle carries `1.5` for the `v1.5.0` release
/// must not lose every notice to the spelling.
@MainActor
@Test func aNoticeSurvivesTheTagAndTheBundleSpellingTheVersionDifferently() {
    let harness = Harness(appVersion: "1.5") { store in
        store.justUpdatedTo = "1.5.0"
    }

    #expect(harness.tiptoe.justUpdatedTo == "1.5.0")
}

/// With nothing to install there is nothing to poll for, and a timer that
/// wakes the app once a minute to learn that is a cost paid all day long.
@MainActor
@Test func pollsOnlyWhileAnUpdateIsWaiting() async {
    let harness = Harness(policy: fastPolling)
    harness.box.secondsSinceInput = 3
    harness.tiptoe.start()
    defer { harness.tiptoe.stop() }
    #expect(!harness.tiptoe.isPolling)

    harness.hold()
    #expect(harness.tiptoe.isPolling)

    await letTheHoldEvaluationPass()
    harness.box.secondsSinceInput = 9999
    #expect(await eventually { harness.installs == 1 })
    #expect(await eventually { !harness.tiptoe.isPolling })
}

/// The install the loop itself lands must not run inside a task the loop has
/// cancelled on the way: mxcl/AppUpdater's relaunch sleeps, and a sleep in a
/// cancelled task throws at once, so every silent install would fail.
@MainActor
@Test func anInstallTheLoopLandsIsNotCancelled() async {
    let harness = Harness(policy: fastPolling)
    harness.box.secondsSinceInput = 3
    harness.tiptoe.start()
    defer { harness.tiptoe.stop() }
    var completed = false
    harness.tiptoe.hold(version: "1.4.0", retryable: false) {
        try await Task.sleep(nanoseconds: 1_000_000)
        completed = true
    }

    await letTheHoldEvaluationPass()
    harness.box.secondsSinceInput = 9999
    #expect(await eventually { completed })
}

@MainActor
@Test func aRetryableInstallThatFailedKeepsThePollGoing() async {
    let harness = Harness(policy: fastPolling)
    harness.box.secondsSinceInput = 3
    harness.tiptoe.start()
    defer { harness.tiptoe.stop() }
    var attempts = 0
    harness.tiptoe.hold(version: "1.4.0") {
        attempts += 1
        throw HarnessInstallFailure()
    }

    await letTheHoldEvaluationPass()
    harness.box.secondsSinceInput = 9999
    #expect(await eventually { attempts >= 3 })
    #expect(harness.tiptoe.pending != nil)
    #expect(harness.tiptoe.isPolling)
}

/// Held while stopped, the evaluation `hold()` spawns does nothing, so
/// `start()` looks at once rather than a whole poll interval later.
@MainActor
@Test func anUpdateHeldWhileStoppedIsLookedAtOnStart() async {
    let harness = Harness()
    harness.tiptoe.start()
    harness.tiptoe.stop()
    harness.hold()
    await letTheHoldEvaluationPass()
    #expect(harness.installs == 0)
    #expect(!harness.tiptoe.isPolling)

    harness.tiptoe.start()
    defer { harness.tiptoe.stop() }
    #expect(await eventually { harness.installs == 1 })
}

private var fastPolling: QuietPolicy {
    var policy = QuietPolicy.default
    policy.pollInterval = 0.01
    return policy
}

/// `hold()` evaluates at once, in a task of its own. Going quiet before that
/// runs would let it, rather than the loop, land the install.
@MainActor
private func letTheHoldEvaluationPass() async {
    try? await Task.sleep(nanoseconds: 50_000_000)
}

/// Waits for something the poll loop does on its own schedule.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
