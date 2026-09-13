#!/usr/bin/env bash
# persist-package-json.sh (smoke) - verify the START-TIME rebuild of
# package.json keeps it a SUPERSET of node_modules across a container recreate,
# WITHOUT corrupting non-trivial dependency specs.
#
# scripts/persist-package-json.sh `restore` rebuilds /opt/iobroker/package.json
# as a merge of: the persisted snapshot (.iob-package.json, authoritative specs)
# + the current live package.json + every package present on disk under
# node_modules (added with its own version only if not already a dependency).
# The result is written to both the live file and the snapshot. This test drives
# the real script against hand-built fixtures (no docker/npm/network), asserting:
#
#   * first start (no snapshot) seeds the snapshot and lists on-disk packages,
#   * a recreate (live reset to 1 dep) PRESERVES github:/npm-alias/range specs
#     verbatim from the snapshot (never rewritten to a bare on-disk version),
#   * an adapter present on disk but absent from both snapshot and live (the
#     "installed via admin at runtime, then recreated" case) is ADDED so the
#     next npm cannot prune it,
#   * scoped packages (@scope/name) on disk are handled,
#   * the snapshot is refreshed to match (no separate save step).
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
if ! command -v node >/dev/null 2>&1; then
  echo "${FAIL_PREFIX} node required for this test but not found" >&2
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
  IOB_PKG_JSON_PERSIST="${root}/node_modules/.iob-package.json" \
    bash "${PERSIST_SH}" restore >/dev/null 2>&1
}

# mk_pkg_dir <root> <pkgname> <version> : a node_modules package dir with a
# package.json carrying <version>. Handles @scope/name.
mk_pkg_dir() {
  local root="$1" name="$2" ver="$3" dir
  dir="${root}/node_modules/${name}"
  mkdir -p "${dir}"
  printf '{"name":"%s","version":"%s"}\n' "${name}" "${ver}" >"${dir}/package.json"
}

# dep_spec <file> <name> : print the dependency spec for <name>, or empty.
dep_spec() {
  local f="$1" name="$2"
  [[ -r "${f}" ]] || { printf ''; return; }
  IOB_Q_FILE="${f}" IOB_Q_NAME="${name}" node -e '
    try {
      const o = JSON.parse(require("fs").readFileSync(process.env.IOB_Q_FILE, "utf8"));
      const d = (o && o.dependencies) || {};
      process.stdout.write(String(d[process.env.IOB_Q_NAME] ?? ""));
    } catch { process.stdout.write(""); }
  ' 2>/dev/null
}

check_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    printf '  ok   %-58s (%s)\n' "${desc}" "${got:-<empty>}"
  else
    printf '  FAIL %-58s want=[%s] got=[%s]\n' "${desc}" "${want}" "${got}" >&2
    fail="${fail} [${desc}]"
  fi
}

echo "=== persist-package-json (start-time rebuild / merge) ==="

# --- Case 1: first start seeds the snapshot and lists on-disk packages. -------
r1="$(new_root)"
cat >"${r1}/package.json" <<'JSON'
{ "name": "iobroker.inst", "dependencies": { "iobroker.js-controller": "7.2.2" } }
JSON
mk_pkg_dir "${r1}" "iobroker.js-controller" "7.2.2"
mk_pkg_dir "${r1}" "iobroker.admin" "8.0.11"
run_restore "${r1}"
check_eq "first start: snapshot seeded (admin listed)" "$(dep_spec "${r1}/node_modules/.iob-package.json" iobroker.admin)" "8.0.11"
check_eq "first start: live gains on-disk admin" "$(dep_spec "${r1}/package.json" iobroker.admin)" "8.0.11"
rm -rf -- "${r1}"

