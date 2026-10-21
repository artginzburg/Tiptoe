# Tiptoe

Holds a downloaded macOS app update back until the Mac is quiet and the host app says it's safe, then installs it with no UI at all.

[![Tests](https://github.com/artginzburg/Tiptoe/actions/workflows/tests.yml/badge.svg)](https://github.com/artginzburg/Tiptoe/actions/workflows/tests.yml)

## The idea

An app that updates itself should be able to do it without ever taking a moment from the person using the Mac: no alert, no click, no "relaunch now?". Downloading is invisible already — it runs in the background, on its own schedule. It is the *swap* that interrupts: a window disappears and reappears, or the app quits mid-task. So the swap waits, for as long as it takes, until nobody is there to notice.

WheelClick has shipped exactly this experience since 1.0.3.

Tiptoe is that waiting, extracted into a package. It does not download, verify, or install anything — Sparkle and [mxcl/AppUpdater](https://github.com/mxcl/AppUpdater) already do that well. Tiptoe decides *when* the last step of either one may run.

## Install

Tiptoe is one package with two optional adapters, gated behind [package traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md) so a consumer links only what it uses. With neither trait enabled, the package pulls in nothing — no Sparkle, no AppUpdater, not even their transitive dependencies get resolved.

For an unsandboxed app shipping notarized DMGs on GitHub Releases:

```swift
.package(url: "https://github.com/artginzburg/Tiptoe", from: "1.0.0", traits: ["GitHubSupport"])
```

```swift
.product(name: "TiptoeGitHub", package: "Tiptoe")
```

For a sandboxed app, via Sparkle:

```swift
.package(url: "https://github.com/artginzburg/Tiptoe", from: "1.0.0", traits: ["SparkleSupport"])
```

```swift
.product(name: "TiptoeSparkle", package: "Tiptoe")
```

## Use it

```swift
// Adrafinil, complete
TiptoeGitHub(owner: "kageroumado", repo: "adrafinil")
    .gate("agents are working") { await daemon.assertionsAreIdle }
    .start()

// WheelClick — plus the four SU… keys below, in Info.plist
TiptoeSparkle().start()
```

`gate(_:_:)` adds a veto only the host can evaluate — `daemon.assertionsAreIdle` above is Adrafinil's own condition, not anything Tiptoe knows about. The condition it takes is `async`, because the answer often lives somewhere else (behind XPC, in Adrafinil's case); a gate that never answers is treated as a refusal after five seconds, and logged as a fault. Several gates may be chained; any one of them saying no holds the update.

`start()` keeps the instance alive on its own — no property to retain it yourself, no risk of it being deallocated on the next line and silently never updating. That is why both lines above stand alone, assigned to nothing. It also *returns* the instance, so keep it when the host wants to talk to it later — a "Check for Updates…" menu item, or the "Updated to 1.0.3" line:

```swift
updates = TiptoeSparkle().start()   // a property of your app delegate
```

## Where it goes

Once, at launch, from the main actor — both adapters are `@MainActor`, like the AppKit state they read. Not per window, not per document, and there is nothing to tear down: an app that never calls `stop()` is the normal case.

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var updates: TiptoeSparkle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updates = TiptoeSparkle().start()

        if let installed = updates?.tiptoe.justUpdatedTo {
            statusMenu.note("Updated to \(installed)")
            updates?.tiptoe.acknowledge()
        }
    }
}
```

A SwiftUI app has no delegate of its own, so it borrows one — `@NSApplicationDelegateAdaptor(AppDelegate.self)` on the `App`, with the same body as above. Starting it from `App.init()` works too, but a delegate is the honest home for something that outlives every window.

The menu item, if you want one:

```swift
Button("Check for Updates…") { updates?.checkForUpdates() }
    .disabled(!(updates?.canCheckForUpdates ?? false))
