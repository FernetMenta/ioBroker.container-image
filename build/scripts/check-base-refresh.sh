#!/usr/bin/env bash
# check-base-refresh.sh - decide whether a published image revision should be
# rebuilt because a NEWER base image now exists, and if so print the next
# `<version>-r<n>` tag to create.
#
# This is the decision core behind the scheduled "auto base-image refresh"
# workflow (.github/workflows/base-refresh.yml). Given ONE js-controller
# `<version>` (e.g. `7.2.2`) and the set of existing git tags, it:
#
#   1. Finds the highest existing revision for that version among the passed
#      tags, e.g. `7.2.2-r5` -> current revision 5.
#   2. Resolves the BASE image that revision was built on from the published
#      image's OCI labels (`org.opencontainers.image.base.name`, e.g.
#      `node:22-trixie-slim`). This is the SAME base the Dockerfile records, so
#      the check tracks whatever node/debian the image actually shipped with —
#      no second source of truth to keep in sync.
#   3. Compares the base image's current `created` timestamp against the
#      published revision image's own `created` timestamp. If the base image is
#      NEWER than our published image, a fresh base exists since we last built,
#      so a rebuild is warranted.
#   4. When a rebuild is warranted, prints the next tag (`<version>-r<n+1>`,
#      e.g. `7.2.2-r6`) on stdout. When no rebuild is needed (base not newer, or
#      the published image / base cannot be resolved), prints nothing.
#
# Why compare `created` timestamps rather than base digests: the shipped image
# records the base image NAME (`node:22-trixie-slim`) but not the digest it was
# built against, so there is no recorded base digest to diff. The image config's
# `created` timestamp is always present in the registry for both the base and
# our published image, needs no extra state, and answers exactly the question
# asked: "is there a base image newer than the one we shipped?".
#
# Everything is read from the registry via
#   docker buildx imagetools inspect <ref> --format '{{json .Image}}'
# which resolves a multi-arch manifest list to its image config(s) WITHOUT
# pulling the image, and works for public images on GHCR and Docker Hub. It
# requires a reasonably recent buildx (the GitHub `ubuntu-latest` runner via
# docker/setup-buildx-action has one) and `jq`.
#
# Usage:
#   scripts/check-base-refresh.sh <image> <version> <tag>...
#
#     <image>    Published image ref WITHOUT tag, e.g. ghcr.io/owner/iobroker
#     <version>  js-controller version to consider, e.g. 7.2.2
#     <tag>...   All candidate git tags (the script filters to <version>-r<n>).
#                Typically the full `git tag` list is passed.
#
# Output:
#   - On stdout: the next tag to create (`<version>-r<n+1>`) IFF a newer base
#     image exists; otherwise nothing.
#   - Human-readable progress on stderr.
#
# Exit codes:
#   0  decision made successfully (whether or not a rebuild is warranted)
#   1  usage error or a hard failure (missing jq/docker, unparseable input)
set -euo pipefail

log() { echo "check-base-refresh: $*" >&2; }

# ---------------------------------------------------------------------------
# Pure helpers (no network). Kept as small functions so they can be unit-tested
# by sourcing this file with CHECK_BASE_REFRESH_LIB=1 set (which skips main).
# ---------------------------------------------------------------------------