# --- Case 2: RECREATE preserves non-trivial specs from the snapshot. ---------
# snapshot carries the authoritative specs; live was reset to the image baseline.
r2="$(new_root)"
cat >"${r2}/node_modules/.iob-package.json" <<'JSON'
{
  "name": "iobroker.inst",
  "dependencies": {
    "iobroker.js-controller": "7.2.2",
    "iobroker.admin": "8.0.11",
    "iobroker.lovelace": "^6.1.3",
    "iobroker.mielecloudservice": "github:Grizzelbee/ioBroker.mielecloudservice#development",
    "@iobroker-javascript.0/csv-parse": "npm:csv-parse@^7.0.2"
  }
}
JSON
cat >"${r2}/package.json" <<'JSON'
{ "name": "iobroker.inst", "dependencies": { "iobroker.js-controller": "7.2.2" } }
JSON
# on disk: the adapters exist with their real installed versions
mk_pkg_dir "${r2}" "iobroker.js-controller" "7.2.2"
mk_pkg_dir "${r2}" "iobroker.admin" "8.0.11"
mk_pkg_dir "${r2}" "iobroker.lovelace" "6.1.3"
mk_pkg_dir "${r2}" "iobroker.mielecloudservice" "7.0.0"
run_restore "${r2}"
# github spec must survive verbatim (NOT rewritten to the on-disk 7.0.0)
check_eq "recreate: github spec preserved" \
  "$(dep_spec "${r2}/package.json" iobroker.mielecloudservice)" \
  "github:Grizzelbee/ioBroker.mielecloudservice#development"
check_eq "recreate: range spec preserved" \
  "$(dep_spec "${r2}/package.json" iobroker.lovelace)" "^6.1.3"
check_eq "recreate: npm-alias spec preserved" \
  "$(dep_spec "${r2}/package.json" '@iobroker-javascript.0/csv-parse')" "npm:csv-parse@^7.0.2"
check_eq "recreate: pinned spec preserved" \
  "$(dep_spec "${r2}/package.json" iobroker.admin)" "8.0.11"
rm -rf -- "${r2}"

# --- Case 3: admin-installed adapter (on disk, not in snapshot/live) added. --
r3="$(new_root)"
cat >"${r3}/node_modules/.iob-package.json" <<'JSON'
{ "name": "iobroker.inst", "dependencies": { "iobroker.js-controller": "7.2.2", "iobroker.admin": "8.0.11" } }
JSON
cat >"${r3}/package.json" <<'JSON'
{ "name": "iobroker.inst", "dependencies": { "iobroker.js-controller": "7.2.2" } }
JSON
mk_pkg_dir "${r3}" "iobroker.js-controller" "7.2.2"
mk_pkg_dir "${r3}" "iobroker.admin" "8.0.11"
mk_pkg_dir "${r3}" "iobroker.newlyadded" "1.4.2"   # installed via admin, not in any manifest
run_restore "${r3}"
check_eq "admin-install: on-disk-only adapter added (prevents prune)" \
  "$(dep_spec "${r3}/package.json" iobroker.newlyadded)" "1.4.2"
check_eq "admin-install: snapshot updated too" \
  "$(dep_spec "${r3}/node_modules/.iob-package.json" iobroker.newlyadded)" "1.4.2"
rm -rf -- "${r3}"

# --- Case 4: scoped package on disk is handled. ------------------------------
r4="$(new_root)"
cat >"${r4}/package.json" <<'JSON'
{ "name": "iobroker.inst", "dependencies": { "iobroker.js-controller": "7.2.2" } }
JSON
mk_pkg_dir "${r4}" "iobroker.js-controller" "7.2.2"
mk_pkg_dir "${r4}" "@scope/thing" "2.5.0"
run_restore "${r4}"
check_eq "scoped package on disk added" "$(dep_spec "${r4}/package.json" '@scope/thing')" "2.5.0"
rm -rf -- "${r4}"

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} failures:${fail}" >&2
  echo "=== persist-package-json FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} start-time rebuild keeps package.json a superset and preserves specs"
echo "=== persist-package-json PASSED ==="
exit 0