```

**Xcode projects.** Traits survive the trip: Xcode keeps them on the package reference (`traits = (GitHubSupport,);` in `project.pbxproj`), and without one the dependency resolves nothing at all. Linking an adapter product without enabling its trait is not an error and not a warning — the module compiles to nothing, and the first sign is `TiptoeSparkle` not being found in scope.

**One target that also ships to the Mac App Store** needs a different route: an updater in an App Store build is grounds for rejection, and SwiftPM links a product into *every* configuration of a target, so the adapter cannot be kept out of that one. It is solvable — compile the sources instead of linking the product — and [docs/app-store-apps.md](docs/app-store-apps.md) has the recipe, the settings, and the measurements behind them.

For the GitHub path, anything mxcl/AppUpdater offers beyond a repository name is reached by handing over a ready-made updater — artifact attestation, above all, which verifies GitHub's provenance for the binary that is about to replace the running app:

```swift
let updater = AppUpdater(
    owner: "kageroumado", repo: "adrafinil",
    configuration: .init(attestationPolicy: GitHubAttestationPolicy(
        workflow: ".github/workflows/release.yml", sourceRef: "refs/heads/main")))
updater.allowPrereleases = true

TiptoeGitHub(updater: updater).start()
```

## A setting, if the app offers one

Plenty of apps put "install updates automatically" in front of the person, and an app that does has a problem this package used to make worse: with the setting off there is nothing to install silently, so the app still has to answer *is there a new version?* — and answering it meant a second poller, a second idea of "latest", and two requests a day to the same endpoint.

So the check loop keeps running in both modes, and what it learns is readable either way:

```swift
updates = TiptoeGitHub(owner: "kageroumado", repo: "adrafinil")
    .gate("agents are working") { await daemon.assertionsAreIdle }
    .installsAutomatically(settings.autoInstall)   // and again whenever it changes
    .start()
