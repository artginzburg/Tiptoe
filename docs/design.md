# Tiptoe — design

- **Date:** 2026-08-13
- **Status:** Approved, not yet implemented
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

// WheelClick, complete
updates = TiptoeSparkle().start()
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

1. Repository, core, tests.
2. `TiptoeGitHub` and `TiptoeSparkle`.
3. README: the model, the ladder, both integrations, and a "when not to use this"
   section (the App Store forbids self-updating apps outright; a sandboxed app
   needs the Sparkle path).
4. An issue to Adrafinil's maintainer proposing the change and showing what it
   costs them — before any PR, because it brings two dependencies they never
   asked for. PR after a reply.
5. **Only on Arthur's word, and separately:** WheelClick migrates.
   `UpdateController` collapses to a couple of lines, `updateInstalledNotice`
   leaves `Config`, and ADR 0006 records the extraction. Other agents are working
   in that repository; it stays untouched until then.

## Risks

- **Traits are new.** If SPM's platform check turns out to reject a macOS 12
  package graph in some Xcode version, the fallback is plain products without
  traits, at the cost of resolving unused dependencies.
- **Adrafinil may decline.** Two new dependencies in a repository with 437 stars
  is a real ask. The issue-first order exists so the answer arrives before the
  work does, and the package is useful with one consumer regardless.
- **The third rung is the only place Tiptoe can do harm.** Everything else is
  strictly more conservative than shipping without it. The window rule and the
  opt-out are the mitigation, and the README documents the case they miss.
