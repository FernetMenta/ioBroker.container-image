#!/usr/bin/env bash
# persist-package-json.sh (smoke) - verify package.json survives a container
# RECREATE (restore) and that the watcher captures runtime changes (watch),
# using verbatim copies (no rebuild/guessing).
#
# scripts/persist-package-json.sh keeps a byte-for-byte snapshot of package.json
# inside the persistent node_modules volume. `restore` copies the snapshot over
# the (image-reset) package.json on start so the next npm cannot prune adapters;
# `watch` copies package.json to the snapshot whenever it changes at runtime
# (only on an actual change), so an adapter installed via admin is captured for
# the next recreate. Drives the real script against temp dirs (no docker/npm/
# network), so it never skips.
#
# Exit codes: 0 all cases held; 1 a regression.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
PERSIST_SH="${REPO_ROOT}/scripts/persist-package-json.sh"

PASS_PREFIX="persist-package-json: PASS:"
FAIL_PREFIX="persist-package-json: FAIL:"

if [[ ! -r "${PERSIST_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot find ${PERSIST_SH}" >&2
  exit 1
fi

fail=""

new_root() {
  local root
  root="$(mktemp -d 2>/dev/null || echo "/tmp/iac-persist.$$.${RANDOM}")"
  mkdir -p "${root}/node_modules"
  printf '%s' "${root}"
}

run_restore() {
  local root="$1"
  IOB_ROOT="${root}" \
  IOB_NODE_MODULES_DIR="${root}/node_modules" \
  IOB_PKG_JSON="${root}/package.json" \
  IOB_PKG_JSON_SNAPSHOT="${root}/node_modules/.iob-package.json" \
  IOB_PKG_LOCK="${root}/package-lock.json" \
  IOB_PKG_LOCK_SNAPSHOT="${root}/node_modules/.iob-package-lock.json" \
    bash "${PERSIST_SH}" restore >/dev/null 2>&1
}

# marker <file> : print a stable content marker we can compare (the whole file).
content() { cat -- "$1" 2>/dev/null || printf ''; }

check() {
  local desc="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    printf '  ok   %-52s\n' "${desc}"
  else
    printf '  FAIL %-52s want=[%s] got=[%s]\n' "${desc}" "${want}" "${got}" >&2
    fail="${fail} [${desc}]"
  fi
}

echo "=== persist-package-json (restore) ==="

# --- Case 1: first start seeds the snapshot verbatim from package.json. -------
r1="$(new_root)"
printf 'PKG-FULL-35\n' >"${r1}/package.json"
run_restore "${r1}"
check "first start seeds snapshot verbatim" "$(content "${r1}/node_modules/.iob-package.json")" "PKG-FULL-35"
check "first start leaves package.json intact" "$(content "${r1}/package.json")" "PKG-FULL-35"
rm -rf -- "${r1}"

# --- Case 2: RECREATE restores the snapshot verbatim over the reset file. ----
r2="$(new_root)"
printf 'PKG-FULL-35\n' >"${r2}/node_modules/.iob-package.json"   # snapshot (grown at runtime)
printf 'PKG-BASELINE-1\n' >"${r2}/package.json"                  # image reset in fresh layer
run_restore "${r2}"
check "recreate restores full snapshot verbatim" "$(content "${r2}/package.json")" "PKG-FULL-35"
rm -rf -- "${r2}"

# --- Case 2-lock: RECREATE restores package-lock.json as the coherent pair. --
r2l="$(new_root)"
printf 'PKG-FULL-35\n' >"${r2l}/node_modules/.iob-package.json"        # pkg snapshot
printf 'LOCK-FULL-35\n' >"${r2l}/node_modules/.iob-package-lock.json"  # lock snapshot
printf 'PKG-BASELINE-1\n' >"${r2l}/package.json"                       # image reset
printf 'LOCK-BASELINE-1\n' >"${r2l}/package-lock.json"                 # image reset
run_restore "${r2l}"
check "recreate restores package.json verbatim" "$(content "${r2l}/package.json")" "PKG-FULL-35"
check "recreate restores package-lock.json verbatim" "$(content "${r2l}/package-lock.json")" "LOCK-FULL-35"
# The restored lockfile must not be older than package.json (npm staleness).
pkg_mtime="$(stat -c '%Y' "${r2l}/package.json" 2>/dev/null)"
lock_mtime="$(stat -c '%Y' "${r2l}/package-lock.json" 2>/dev/null)"
if [[ -n "${pkg_mtime}" && -n "${lock_mtime}" && "${lock_mtime}" -ge "${pkg_mtime}" ]]; then ok_pair="yes"; else ok_pair="no"; fi
check "restored lockfile is not older than package.json" "${ok_pair}" "yes"
rm -rf -- "${r2l}"

# --- Case 2-lock-seed: first start seeds the lock snapshot from the live file. -
r2ls="$(new_root)"
printf 'LOCK-LIVE-9\n' >"${r2ls}/package-lock.json"   # live lockfile, no snapshot yet
run_restore "${r2ls}"
check "first start seeds lock snapshot verbatim" "$(content "${r2ls}/node_modules/.iob-package-lock.json")" "LOCK-LIVE-9"
rm -rf -- "${r2ls}"

echo "=== persist-package-json (watch) ==="

# --- Case 3: watch copies package.json to the snapshot ONLY on change. -------
r3="$(new_root)"
printf 'PKG-V1\n' >"${r3}/package.json"
printf 'PKG-V1\n' >"${r3}/node_modules/.iob-package.json"   # already in sync at watch start
printf 'LOCK-V1\n' >"${r3}/package-lock.json"
printf 'LOCK-V1\n' >"${r3}/node_modules/.iob-package-lock.json"
# Start the watcher with a short interval in the background.
IOB_ROOT="${r3}" \
IOB_NODE_MODULES_DIR="${r3}/node_modules" \
IOB_PKG_JSON="${r3}/package.json" \
IOB_PKG_JSON_SNAPSHOT="${r3}/node_modules/.iob-package.json" \
IOB_PKG_LOCK="${r3}/package-lock.json" \
IOB_PKG_LOCK_SNAPSHOT="${r3}/node_modules/.iob-package-lock.json" \
IOB_PKG_WATCH_INTERVAL=1 \
  bash "${PERSIST_SH}" watch >/dev/null 2>&1 &
watch_pid=$!

# Give the watcher a moment, then change both files (an install rewrites both).
sleep 2
printf 'PKG-V2-adminadapter\n' >"${r3}/package.json"
printf 'LOCK-V2-adminadapter\n' >"${r3}/package-lock.json"
touch -- "${r3}/package.json" "${r3}/package-lock.json"
# Wait for at least one poll cycle to capture it.
sleep 3

got3="$(content "${r3}/node_modules/.iob-package.json")"
got3lock="$(content "${r3}/node_modules/.iob-package-lock.json")"
kill "${watch_pid}" 2>/dev/null || true
wait "${watch_pid}" 2>/dev/null || true
check "watch captures a package.json change to the snapshot" "${got3}" "PKG-V2-adminadapter"
check "watch captures a package-lock.json change to the snapshot" "${got3lock}" "LOCK-V2-adminadapter"
rm -rf -- "${r3}"

# --- Case 3b: watch does NOT copy when only mtime changes (content same). ----
# Detect a spurious copy by watching the snapshot's own mtime: if the watcher
# rewrites it despite identical content, its mtime advances.
r3b="$(new_root)"
printf 'PKG-SAME\n' >"${r3b}/package.json"
printf 'PKG-SAME\n' >"${r3b}/node_modules/.iob-package.json"
snap_mtime_before="$(stat -c '%Y' "${r3b}/node_modules/.iob-package.json" 2>/dev/null)"
IOB_ROOT="${r3b}" \
IOB_NODE_MODULES_DIR="${r3b}/node_modules" \
IOB_PKG_JSON="${r3b}/package.json" \
IOB_PKG_JSON_SNAPSHOT="${r3b}/node_modules/.iob-package.json" \
IOB_PKG_WATCH_INTERVAL=1 \
  bash "${PERSIST_SH}" watch >/dev/null 2>&1 &
wpid3b=$!
sleep 1
touch -- "${r3b}/package.json"   # bump mtime only; content unchanged
sleep 3
snap_mtime_after="$(stat -c '%Y' "${r3b}/node_modules/.iob-package.json" 2>/dev/null)"
kill "${wpid3b}" 2>/dev/null || true
wait "${wpid3b}" 2>/dev/null || true
check "watch skips copy when content unchanged (mtime-only)" "${snap_mtime_after}" "${snap_mtime_before}"
rm -rf -- "${r3b}"

# --- Case 4: watch exits promptly on SIGTERM. --------------------------------
r4="$(new_root)"
printf 'PKG-V1\n' >"${r4}/package.json"
IOB_ROOT="${r4}" \
IOB_NODE_MODULES_DIR="${r4}/node_modules" \
IOB_PKG_JSON="${r4}/package.json" \
IOB_PKG_JSON_SNAPSHOT="${r4}/node_modules/.iob-package.json" \
IOB_PKG_WATCH_INTERVAL=5 \
  bash "${PERSIST_SH}" watch >/dev/null 2>&1 &
wpid=$!
sleep 1
kill -TERM "${wpid}" 2>/dev/null || true
# Give it up to ~3s to exit; it should be well under the 5s poll interval.
exited="no"
for _ in 1 2 3; do
  if ! kill -0 "${wpid}" 2>/dev/null; then exited="yes"; break; fi
  sleep 1
done
wait "${wpid}" 2>/dev/null || true
check "watch exits promptly on SIGTERM (< poll interval)" "${exited}" "yes"
rm -rf -- "${r4}"

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} failures:${fail}" >&2
  echo "=== persist-package-json FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} restore + watch behave correctly"
echo "=== persist-package-json PASSED ==="
exit 0
