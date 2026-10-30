#!/usr/bin/env bash
# plan-release-tags.sh - given a release SIGNAL and the full tag history, decide
# which release tag the signal should create.
#
# This is the decision core behind .github/workflows/release-promote.yml. That
# workflow fires when a plain `<version>` release-signal tag is pushed (e.g.
# `7.2.2` or `7.2.2.1`); this script decides which `<version>-r<n>` tag to
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
#                           "cut a release of <version>". The 4th numeric
#                           component (if any) is an image-only nudge and is NOT
#                           part of the 3-component js-controller `<version>`.
#
# What a signal produces:
#   A release affects ONLY the version it refers to. The signal's 3-component
#   `<version>` gets its next release revision:
#     - if a `<version>-r<n>` already exists -> `<version>-r<highest+1>`;
#     - else (only dev tags, or no tag at all) -> `<version>-r1`.
#   Other versions are never touched here. Keeping the latest 2 versions
#   current on a newer base image is base-refresh.yml's job, not this one's.
#
# Usage:
#   build/scripts/plan-release-tags.sh <signal> <tag>...
#     <signal>  The release-signal tag or version (`7.2.5`, `7.2.5.2`).
#     <tag>...  All candidate git tags (typically the full `git tag` list).
#
# Output:
#   Exactly one planned tag on stdout (e.g. `7.2.5-r2`). Human-readable progress
#   on stderr.
#
# Exit codes:
#   0  plan computed
#   1  usage error / malformed signal
set -euo pipefail
log() { echo "plan-release-tags: $*" >&2; }
# ---------------------------------------------------------------------------
# Pure helpers. Sourced (CHECK_LIB=1) by unit tests; then main is skipped.
# ---------------------------------------------------------------------------
# signal_version <signal>
# Print the 3-component `<version>` of a release signal (`7.2.5` or
# `7.2.5.2` -> `7.2.5`). Returns 1 (prints nothing) for anything else.
signal_version() {
  if [[ "$1" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(\.[0-9]+)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
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
  echo "usage: $0 <signal> <tag>..." >&2
  exit 1
fi
signal="$1"; shift
if ! version="$(signal_version "${signal}")"; then
  echo "plan-release-tags: '${signal}' is not a release signal; expected <version> (e.g. 7.2.5) or <version>.<build> (e.g. 7.2.5.2)." >&2
  exit 1
fi
next_tag="$(next_release_tag "${version}" "$@")"
highest="$(highest_release_rev "${version}" "$@")"
if (( highest == 0 )); then
  log "signal '${signal}' -> ${version}: no existing release tag -> create '${next_tag}'."
else
  log "signal '${signal}' -> ${version}: highest release r${highest} -> create '${next_tag}'."
fi
printf '%s\n' "${next_tag}"
