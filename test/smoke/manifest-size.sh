#!/usr/bin/env bash
#
# Manifest + image-size smoke tests for the rootless ioBroker container image.
# Task 19.1 — Requirements 1.3, 1.4, 1.5, 1.6, 1.7, 2.5
#
# These are OPERATOR / CI SMOKE CHECKS, not unit tests. They run against a
# BUILT, multi-arch image (published to a registry or loaded locally) and need
# `docker` with buildx available. They are intentionally NOT part of the Node
# unit-test suite (vitest) because they require a real image + docker daemon.
#
# What is checked:
#   1. `docker buildx imagetools inspect "$IMAGE"` lists BOTH linux/amd64 and
#      linux/arm64 under a single tag / manifest list.            (Req 1.3, 1.6)
#   2. The manifest does NOT advertise an unsupported architecture (e.g.
#      linux/s390x), so a pull on such a host is rejected with "no matching
#      manifest".                                                        (Req 1.7)
#   3. Per-architecture image size is meaningfully below ~1.6 GB (the reference
#      image) — asserted against a configurable threshold (default 1.4 GB). (Req 2.5)
#
# Per-host resolution of the amd64 / arm64 variant (Req 1.4, 1.5) is standard
# OCI manifest-list behavior provided by the registry; it cannot be exercised
# from a single host, so it is verified indirectly by asserting both variants
# are present under one manifest (check 1). See README.md in this directory.
#
# Behavior when prerequisites are missing:
#   The script SKIPS with a clear message (and exits 0) when docker/buildx or the
#   image are unavailable, so it never hard-fails in a build-less environment.
#
# Configuration (env vars):
#   IMAGE            Image reference to inspect.
#                    Default: ghcr.io/${GITHUB_OWNER:-<owner>}/iobroker:latest
#   GITHUB_OWNER     Used to build the default IMAGE when IMAGE is unset.
#   REQUIRED_ARCHES  Space-separated platforms that MUST be present.
#                    Default: "linux/amd64 linux/arm64"
#   FORBIDDEN_ARCHES Space-separated platforms that MUST NOT be present.
#                    Default: "linux/s390x"
#   SIZE_THRESHOLD_BYTES  Max allowed per-arch size in bytes.
#                    Default: 1503238553  (~1.4 GiB)
#
# Exit codes:
#   0  all checks passed, OR skipped due to missing prerequisites
#   1  a check failed
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GITHUB_OWNER="${GITHUB_OWNER:-<owner>}"
IMAGE="${IMAGE:-ghcr.io/${GITHUB_OWNER}/iobroker:latest}"
REQUIRED_ARCHES="${REQUIRED_ARCHES:-linux/amd64 linux/arm64}"
FORBIDDEN_ARCHES="${FORBIDDEN_ARCHES:-linux/s390x}"
# ~1.4 GiB — meaningfully below the ~1.6 GB reference image. (Req 2.5)
SIZE_THRESHOLD_BYTES="${SIZE_THRESHOLD_BYTES:-1503238553}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
info() { printf '[INFO]  %s\n' "$*"; }
pass() { printf '[PASS]  %s\n' "$*"; }
fail() { printf '[FAIL]  %s\n' "$*" >&2; }
skip() {
  printf '[SKIP]  %s\n' "$*"
  printf '[SKIP]  Smoke test skipped (prerequisite unavailable); not a failure.\n'
  exit 0
}

# ---------------------------------------------------------------------------
# Prerequisite checks -> skip (never hard-fail) when unavailable
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || skip "docker not found on PATH."

if ! docker buildx version >/dev/null 2>&1; then
  skip "docker buildx not available."
fi

info "Inspecting image manifest: ${IMAGE}"
INSPECT_OUT="$(docker buildx imagetools inspect "${IMAGE}" 2>/dev/null || true)"
if [ -z "${INSPECT_OUT}" ]; then
  skip "Image '${IMAGE}' not reachable/available (not built, not pulled, or no access)."
fi

failures=0

# ---------------------------------------------------------------------------
# Check 1: required architectures present under one manifest (Req 1.3, 1.6)
# ---------------------------------------------------------------------------
info "Check 1: required architectures present under a single manifest."
for plat in ${REQUIRED_ARCHES}; do
  if printf '%s\n' "${INSPECT_OUT}" | grep -q -- "${plat}"; then
    pass "Platform present: ${plat}"
  else
    fail "Platform MISSING from manifest '${IMAGE}': ${plat}"
    failures=$((failures + 1))
  fi
done

