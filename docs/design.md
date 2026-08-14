# Tiptoe — design

- **Date:** 2026-08-13
- **Status:** Implemented 2026-08-14. Sections below marked *(as built)* record where
  the finished package departs from what was designed, and why
- **Deciders:** Arthur, with Claude

## What this is

A macOS app that updates itself should be able to do it without ever taking a
moment from the person using the Mac: no alert, no click, no "relaunch now?".
WheelClick has shipped that experience since 1.0.3 — Sparkle downloads in the
background, and the *installation* is held back until the Mac has been idle for
two minutes with no window of ours open, then swaps the bundle and relaunches
with nobody noticing. The whole visible footprint is one line in the menu the
next time it opens: "Updated to 1.0.3".

Tiptoe extracts that mechanism — the *when*, not the *how* — into a package any
macOS app can adopt, and gives the host app a veto so it can add its own idea of
"not now" without reimplementing any of the waiting.

The second consumer is the reason the veto exists.
[Adrafinil](https://github.com/kageroumado/adrafinil) keeps a Mac awake while AI
coding agents are working. Restarting it while agents hold assertions would put
the machine to sleep at exactly the wrong moment — so "no agents are working" is
a condition only Adrafinil can evaluate, and Tiptoe must ask rather than guess.

## Scope

**In:** deciding when it is safe to install, holding a prepared installation
until then, escalating when the wait becomes absurd, and reporting what happened.

**Out:** finding, downloading, verifying and installing updates. That is done by
code that already exists and is trusted:

- **Sparkle** for sandboxed apps — the only updater whose answer to "a sandboxed
  app cannot replace its own bundle" is an XPC service outside the sandbox
  (see WheelClick ADR 0005).
- **[mxcl/AppUpdater](https://github.com/mxcl/AppUpdater)** for everything else —
  GitHub Releases, DMG assets, Team ID and attestation checks, and, decisively,
  a three-stage seam: `check()` → `prepareInstallation()` →
  `installAndRelaunch()`. That last call is exactly what Tiptoe holds.

**Also out:** any user interface. Tiptoe never shows anything. When it has
something to say it calls the host, and the host decides whether that becomes a
line in a menu.

## Modules

One repository, three products, so a consumer links only what it uses.

| Product | Depends on | For |
| --- | --- | --- |
| `Tiptoe` | nothing but AppKit | the policy engine |
| `TiptoeSparkle` | Sparkle | sandboxed apps (WheelClick) |
| `TiptoeGitHub` | mxcl/AppUpdater | unsandboxed apps (Adrafinil) |

*(as built)* A fourth way of consuming this turned out to be necessary and is
documented in [app-store-apps.md](app-store-apps.md): an app whose single target
also ships to the Mac App Store cannot link the adapter at all, because SwiftPM
links a product into every configuration and an updater in an App Store build is
a rejection. Such an app compiles the sources into its own target instead, which
is why both adapters import the core only `#if canImport(Tiptoe)` and avoid
isolated default arguments.

The upstream dependencies sit behind **package traits** (`swift-tools-version:
6.1`), so `swift build` without a trait resolves neither Sparkle nor AppUpdater.
This is not cosmetic: WheelClick's App Store build must contain *not one byte* of
Sparkle — three separate seams that `release-appstore.sh` asserts against the
built archive — and the core has to be adoptable without dragging any of it in.

## Public API

Both adapters have the same shape and the same lifecycle. The host never touches
Sparkle or AppUpdater types.

```swift
// Adrafinil, complete
TiptoeGitHub(owner: "kageroumado", repo: "adrafinil")
    .gate("agents are working") { await daemon.assertionsAreIdle }
    .start()

// WheelClick — plus four SU… keys in Info.plist, see below
TiptoeSparkle().start()
```

- `gate(_:_:)` returns `Self`, so gates chain. Several may be registered; any one
  of them saying no is a veto.
- Gates are **async**, because the answer often lives somewhere else — Adrafinil's
  lives in a daemon behind XPC. A synchronous signature would force every such
  host to cache state by hand.
- `start()` registers the instance in a private static set and keeps it alive
  until `stop()`. Without this, the chained form above would be deallocated on
  the next line and silently never update — the worst possible failure for a
  mechanism whose whole point is that nothing visible happens.
- `TiptoeSparkle` owns its `SPUStandardUpdaterController` and creates it inside
  `start()`. It re-exposes `checkForUpdates()` and `canCheckForUpdates` for the
  host's menu row: a check somebody asked for is the one moment where a window,
  a progress bar and the release notes are the point rather than an interruption,
  so it goes through Sparkle's own UI.
- The core exposes `pending` (what is waiting, and since when), `onWillInstall`,
  `onWaitingTooLong`, and `justUpdatedTo` / `acknowledge()` — the last pair being
  what a host turns into "Updated to 1.0.3".

*(as built)* Four additions the design did not foresee, each forced by something
found while building it:

- **`hold` takes `retryable:`.** Sparkle's block can be invoked again; AppUpdater's
  prepared update is spent the moment it is called, success or failure. Without the
  distinction, a failed install left the engine retrying a dead download every
  minute for hours, logging an error each time.
- **`installNow()` returns its `Task`.** A host that acts on an explicit request may
  want to await the outcome, and a test certainly does — the alternative was
  sleeping and hoping.
- **`onChecksFailing`.** A typo in `owner`/`repo` is the one path where the app
  silently never updates *and* nothing ever reaches the host: no update is ever
  held, so `onWaitingTooLong` cannot fire either. A streak of failed checks now
  reports itself.
- **`TiptoeSparkle` is inert without host configuration.** Everything hangs on
  Sparkle's `willInstallUpdateOnQuit`, which it calls only after downloading
  automatically — and automatic downloads are off by default. A host must ship
  `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`;
  without the last two the adapter does nothing and Sparkle asks the user a
  question, which is the one thing this package promises never to happen. `start()`
  says so in the log rather than overriding the user's own preference.

## When it is safe

### The two signals Tiptoe measures itself

1. **No input for a while.** `CGEventSource.secondsSinceLastEventType` with
   `.combinedSessionState` and the any-event sentinel — the same measure the
   screen saver's idle timer uses.
2. **No window of ours that has something to lose.** See the ladder below for
   what that means at each rung.

Everything else is a host gate. Tiptoe ships no built-in gate for microphone use,
Do Not Disturb, battery state or full-screen apps: none of it is proven in the
field, some of it has no public API, and a host that needs one can write it in a
closure.

### The ladder

The Mac may never be quiet. An app that waits for perfect conditions and gets
none simply does not update — and with Sparkle it is worse than that, because
holding the installation stalls Sparkle's whole update cycle, so a stale pending
update blocks the fix that would have replaced it. So the requirement relaxes as
the wait grows:

| Waiting for | Enough |
| --- | --- |
| up to 48 h | 120 s without input, **and** no visible window that can become main |
| 48 h – 7 d | 30 s without input, same window rule |
| beyond 7 d | 5 s without input; only windows with something to lose still block |

"Something to lose" means `isDocumentEdited` (the dot in the close button) or a
sheet or modal being up. Those block **forever, at every rung** — a text editor
with a dirty document never gets swapped out from under its author, and its
author writes no code to get that. The distinction matters because the package
cannot know what an arbitrary window holds: WheelClick's tour and Configure
windows lose nothing worth a dialog, a half-written document does.

`.windowsAlwaysBlock()` opts out of the third rung for hosts that want the strict
rule. The README states the one case the flag cannot cover: a SwiftUI app holding
unsaved state without setting `isDocumentEdited` is invisible to this rule and
should opt out.

**Host gates never relax.** They are a veto, not a preference. This has a
consequence worth stating plainly: Tiptoe's own signals always yield eventually
(five seconds without input happens to everyone), so in practice a wait that runs
for weeks means a host gate is holding it. That is what makes the escalation
below meaningful.

### Polling and escalation

The gate is evaluated once a minute, plus immediately when an update is handed
over, when the screen locks, and when the display sleeps — quiet is guaranteed in
those last two, and waiting up to a minute to notice is pointless.

After 14 days of continuous waiting, `onWaitingTooLong` fires once and the host
decides whether to say anything. Tiptoe keeps waiting either way. Given the
paragraph above, this event does not mean "we are being too careful" — it means
"something in your app has been saying no for two weeks", which is exactly the
kind of thing a maintainer wants to hear about.

### Failure of a gate

A gate that does not answer within 5 s counts as "no" — the safe side — but is
logged at `error` level and the wait keeps ticking toward `onWaitingTooLong`.
A dead XPC daemon must surface as a broken app, not as an app that quietly stops
updating forever.

## State that outlives the process

Stored in `UserDefaults` under a `Tiptoe.` prefix (suite configurable):

- **When the current wait began**, and for which version. Without this a logout
  resets the clock and the later rungs are never reached.
- **The version installed silently**, for the host to display and then
  `acknowledge()`.

The clock measures *continuous waiting*, not the age of one version. If a newer
version arrives while one is pending, it replaces the pending one (the old one's
temporary DMG is discarded) and the clock keeps running — otherwise an app that
ships weekly would never reach the later rungs.

*(as built)* A third thing is stored, and it exists to keep the paragraph above
from becoming a hazard: **the app's own version at the moment the wait began.**

The wait was designed to end when Tiptoe installs — and Tiptoe is not the only
thing that installs. Sparkle's own documentation says it will install a downloaded
update when the app terminates, so somebody quitting the app in the evening ends
the wait without telling us; Homebrew and a manually dragged DMG do the same. The
recorded wait then survives forever, and the *next* update's very first check
finds a wait months long — which lands it directly on the third rung, where five
seconds of stillness is enough and an open window no longer blocks. The one rung
that can do harm would be reached on day one, by an app that had done nothing
wrong.

So at startup the running version is compared with the recorded one. If they
differ, the app was replaced by somebody else and the wait is cleared; and if the
version that was pending is the one now running, that is precisely "the update
landed", so the `justUpdatedTo` notice is set from it — which also fixes a gap
nobody had noticed, since an update Sparkle installed on quit used to produce no
notice at all. A recorded wait older than 90 days is discarded too: a Mac that
booted with a wrong clock before NTP corrected it must not inherit rung three.

## Logging

`os.Logger`, category `tiptoe`, subsystem taken from the host's bundle
identifier. Every refusal is logged with its reason — "input 12 s ago",
"gate: agents are working" — at `debug`; the installation itself at `info`.
"Why did it not update?" is the only question anyone will ever ask about this
package, and the log is the answer.

## Testing

The core takes its clock and both sensors through the initializer, defaulted to
the real ones: `secondsSinceInput`, and a window probe reporting the two facts
the ladder asks about separately — whether any visible window can become main,
and whether any window has unsaved changes or a sheet up. The
ladder, the window rule, the veto, the timeout and the escalation are all unit
tests over injected values — "49 hours waiting, input 40 s ago, gate silent"
resolves in microseconds and needs no idle Mac. `TiptoeGitHub` is tested against
a stub release provider.

There is no end-to-end test of the bundle swap, and the README and the Adrafinil
PR will say so rather than imply otherwise: a real one needs a signed, notarized
DMG (mxcl/AppUpdater checks the Team ID, so an ad-hoc build fails by design),
which means certificates and a human. The swap itself is upstream's tested code;
what Tiptoe adds is the decision to call it, and that is what the tests cover.

CI on `macos-latest` builds and tests with each trait; the README carries the
badge.

## Platform and licence

`.macOS(.v12)`. The core alone would run on 11 — `os.Logger` is the only thing
above 10.15 it touches — but SPM declares platforms per package, not per target,
and both upstreams declare 12. Below that is impossible, above it is gratuitous.

MIT, matching Sparkle and Adrafinil, and requiring the copyright line to travel
with every copy — which is the point of giving the model away under a name.

## Order of work

1. ~~Repository, core, tests.~~ Done.
2. ~~`TiptoeGitHub` and `TiptoeSparkle`.~~ Done.
3. ~~README: the model, the ladder, both integrations, and a "when not to use this"
   section (the App Store forbids self-updating apps outright; a sandboxed app
   needs the Sparkle path).~~ Done.
4. An issue to Adrafinil's maintainer proposing the change and showing what it
   costs them — before any PR, because it brings two dependencies they never
   asked for. PR after a reply.
5. **Only on Arthur's word, and separately:** WheelClick migrates.
   `UpdateController` collapses to a couple of lines, `updateInstalledNotice`
   leaves `Config`, and ADR 0006 records the extraction. Other agents are working
   in that repository; it stays untouched until then.

## Risks

- ~~**Traits are new.**~~ Settled: with neither trait enabled a clean `swift build`
  fetches nothing at all — empty checkouts, no `Package.resolved` written — and the
  macOS 12 graph resolves with either trait on. The core really is dependency-free,
  not merely unlinked.
- **Adrafinil may decline.** Two new dependencies in a repository with 437 stars
  is a real ask. The issue-first order exists so the answer arrives before the
  work does, and the package is useful with one consumer regardless.
- **The third rung is the only place Tiptoe can do harm.** Everything else is
  strictly more conservative than shipping without it. The window rule and the
  opt-out are the mitigation, and the README documents the case they miss.
