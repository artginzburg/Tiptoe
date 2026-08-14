# Apps that also ship to the Mac App Store

This page is for one specific situation: **one target that builds both a direct
download and an App Store submission.** If that is not you, ignore it — link
`TiptoeSparkle` or `TiptoeGitHub` the ordinary way and read no further.

The situation is awkward because the App Store rejects self-updating apps
outright. Not "discourages": a build carrying an updater is a rejection, so the
App Store configuration must contain none of it. Meanwhile the direct build of a
*sandboxed* app has no choice but Sparkle, since nothing else can replace a
sandboxed app's own bundle.

## What does not work, and what it costs

Measured on a real dual-channel app, not reasoned about:

- **Package traits do work in Xcode.** `traits = (SparkleSupport,)` on the
  package reference in `project.pbxproj` is honoured; without it the dependency
  resolves nothing at all. That part is fine.
- **But a SwiftPM product links into every configuration of a target.** There is
  no way to vary it. Linking `TiptoeSparkle` put two
  `@rpath/Sparkle.framework` load commands into the App Store binary — an
  automatic rejection.
- `EXCLUDED_SOURCE_FILE_NAMES` does not help here. Set to the package name, and
  set to the product name, it changed nothing; nor did leaving the product out
  of the Frameworks build phase, because the dependency declaration alone is
  enough for Xcode to link it.
- **Linking only the core** keeps Sparkle out, and costs **307 KB** of code the
  App Store build never runs, since the linker does not strip it.

## What works: compile the sources into your target

Vendor Tiptoe as a submodule and let your own target compile the files, so the
App Store configuration can exclude them like any other source file. You get the
real adapter from the real repository rather than a copy that drifts.

```bash
git submodule add https://github.com/artginzburg/Tiptoe.git vendor/Tiptoe
```

Add these to your app target's *Compile Sources* — seven for the engine, plus
the adapter you need:

```
vendor/Tiptoe/Sources/Tiptoe/QuietPolicy.swift
vendor/Tiptoe/Sources/Tiptoe/Gate.swift
vendor/Tiptoe/Sources/Tiptoe/Nanoseconds.swift
vendor/Tiptoe/Sources/Tiptoe/Store.swift
vendor/Tiptoe/Sources/Tiptoe/Environment.swift
vendor/Tiptoe/Sources/Tiptoe/Tiptoe.swift
vendor/Tiptoe/Sources/Tiptoe/TiptoeRegistry.swift
vendor/Tiptoe/Sources/TiptoeSparkle/TiptoeSparkle.swift
```

Then three build settings:

**`EXCLUDED_SOURCE_FILE_NAMES`**, in the App Store configurations only. It
matches **file names, not paths** — `vendor/Tiptoe/*` and `*/vendor/Tiptoe/*`
both silently do nothing, which is the trap that costs an afternoon:

```
Tiptoe*.swift  QuietPolicy.swift  Gate.swift  Nanoseconds.swift  Store.swift  Environment.swift
```

**`SWIFT_ACTIVE_COMPILATION_CONDITIONS`**, in the direct configurations only:
add `SparkleSupport` (or `GitHubSupport`). Compiled as a package this is what
the trait sets; compiled as source, you set it. Without it the adapter file
compiles to nothing and the first sign is `TiptoeSparkle` not being found in
scope.

**`SWIFT_PACKAGE_NAME`**, set to anything — `Tiptoe` will do. Two of the files
use Swift's `package` access level, which the compiler rejects without a package
name.

Nothing else changes: the adapters import the core only `#if canImport(Tiptoe)`,
and take no isolated default arguments, precisely so they compile inside a
host's own module and in a target still on Swift 5.

## Two things to do afterwards

**Check the App Store build, don't trust it.** The exclusion is by file name, so
a file added to this package upstream will be compiled into your App Store build
until you list its name too. One line in the release script notices:

```bash
if nm "$APP/Contents/MacOS/YourApp" | grep -q Tiptoe; then
  echo "The App Store binary carries Tiptoe's code" >&2
  exit 1
fi
```

**Check out submodules in CI.** `actions/checkout` does not, by default:

```yaml
- uses: actions/checkout@v4
  with:
    submodules: true
```

## Updating

`git -C vendor/Tiptoe checkout <tag>` and commit the new pin. Nothing moves on
its own — which is the point, for the one dependency whose job is to replace
your app while nobody is watching.