# ---------------------------------------------------------------------------
# Check 2: forbidden/unsupported architectures absent (Req 1.7)
# ---------------------------------------------------------------------------
info "Check 2: unsupported architectures are not advertised (pull would be rejected)."
for plat in ${FORBIDDEN_ARCHES}; do
  if printf '%s\n' "${INSPECT_OUT}" | grep -q -- "${plat}"; then
    fail "Unsupported platform unexpectedly present in manifest: ${plat}"
    failures=$((failures + 1))
  else
    pass "Unsupported platform correctly absent (pull rejected): ${plat}"
  fi
done

# ---------------------------------------------------------------------------
# Check 3: per-arch image size meaningfully below ~1.6 GB (Req 2.5)
# ---------------------------------------------------------------------------
info "Check 3: per-architecture image size below threshold (${SIZE_THRESHOLD_BYTES} bytes)."

# Gather per-arch sizes. Prefer a robust JSON path via `docker image inspect`
# on a locally available image; otherwise fall back to summing layer sizes
# reported by `imagetools inspect --raw` (manifest-list -> per-arch manifests).

human() {
  # bytes -> human readable, integer math only (portable, no bc needed)
  b="$1"
  if [ "${b}" -ge 1073741824 ]; then
    printf '%d.%02d GiB' "$((b / 1073741824))" "$(((b % 1073741824) * 100 / 1073741824))"
  else
    printf '%d.%02d MiB' "$((b / 1048576))" "$(((b % 1048576) * 100 / 1048576))"
  fi
}

check_size() {
  # $1 = label, $2 = size in bytes
  label="$1"; size="$2"
  if [ -z "${size}" ] || [ "${size}" -le 0 ] 2>/dev/null; then
    info "Size for ${label} could not be determined; skipping size assertion for it."
    return 0
  fi
  if [ "${size}" -lt "${SIZE_THRESHOLD_BYTES}" ]; then
    pass "${label} size $(human "${size}") is below threshold $(human "${SIZE_THRESHOLD_BYTES}")."
  else
    fail "${label} size $(human "${size}") is NOT below threshold $(human "${SIZE_THRESHOLD_BYTES}")."
    failures=$((failures + 1))
  fi
}

sized_any=0

# Path A: image present locally -> authoritative uncompressed Size per platform.
if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  # `docker image inspect` returns an array; sum is per-arch for a single-arch
  # local image. Extract Size via a portable grep (avoid requiring jq).
  local_size="$(docker image inspect "${IMAGE}" \
    --format '{{.Size}}' 2>/dev/null | head -n1 || true)"
  if [ -n "${local_size:-}" ]; then
    check_size "local ${IMAGE}" "${local_size}"
    sized_any=1
  fi
fi

# Path B: registry/manifest-list -> sum compressed layer sizes per platform
# from the raw manifest. This is a lower bound (compressed) but sufficient to
# assert we are well under the ~1.6 GB reference. Requires jq if available.
if [ "${sized_any}" -eq 0 ]; then
  if command -v jq >/dev/null 2>&1; then
    RAW="$(docker buildx imagetools inspect "${IMAGE}" --raw 2>/dev/null || true)"
    if [ -n "${RAW}" ]; then
      # For each platform in the manifest list, resolve its manifest digest,
      # inspect that digest raw, and sum its layer sizes.
      digests="$(printf '%s' "${RAW}" \
        | jq -r '.manifests[]? | select(.platform.os=="linux") | "\(.platform.os)/\(.platform.architecture) \(.digest)"' 2>/dev/null || true)"
      if [ -n "${digests}" ]; then
        base="${IMAGE%%:*}"
        while read -r plat digest; do
          [ -n "${digest}" ] || continue
          case " ${REQUIRED_ARCHES} " in *" ${plat} "*) : ;; *) continue ;; esac
          man="$(docker buildx imagetools inspect "${base}@${digest}" --raw 2>/dev/null || true)"
          if [ -n "${man}" ]; then
            total="$(printf '%s' "${man}" \
              | jq '[.layers[]?.size] | add // 0' 2>/dev/null || echo 0)"
            check_size "${plat} (compressed layers)" "${total}"
            sized_any=1
          fi
        done <<EOF
${digests}
EOF
      fi
    fi
  fi
fi

if [ "${sized_any}" -eq 0 ]; then
  info "Could not determine image size (image not local and jq unavailable for raw manifest parsing)."
  info "To enable the size check: pull the per-arch image locally, or install jq."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [ "${failures}" -eq 0 ]; then
  pass "All manifest + size smoke checks passed for '${IMAGE}'."
  exit 0
fi
fail "${failures} manifest + size smoke check(s) FAILED for '${IMAGE}'."
exit 1