```

With it off, nothing is downloaded and nothing installs itself; `availableVersion` still says what exists, and `updateNow()` is there for the button that acts on it. With it on, everything is as before — and `availableVersion` is still worth reading, because it answers from the release itself rather than from a download, and so keeps answering when a download is what broke.

Sparkle has this already, in its own shape: `SUAutomaticallyUpdate` is the person's to set, the adapter is inert without it, and a check somebody asks for goes through Sparkle's own windows.

## Sparkle setup

The Sparkle adapter takes over the moment Sparkle has downloaded an update by itself — that is the only hook there is. So Sparkle has to be configured to download by itself, in the host app's Info.plist:

| Key | What it does |
| --- | --- |
| `SUFeedURL` | Where the appcast lives. |
| `SUPublicEDKey` | The EdDSA public key updates are signed against. |
| `SUEnableAutomaticChecks` | Check in the background without asking first — otherwise Sparkle prompts on first launch, which is one alert more than this package promises. |
| `SUAutomaticallyUpdate` | Download found updates without asking. |

**Without the last two, the adapter is inert**: nothing is ever downloaded automatically, so nothing is ever handed to Tiptoe, and no update ever installs quietly. `start()` says so at `error` level in the log rather than fixing it in code — Sparkle is explicit that an app must not override this at launch, because after the first run it is the person's own preference.

## One grid, not a thousand phases

Sparkle checks at `lastUpdateCheckDate + updateCheckInterval`. The interval is shared, the *phase* is not: whichever moment an install first ran is the moment it will ask in for the rest of its life. Over an install base those accidents spread evenly, and a fleet arriving at every hour of every day is the worst shape a feed server can be handed.

It is worst for exactly the servers a small app can afford. A CDN in front of the appcast almost never sees a second request inside one TTL, because the arrivals fragment across points of presence faster than they accumulate — so the cache is paid for and never hits. A scale-to-zero backend is worse still: it sleeps after some idle timeout and is billed by the wall clock, so a hundred arrivals at a hundred unrelated moments buy a hundred full idle timeouts, while the same hundred inside one clump buy one.

`alignChecks` snaps the check to a wall-clock grid every install computes identically:

```swift
updates = TiptoeSparkle().start().alignChecks()   // once a day, on the hour
updates = TiptoeSparkle().start().alignChecks(CheckSchedule(period: 43200, alignment: 900))
```

The period is unchanged — this is not a way to check more often, and `period` still governs how much time must pass. Only the *moment* moves, to the first grid instant at or after the check falls due.

The arithmetic lives in [`CheckSchedule`](Sources/Tiptoe/CheckSchedule.swift), which knows nothing about Sparkle and is tested on its own; the adapter contributes a timer, a wake notification and two calls into `SPUUpdater`.

Measured on WheelClick's own arrival times, snapping the fleet to the hour took its database from ~123 to ~38 compute-hours a month, against a cap of 100. The saving is superlinear in a way that is easy to get wrong: halving the number of requests barely moved the bill, and aligning them without halving anything moved it by two thirds. What is billed is the number of separated arrival clusters, not the number of requests.

**What it costs the person: one grid step of latency, at most.** The rule is "the first slot at or after it fell due", never "the next slot tomorrow" — a Mac that slept through its slot checks at the following one, minutes after waking, not a period later. With the default hour, an update is found at most 59 minutes later than Sparkle would have found it, against a period of a day. Keep the grid well under the period for that reason: an hour always has a slot near any waking moment, while a daily grid would be missed forever by a Mac that sleeps at the same hour every night.

It tends to make the check *faster*, in fact. A scattered request has good odds of being the one that finds the server asleep and pays for the cold start; on a grid only the first request in each clump does, and the rest arrive to something warm.

None of this writes to Sparkle's settings. `updateCheckInterval` is a preference that may be the person's own, and Sparkle's header is explicit that an app must not set it on launch — so the aligned check is timed to land inside that window rather than to move it, which means checks come a grid step sooner than the period given, and the shorter of the two periods wins. Sparkle's own timer stays armed underneath as the backstop for a Mac that was asleep for both. Someone who has turned automatic checks off is left alone entirely.

All of it is opt-in: without a call to `alignChecks`, `TiptoeSparkle` schedules nothing, observes nothing and writes nothing, exactly as before.

## The ladder

The Mac may never be perfectly quiet. An app that waits for ideal conditions and never gets them simply never updates — and under Sparkle it's worse than that, because holding one installation stalls the whole update cycle, so a stale pending update blocks the very fix that would have replaced it. So the requirement relaxes the longer an update has been waiting:

| Waiting for | Enough |
| --- | --- |
| up to 48 h | 120 s without input, **and** no visible window that can become main |
| 48 h – 7 d | 30 s without input, same window rule |
| beyond 7 d | 5 s without input; only windows with something to lose still block |

Host gates never relax — they're a veto, not a preference, and stay in force at every rung. Unsaved work blocks the install forever, at every rung, regardless of how long the wait has run: a window is "something to lose" if it has `isDocumentEdited` set (the dot in the close button) or a sheet or modal open.

The clock measures *continuous* waiting, and it survives relaunches — otherwise the later rungs would never be reached on the machines that need them most. It is not allowed to outlive its update, though: if the app's version changed while it was not running, the update landed some other way (Sparkle installs pending updates on quit; so do Homebrew and a downloaded DMG), and the next update starts a fresh clock rather than inheriting seven days it never waited.

`.windowsAlwaysBlock()` opts out of the third rung's relaxation, keeping every rung as strict as the first. Use it if your app keeps unsaved state that a SwiftUI view doesn't reflect through `isDocumentEdited` — Tiptoe can only see what that property reports, so state it can't see is state it can't protect, and the opt-out is the only way to keep it safe.

## What the host can show

The package shows nothing itself — no window, no notification, not a badge. Everything visible is the host's to decide, from these.

Where they live: `justUpdatedTo`, `acknowledge()`, `pending`, `onWillInstall`, `onWaitingTooLong` and `installNow()` belong to the engine, reached through the adapter's `tiptoe` property — `updates.tiptoe.justUpdatedTo`. `availableVersion`, `installsAutomatically(_:)`, `updateNow()`, `onChecksFailing`, `checkNow()` and `stop()` are the adapter's own, called on it directly.

| | |
| --- | --- |
| `justUpdatedTo` | The version installed while nobody was looking, or `nil`. The one line worth showing: *"Updated to 1.0.3"*, wherever the app already talks about itself. Survives relaunches, and survives an update that landed some other way — Sparkle installing it on quit, say. Dropped on its own once the app runs as some other version, so a notice nobody opened cannot announce 1.11 from inside 1.12. |
| `acknowledge()` | Clears that notice, once the person has had a chance to see it. |
| `pending` | The update currently waiting, with the version and the moment the wait began. `nil` when there is nothing to install. |
| `availableVersion` | GitHub path only. The newest version published, when it is newer than the running app. A weaker claim than `pending`, and the one an "a new version is out" line wants: true from the moment the release exists, and still true when the download is what failed — the case where a host reporting from `pending` alone falls silent exactly when it had something to say. |
| `installsAutomatically(_:)` | GitHub path only. What an "install updates automatically" setting sets, at launch or while the app runs. Off, the check loop keeps running and keeps answering `availableVersion`, but nothing is downloaded and nothing installs itself. |
| `onWillInstall` | Called on the last quiet instant before the app is replaced. The process may not survive the next line, so anything to be recorded is recorded here. |
| `onWaitingTooLong` | Fires once when a wait has run past two weeks. The package's own signals always yield eventually, so this means a host gate has been refusing all that time — the host decides whether that is worth saying out loud. |
| `onChecksFailing` | GitHub path only. Fires once when update checks have been failing for about a day — a wrong repository name, a repository gone private. Without it, that is indistinguishable from "no update available", forever. |
| `installNow()` | Installs immediately, whatever the Mac is doing — for a host acting on an explicit request from a person, and only then. Installs what is already held: on the GitHub path, `updateNow()` is the one a button should call. |
| `updateNow()` | GitHub path only. Asks GitHub for the newest release, downloads it unless it is the one already waiting, then installs immediately — the "Update Now" button, in either mode. A waiting download that fell behind is replaced; one that cannot be re-checked (no network) is installed as it stands. False back means there was nothing newer, or the download could not be made; a successful install replaces the process and returns nothing anybody reads. |
| `checkNow()` | GitHub path only. Looks for an update right now, out of band with the check loop; anything found is still held for a quiet moment. |
| `stop()` | Stops both the polling and, on the GitHub path, the checking. Nothing already queued can land an install afterward. |

The Sparkle adapter adds the two things a "Check for Updates…" menu item needs: `checkForUpdates()`, deliberately routed through Sparkle's own windows — a check somebody asked for is the one moment where a progress bar and the release notes are the point rather than an interruption — and `canCheckForUpdates`, which is what such a menu row disables itself on.

## What it does not do

No downloading, no installing, no UI. Sparkle and mxcl/AppUpdater do that work; Tiptoe only decides when the last step — the one that replaces the running app — may happen.

## When not to use it

The Mac App Store forbids self-updating apps outright, so a Mac App Store build must contain none of this — no Tiptoe, no Sparkle, no AppUpdater.

Outside the App Store, a sandboxed app needs the Sparkle path specifically: nothing else can replace a sandboxed app's own bundle, because that requires an XPC service running outside the sandbox, which is what Sparkle provides.

## What is tested, and what is not

Every rule of the ladder, the host veto, the gate timeout, and the escalation after a long wait are unit-tested against injected clocks and sensors — no idle Mac required.

The bundle swap itself is not tested here. A real end-to-end test needs a signed, notarized build, because mxcl/AppUpdater checks the app's Team ID and an ad-hoc build fails that check by design. That swap is upstream's code, and it has its own tests; what Tiptoe adds is the decision of *when* to call it, and that decision is what these tests cover.

## Licence

[MIT](LICENSE).
