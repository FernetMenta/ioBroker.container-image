#!/usr/bin/env bash
# plan-release-tags.sh - given the full tag history, decide which release tags a
# release SIGNAL should create.
#
# This is the decision core behind .github/workflows/release-promote.yml. That
# workflow fires when a plain `<version>` release-signal tag is pushed (e.g.
# `7.2.2` or `7.2.2.1`); this script decides which `<version>-r<n>` tags to
# create as a result. It reads ONLY the tag list — no network — so it is easy
# to unit-test.
#
# Tagging model (see docs/building.md):
#   - `<version>-dev-r<n>`  dev/test tag (e.g. 7.2.2-dev-r2). Builds & publishes
#                           the immutable dev image; never a release pointer.
#   - `<version>-r<n>`      release tag (e.g. 7.2.2-r3). Immutable + moving
#                           `<version>` alias + `latest`. Created ONLY by
#                           automation (this script / base-refresh).
#   - `<version>` / `<version>.<build>`  release SIGNAL tag. Pushing it means
#                           "cut a release". The 4th numeric component (if any)
#                           is an image-only nudge and is NOT part of the
#                           3-component js-controller `<version>`.
#
# What a signal produces (Req from the maintainer):
#   1. Take the LATEST 2 distinct 3-component js-controller `<version>`s across
#      ALL tags (dev and release both reveal a version). Only the two newest are
#      (re)released; older versions stay frozen. Releasing the newest also
#      re-cuts the previous release so shared image/script changes made during
#      the dev cycle flow to it too.
#   2. For each of those 2 versions, compute the next release revision:
#        - if a `<version>-r<n>` already exists -> `<version>-r<highest+1>`;
#        - else (only `<version>-dev-r<n>` exists) -> `<version>-r1`.
#      A version with NO tag at all is impossible here (versions are discovered
#      from existing tags).
#
# Usage:
#   scripts/plan-release-tags.sh <tag>...
#     <tag>...  All candidate git tags (typically the full `git tag` list).
#
# Output:
#   One planned tag per line on stdout (e.g. `7.2.2-r4` then `7.1.3-r4`), newest
#   version first. Human-readable progress on stderr. Prints nothing when no
#   `<version>`-bearing tags exist.
#
# Exit codes:
#   0  plan computed (possibly empty)
#   1  usage error
set -euo pipefail

log() { echo "plan-release-tags: $*" >&2; }

# ---------------------------------------------------------------------------
# Pure helpers. Sourced (CHECK_LIB=1) by unit tests; then main is skipped.
# ---------------------------------------------------------------------------

# distinct_versions <tag>...
# Print the distinct 3-component `<version>`s found in `<version>-r<n>` and
# `<version>-dev-r<n>` tags, one per line, sorted newest-first (semver order).
distinct_versions() {
  local t
  for t in "$@"; do
    if [[ "${t}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-dev)?-r[0-9]+$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done | sort -u -V
}

# highest_release_rev <version> <tag>...
# Print the highest <n> among `<version>-r<n>` RELEASE tags (dev tags excluded),
# or `0` when the version has no release tag yet.
highest_release_rev() {
  local version="$1"; shift
  local esc re t best=0 rev
  esc="$(printf '%s' "${version}" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
  # Note: `<version>-r<n>` only. `<version>-dev-r<n>` does NOT match because of
  # the required literal `-r` immediately after the escaped version.
  re="^${esc}-r([0-9]+)\$"
  for t in "$@"; do
    if [[ "${t}" =~ ${re} ]]; then
      rev=$((10#${BASH_REMATCH[1]}))
      (( rev > best )) && best="${rev}"
    fi
  done
  printf '%s\n' "${best}"
}

# next_release_tag <version> <tag>...
# Print the release tag to create for <version>: `<version>-r<highest+1>`, which
# is `<version>-r1` when no release tag exists yet.
next_release_tag() {
  local version="$1"; shift
  local highest
  highest="$(highest_release_rev "${version}" "$@")"
  printf '%s-r%s\n' "${version}" "$(( highest + 1 ))"
}

if [[ -n "${CHECK_LIB:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "usage: $0 <tag>..." >&2
  exit 1
fi

# Latest 2 distinct versions across all tags (newest last from sort -V; keep the
# last two, then emit newest-first for readability).
mapfile -t versions < <(distinct_versions "$@" | tail -n 2)
if [[ ${#versions[@]} -eq 0 ]]; then
  log "no '<version>-r<n>' or '<version>-dev-r<n>' tags found; nothing to release."
  exit 0
fi

# Reverse to newest-first.
for (( i=${#versions[@]}-1; i>=0; i-- )); do
  version="${versions[$i]}"
  next_tag="$(next_release_tag "${version}" "$@")"
  highest="$(highest_release_rev "${version}" "$@")"
  if (( highest == 0 )); then
    log "${version}: no existing release tag (dev-only) -> create '${next_tag}'."
  else
    log "${version}: highest release r${highest} -> create '${next_tag}'."
  fi
  printf '%s\n' "${next_tag}"
done
