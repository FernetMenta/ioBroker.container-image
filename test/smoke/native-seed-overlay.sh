#!/usr/bin/env bash
# native-seed-overlay.sh (smoke) - verify the native-module seed overlay logic
# in scripts/reconcile.sh WITHOUT a real ioBroker install, registry, or compiler.
#
# Reproduces the exact failure the fix targets: a Node-major upgrade leaves the
# persisted node_modules with a native module whose compiled .node is stale /
# missing (here: unix-dgram), while the toolchain-free runtime image cannot
# rebuild it from source. The image stashes a pristine, correct-ABI copy under
# IOB_NATIVE_SEED_DIR; overlay_native_seed() must copy it over the volume.
#
# We source ONLY the relevant function definitions out of reconcile.sh (the real
# code, extracted verbatim) so we exercise the shipped implementation rather than
# a reimplementation, without triggering the script's main flow (which sets a
# trap and begins reconciliation at source time).
#
# Asserts:
#   * seed_native_modules() lists exactly the native dirs present in the seed,
#   * overlay_native_seed() copies the seed's binaries over the volume,
#   * a volume module that EXISTS in the seed is repaired (binary restored),
#   * a volume module NOT in the seed is left untouched,
#   * dry-run performs no copy.
#
# Exit codes: 0 all cases held; 1 a regression.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
RECONCILE_SH="${REPO_ROOT}/scripts/reconcile.sh"

PASS_PREFIX="native-seed-overlay: PASS:"
FAIL_PREFIX="native-seed-overlay: FAIL:"

