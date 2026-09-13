#!/usr/bin/env bash
# persist-package-json.sh (smoke) - verify package.json survives a container
# RECREATE so the node_modules volume never gets pruned.
#
# WHY THIS TEST EXISTS
# --------------------
# node_modules is a persistent volume; package.json is not. A recreate resets
# package.json to the image baseline (1 dependency) while node_modules still
# holds every adapter, and the next `npm install` prunes the "extraneous"
# adapters. scripts/persist-package-json.sh keeps an authoritative copy inside
# the node_modules volume and restores it on start BEFORE anything prunes. This
# test drives that script through the exact restart/recreate/first-start cases.
#
# Drives the real scripts/persist-package-json.sh against temp dirs (no docker,
# no npm, no network), so it never skips.
#
# Exit codes: 0 all cases held; 1 a regression.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
PERSIST_SH="${REPO_ROOT}/scripts/persist-package-json.sh"

PASS_PREFIX="persist-package-json: PASS:"
FAIL_PREFIX="persist-package-json: FAIL:"

if [[ ! -x "${PERSIST_SH}" ]] && [[ ! -r "${PERSIST_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot find ${PERSIST_SH}" >&2
  exit 1
fi

fail=""

# Each case runs in its own fake IOB_ROOT with a node_modules subdir.
new_root() {
  local root
  root="$(mktemp -d 2>/dev/null || echo "/tmp/iac-persist.$$.${RANDOM}")"
  mkdir -p "${root}/node_modules"
  printf '%s' "${root}"
}

run_persist() {
  local root="$1" action="$2"
  IOB_ROOT="${root}" \
  IOB_NODE_MODULES_DIR="${root}/node_modules" \
  IOB_PKG_JSON="${root}/package.json" \
  IOB_PKG_JSON_PERSIST="${root}/node_modules/.iob-package.json" \
    bash "${PERSIST_SH}" "${action}" >/dev/null 2>&1
}

# deps_count <file> : number of top-level keys in the JSON "dependencies" object,
# via a tiny awk-free node-free parser using grep (the fixtures are simple, one
# dependency per line).
deps_count() {
  local f="$1"
  [[ -r "${f}" ]] || { printf '%s' "-1"; return; }
  # count only the dependency entries the fixtures write (iobroker.dep<N>), so
  # the surrounding "name"/etc. fields are not miscounted as dependencies.
  grep -cE '"iobroker\.dep[0-9]+"[[:space:]]*:' "${f}"
}

# write_pkg <file> <n> : write a package.json-ish file with n dependency lines.
write_pkg() {
  local f="$1" n="$2" i
  {
    printf '{\n  "name": "iobroker.inst",\n  "dependencies": {\n'
    for ((i = 1; i <= n; i++)); do
      if [[ "${i}" -lt "${n}" ]]; then
        printf '    "iobroker.dep%d": "1.0.0",\n' "${i}"
      else
        printf '    "iobroker.dep%d": "1.0.0"\n' "${i}"
      fi
    done
    printf '  }\n}\n'
  } >"${f}"
}

check() {
  local desc="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    printf '  ok   %-55s (deps=%s)\n' "${desc}" "${got}"
  else
    printf '  FAIL %-55s want=%s got=%s\n' "${desc}" "${want}" "${got}" >&2
    fail="${fail} [${desc}]"
  fi
}

echo "=== persist-package-json ==="

# --- Case 1: first start seeds the persisted copy from the current file. -----
r1="$(new_root)"
write_pkg "${r1}/package.json" 32          # image already grown / full
run_persist "${r1}" restore
check "first start seeds persisted copy" "$(deps_count "${r1}/node_modules/.iob-package.json")" "32"
check "first start leaves live file intact" "$(deps_count "${r1}/package.json")" "32"
rm -rf -- "${r1}"

# --- Case 2: RECREATE restores the full manifest over an image-reset file. ---
# Simulate: persisted copy has full set (32); live package.json was reset by the
# fresh container layer to the image baseline (1). restore must bring it back.
r2="$(new_root)"
write_pkg "${r2}/node_modules/.iob-package.json" 32   # persisted (grown at runtime, on the volume)
write_pkg "${r2}/package.json" 1                      # image baseline in the fresh layer
run_persist "${r2}" restore
check "recreate restores full package.json over reset" "$(deps_count "${r2}/package.json")" "32"
rm -rf -- "${r2}"

# --- Case 3: save captures runtime growth for the next recreate. -------------
r3="$(new_root)"
write_pkg "${r3}/node_modules/.iob-package.json" 20   # persisted lags behind
write_pkg "${r3}/package.json" 33                     # runtime grew it further
run_persist "${r3}" save
check "save refreshes persisted copy from live file" "$(deps_count "${r3}/node_modules/.iob-package.json")" "33"
rm -rf -- "${r3}"

# --- Case 4: restore after a save round-trips (idempotent sync). -------------
r4="$(new_root)"
write_pkg "${r4}/package.json" 30
run_persist "${r4}" restore     # seeds 30
write_pkg "${r4}/package.json" 1  # simulate recreate reset
run_persist "${r4}" restore     # should restore 30
check "seed then recreate-restore round-trips" "$(deps_count "${r4}/package.json")" "30"
rm -rf -- "${r4}"

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} failures:${fail}" >&2
  echo "=== persist-package-json FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} package.json persists across recreate as expected"
echo "=== persist-package-json PASSED ==="
exit 0
