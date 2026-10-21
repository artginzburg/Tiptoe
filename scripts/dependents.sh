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

found=$(
  for file in Package.resolved Package.swift project.pbxproj; do
    gh api -X GET search/code -f q="\"artginzburg/Tiptoe\" filename:$file" \
      --jq '.items[].repository.full_name'
  done | sort -u
)
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
