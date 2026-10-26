#!/bin/bash
# Lists public repositories that depend on Tiptoe, and flags the ones the
# README's "Used by" section does not name yet.
#
# GitHub's own dependents page stays empty for Swift packages: the dependency
# graph does not read Package.swift or Package.resolved, and an Xcode project
# keeps its Package.resolved inside the .xcodeproj anyway. Code search does
# see both, so this asks it instead. Only default branches are indexed, and
# private repositories (WheelClick's own source among them) never show up.
#
# Needs an authenticated `gh`. Exits 10 when something new turned up, and 1
# when the search itself failed. Run weekly by .github/workflows/dependents.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

# Found, looked at, and deliberately not listed — with the reason.
skip=(
  "artginzburg/Tiptoe"                # this repository
  "artginzburg/WheelClick-Community"  # WheelClick's public face; listed as WheelClick
  "ManagementMO/wakelease"            # pre-release derivative of Adrafinil, 2026-10-21
)

# One request, filtered here by path: code search allows only a few a minute,
# and the token Actions hands out runs into that on the second.
search() {
  gh api -X GET search/code -f q='"artginzburg/Tiptoe"' -f per_page=100 \
    --jq '.items[] | select(.path | test("(^|/)(Package\\.resolved|Package\\.swift|project\\.pbxproj)$")) | .repository.full_name'
}
# The limit is not this repository's alone: the very first request can come
# back 429, and GitHub says how long to wait — 7 s on 2026-10-21, 731 s on
# 2026-10-26, where three fixed one-minute retries gave up. So wait what it
# says, within a budget. A limit still standing after that is a busy week,
# not a broken check: say so and let next week's run look. Any other failure
# still fails the job.
budget=1800
err=$(mktemp)
while :; do
  if found=$(search 2>"$err"); then rm -f "$err"; break; fi
  wait=$(sed -n 's/.*try again in \([0-9]*\).*(HTTP 429).*/\1/p' "$err" | tail -1)
  if [ -z "$wait" ]; then cat "$err" >&2; exit 1; fi
  wait=$((wait + 5))
  if [ "$wait" -gt "$budget" ]; then
    echo "::warning::code search is rate-limited for another ${wait}s; next week's run will look"
    exit 0
  fi
  echo "code search rate-limited, waiting ${wait}s" >&2
  sleep "$wait"
  budget=$((budget - wait))
done
found=$(sort -u <<<"$found")
# The apps the README already lists match these searches, so an empty answer
# is a token that cannot search code, not a world with no dependents.
if [ -z "$found" ]; then
  echo "code search returned nothing at all; the token cannot search code" >&2
  exit 1
fi

new=0
for repo in $found; do
  if printf '%s\n' "${skip[@]}" | grep -qx "$repo"; then
    continue
  fi
  if grep -qi "github.com/$repo" README.md; then
    echo "listed  $repo"
  else
    echo "NEW     $repo  https://github.com/$repo"
    new=10
  fi
done
exit $new