# highest_revision <version> <tag>...
# Print "<n> <tag>" for the highest `<version>-r<n>` RELEASE tag among the tags,
# or nothing. Dev tags (`<version>-dev-r<n>`) are EXCLUDED: the pattern requires
# a literal `-r` immediately after the version, which `-dev-r<n>` does not
# satisfy, so base-refresh never acts on dev revisions.
highest_revision() {
  local version="$1"; shift
  local esc re t rev best=-1 best_tag=""
  # Escape regex metacharacters in the version so `7.2.2` matches literally.
  esc="$(printf '%s' "${version}" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
  re="^${esc}-r([0-9]+)\$"
  for t in "$@"; do
    if [[ "${t}" =~ ${re} ]]; then
      rev=$((10#${BASH_REMATCH[1]}))
      if (( rev > best )); then best="${rev}"; best_tag="${t}"; fi
    fi
  done
  if (( best >= 0 )); then printf '%s %s\n' "${best}" "${best_tag}"; fi
}

# image_created_epoch_from_json  (reads `{{json .Image}}` output on stdin)
# The `.Image` field is either the image config object (single-arch) OR a map
# keyed by platform (multi-arch), each value being an image config with a
# `.created` ISO-8601 field. Print the NEWEST `.created` across all entries as
# epoch seconds, or nothing when none is present.
image_created_epoch_from_json() {
  local iso
  iso="$(jq -r '
    def created_of: .created // empty;
    if type == "object" and has("created") then created_of
    elif type == "object" then ([.[] | created_of] | map(select(. != null)) | sort | last // empty)
    else empty end
  ' 2>/dev/null || true)"
  [[ -n "${iso}" ]] || return 0
  date -u -d "${iso}" +%s 2>/dev/null || true
}

# image_base_label_from_json  (reads `{{json .Image}}` output on stdin)
# Print the `org.opencontainers.image.base.name` label from the image config
# (handles both the single-config and per-platform-map shapes), or nothing.
image_base_label_from_json() {
  jq -r '
    def label_of: (.config.Labels["org.opencontainers.image.base.name"] // empty);
    if type == "object" and has("config") then label_of
    elif type == "object" then ([.[] | label_of] | map(select(. != null and . != "")) | first // empty)
    else empty end
  ' 2>/dev/null || true
}

# normalize_base_ref <base-name>
# Qualify a bare base image name so buildx addresses Docker Hub explicitly:
# `node:22-trixie-slim` -> `docker.io/library/node:22-trixie-slim`. Leaves an
# already-qualified ref (with a registry host or explicit namespace) untouched.
normalize_base_ref() {
  local ref="$1" first
  # Split on the first '/', if any, to inspect a potential registry host.
  first="${ref%%/*}"
  if [[ "${ref}" != */* ]]; then
    # Bare `name:tag` -> official library image.
    printf 'docker.io/library/%s\n' "${ref}"
  elif [[ "${first}" == *.* || "${first}" == *:* || "${first}" == "localhost" ]]; then
    # First path element looks like a registry host (has a dot/port) -> as-is.
    printf '%s\n' "${ref}"
  else
    # `namespace/name:tag` on Docker Hub.
    printf 'docker.io/%s\n' "${ref}"
  fi
}

# When sourced for unit tests, stop here (do not run the network flow).
if [[ -n "${CHECK_BASE_REFRESH_LIB:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Main flow (network).
# ---------------------------------------------------------------------------
if [[ $# -lt 3 ]]; then
  echo "usage: $0 <image> <version> <tag>..." >&2
  exit 1
fi

IMAGE="$1"
VERSION="$2"
shift 2

for tool in jq docker; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log "ERROR: '${tool}' is required but not found on PATH."
    exit 1
  fi
done

# Read the image config JSON for a ref (resolves manifest lists). Prints the
# JSON on success, nothing on failure.
image_config_json() {
  docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>/dev/null || true
}

# --- 1. Highest existing revision for this version -------------------------
read -r highest_rev found_tag < <(highest_revision "${VERSION}" "$@") || true
if [[ -z "${found_tag:-}" ]]; then
  log "no existing '${VERSION}-r<n>' tag found; nothing to refresh for this version."
  exit 0
fi
log "highest existing revision for ${VERSION} is r${highest_rev} (tag '${found_tag}')."

# --- 2. Resolve the published revision image and its base ------------------
published_ref="${IMAGE}:${found_tag}"
log "inspecting published image '${published_ref}'."
published_json="$(image_config_json "${published_ref}")"
if [[ -z "${published_json}" ]]; then
  log "could not resolve the published image '${published_ref}' (not published / not reachable); skipping ${VERSION}."
  exit 0
fi

published_epoch="$(printf '%s' "${published_json}" | image_created_epoch_from_json)"
if [[ -z "${published_epoch}" ]]; then
  log "published image '${published_ref}' has no 'created' timestamp; skipping ${VERSION}."
  exit 0
fi

base_name="$(printf '%s' "${published_json}" | image_base_label_from_json)"
if [[ -z "${base_name}" ]]; then
  log "published image '${published_ref}' has no base-image label (org.opencontainers.image.base.name); cannot determine base freshness; skipping ${VERSION}."
  exit 0
fi
base_ref="$(normalize_base_ref "${base_name}")"
log "revision r${highest_rev} was built on base image '${base_ref}'."

# --- 3. Compare base vs. published `created` -------------------------------
base_json="$(image_config_json "${base_ref}")"
if [[ -z "${base_json}" ]]; then
  log "could not resolve base image '${base_ref}'; skipping ${VERSION}."
  exit 0
fi
base_epoch="$(printf '%s' "${base_json}" | image_created_epoch_from_json)"
if [[ -z "${base_epoch}" ]]; then
  log "base image '${base_ref}' has no 'created' timestamp; skipping ${VERSION}."
  exit 0
fi

log "published '${found_tag}' created @ ${published_epoch}; base '${base_ref}' created @ ${base_epoch}."

if (( base_epoch > published_epoch )); then
  next_tag="${VERSION}-r$(( highest_rev + 1 ))"
  log "base image is NEWER than the published revision -> rebuild as '${next_tag}'."
  printf '%s\n' "${next_tag}"
else
  log "base image is not newer than the published revision -> no rebuild for ${VERSION}."
fi