if [[ ! -r "${RECONCILE_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot read ${RECONCILE_SH}" >&2
  exit 1
fi

fail=""

# Extract the function definitions we need, verbatim, from reconcile.sh. We pull
# the contiguous block from `seed_native_modules()` through the end of
# `overlay_native_seed()` (its closing brace on a line by itself). This is the
# real shipped code; if the function names/shape change, this extraction (and
# thus the test) breaks loudly, which is the intent.
FUNCS="$(mktemp 2>/dev/null || echo "/tmp/iac-seed-funcs.$$")"
sed -n '/^native_module_names_under() {/,/^}/p; /^seed_native_modules() {/,/^}/p; /^overlay_native_seed() {/,/^}/p' \
  "${RECONCILE_SH}" >"${FUNCS}"

if ! grep -q 'native_module_names_under() {' "${FUNCS}" \
   || ! grep -q 'seed_native_modules() {' "${FUNCS}" \
   || ! grep -q 'overlay_native_seed() {' "${FUNCS}"; then
  echo "${FAIL_PREFIX} could not extract seed/overlay functions from reconcile.sh" >&2
  rm -f -- "${FUNCS}"
  exit 1
fi

# Minimal log() shim (reconcile.sh's log writes to stderr); the functions call it.
log() { printf 'reconcile(test): %s\n' "$*" >&2; }

# shellcheck source=/dev/null
. "${FUNCS}"

echo "=== native-seed-overlay ==="

# --- Build a sandbox: a seed dir (image-pristine) and a volume (persisted). ---
# Seed provides correct-ABI binaries for diskusage + unix-dgram.
# Volume has unix-dgram WITHOUT its .node (the broken upgrade state) and an
# unrelated adapter native 'serialport' the seed must NOT touch.
make_sandbox() {
  local sbx
  sbx="$(mktemp -d 2>/dev/null || echo "/tmp/iac-seed.$$.${RANDOM}")"
  mkdir -p "${sbx}/seed/diskusage/build/Release" \
           "${sbx}/seed/unix-dgram/build/Release" \
           "${sbx}/vol/unix-dgram/build/Release" \
           "${sbx}/vol/serialport/build/Release"
  # Seed binaries (pristine, correct ABI).
  printf 'SEED-DISKUSAGE\n'  >"${sbx}/seed/diskusage/build/Release/diskusage.node"
  printf 'SEED-UNIXDGRAM\n'  >"${sbx}/seed/unix-dgram/build/Release/unix_dgram.node"
  printf '137\n'             >"${sbx}/seed/.node-abi"
  # Volume: unix-dgram present but its .node MISSING (broken), serialport intact.
  printf '{"name":"unix-dgram"}\n' >"${sbx}/vol/unix-dgram/package.json"
  printf 'VOL-SERIALPORT\n'        >"${sbx}/vol/serialport/build/Release/serialport.node"
  printf '%s' "${sbx}"
}

# --- Case 1: seed_native_modules lists exactly the seed's native dirs. --------
sbx="$(make_sandbox)"
IOB_NATIVE_SEED_DIR="${sbx}/seed" IOB_NODE_MODULES_DIR="${sbx}/vol" IOB_RECONCILE_DRY_RUN=false
export IOB_NATIVE_SEED_DIR IOB_NODE_MODULES_DIR IOB_RECONCILE_DRY_RUN
listed="$(seed_native_modules | sort | tr '\n' ' ' | sed 's/ *$//')"
if [[ "${listed}" == "diskusage unix-dgram" ]]; then
  printf '  ok   seed_native_modules lists seed natives (%s)\n' "${listed}"
else
  printf '  FAIL seed_native_modules got [%s], want [diskusage unix-dgram]\n' "${listed}" >&2
  fail="${fail} [seed-list]"
fi

# --- Case 2: overlay repairs unix-dgram and does NOT touch serialport. --------
if overlay_native_seed >/dev/null 2>&1; then orc=0; else orc=$?; fi
ok=1
[[ "${orc}" -eq 0 ]] || ok=0
# unix-dgram binary restored from seed:
[[ -f "${sbx}/vol/unix-dgram/build/Release/unix_dgram.node" ]] || ok=0
grep -q 'SEED-UNIXDGRAM' "${sbx}/vol/unix-dgram/build/Release/unix_dgram.node" 2>/dev/null || ok=0
# diskusage overlaid too:
grep -q 'SEED-DISKUSAGE' "${sbx}/vol/diskusage/build/Release/diskusage.node" 2>/dev/null || ok=0
# serialport (not in seed) left untouched:
grep -q 'VOL-SERIALPORT' "${sbx}/vol/serialport/build/Release/serialport.node" 2>/dev/null || ok=0
if [[ "${ok}" -eq 1 ]]; then
  printf '  ok   overlay restored seed natives, left non-seed module untouched\n'
else
  printf '  FAIL overlay result wrong (orc=%s)\n' "${orc}" >&2
  fail="${fail} [overlay-copy]"
fi
rm -rf -- "${sbx}"

# --- Case 3: dry-run performs NO copy. ---------------------------------------
sbx="$(make_sandbox)"
IOB_NATIVE_SEED_DIR="${sbx}/seed" IOB_NODE_MODULES_DIR="${sbx}/vol" IOB_RECONCILE_DRY_RUN=true
export IOB_NATIVE_SEED_DIR IOB_NODE_MODULES_DIR IOB_RECONCILE_DRY_RUN
overlay_native_seed >/dev/null 2>&1 || true
if [[ ! -e "${sbx}/vol/diskusage/build/Release/diskusage.node" ]] \
   && [[ ! -f "${sbx}/vol/unix-dgram/build/Release/unix_dgram.node" ]]; then
  printf '  ok   dry-run performed no copy\n'
else
  printf '  FAIL dry-run copied files\n' >&2
  fail="${fail} [dry-run-nocopy]"
fi
rm -rf -- "${sbx}"

# --- Case 4: missing/empty seed -> overlay reports failure (nonzero). --------
sbx="$(mktemp -d)"; mkdir -p "${sbx}/vol"
IOB_NATIVE_SEED_DIR="${sbx}/does-not-exist" IOB_NODE_MODULES_DIR="${sbx}/vol" IOB_RECONCILE_DRY_RUN=false
export IOB_NATIVE_SEED_DIR IOB_NODE_MODULES_DIR IOB_RECONCILE_DRY_RUN
if overlay_native_seed >/dev/null 2>&1; then orc=0; else orc=$?; fi
if [[ "${orc}" -ne 0 ]]; then
  printf '  ok   missing seed -> overlay returns nonzero (caller degrades to warn)\n'
else
  printf '  FAIL missing seed should return nonzero, got %s\n' "${orc}" >&2
  fail="${fail} [missing-seed]"
fi
rm -rf -- "${sbx}"

rm -f -- "${FUNCS}"

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} failures:${fail}" >&2
  echo "=== native-seed-overlay FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} seed overlay repairs image natives, leaves others, honors dry-run"
echo "=== native-seed-overlay PASSED ==="
exit 0
