#!/usr/bin/env bash
# installed-adapters-complete.sh - smoke test for reconcile's installed-adapter
# COMPLETENESS check (`adapter_dir_complete` + `installed_adapters`).
#
# WHY THIS TEST EXISTS
# --------------------
# Reconciliation converges node_modules to the Data_Volume by installing the
# adapters that are DESIRED but not INSTALLED. "Installed" used to mean only
# "the directory node_modules/iobroker.<name> exists". That let a
# present-but-INCOMPLETE tree (interrupted npm install, an npm prune that
# stripped a package's files, a truncated copy) count as installed, so:
#
#   * reconciliation SKIPPED it (never repaired), and
#   * js-controller crashed at runtime on the missing files — the concrete
#     regression that motivated this test is iobroker.admin whose built UI
#     directory `adminWww/` was gone, throwing
#     `ENOENT ... scandir '.../iobroker.admin/adminWww'` on every request.
#
# `installed_adapters()` now counts an adapter only when `adapter_dir_complete`
# holds: package.json is readable AND the entry point it declares (`main`,
# default main.js) exists on disk. This test pins that contract with a set of
# hand-built node_modules trees (no ioBroker, no container, no network).
#
# It is placed under test/smoke/ because it drives SHELL functions rather than a
# `lib/*.js` module (the vitest suite covers the JS modules); it needs only bash
# + coreutils and (optionally) node, so it never skips.
#
# Exit codes:
#   0  all completeness expectations held
#   1  at least one expectation failed (regression)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
RECONCILE_SH="${REPO_ROOT}/scripts/reconcile.sh"

PASS_PREFIX="installed-adapters-complete: PASS:"
FAIL_PREFIX="installed-adapters-complete: FAIL:"

if [[ ! -r "${RECONCILE_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot read ${RECONCILE_SH}" >&2
  exit 1
fi

# Extract JUST the two functions under test from reconcile.sh and eval them in
# THIS shell. reconcile.sh runs a full observe->plan->act pipeline on load (it
# is not written to be `source`d), so we must not source the whole file. Each
# block runs from its `name() {` line through the closing `}` at column 0, which
# is how the functions are formatted in the script.
for fn in adapter_dir_complete installed_adapters; do
  fn_src="$(sed -n "/^${fn}() {/,/^}/p" "${RECONCILE_SH}")"
  if [[ -z "${fn_src}" ]]; then
    echo "${FAIL_PREFIX} could not extract ${fn}() from ${RECONCILE_SH}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  eval "${fn_src}"
  if ! declare -F "${fn}" >/dev/null 2>&1; then
    echo "${FAIL_PREFIX} ${fn}() did not define after eval" >&2
    exit 1
  fi
done

# Build an isolated fake node_modules tree.
IOB_NODE_MODULES_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/iac-nm.$$")"
export IOB_NODE_MODULES_DIR
cleanup() { rm -rf -- "${IOB_NODE_MODULES_DIR}" 2>/dev/null || true; }
trap cleanup EXIT

# mk_complete <name> [mainRel] : a complete adapter (package.json + entry file).
mk_complete() {
  local name="$1" main_rel="${2:-main.js}" dir
  dir="${IOB_NODE_MODULES_DIR}/iobroker.${name}"
  mkdir -p "${dir}"
  printf '{"name":"iobroker.%s","version":"1.0.0","main":"%s"}\n' "${name}" "${main_rel}" >"${dir}/package.json"
  mkdir -p "${dir}/$(dirname -- "${main_rel}")"
  printf '// entry\n' >"${dir}/${main_rel}"
}

# mk_incomplete_no_main <name> : package.json present but its entry file missing.
mk_incomplete_no_main() {
  local name="$1" dir
  dir="${IOB_NODE_MODULES_DIR}/iobroker.${name}"
  mkdir -p "${dir}"
  printf '{"name":"iobroker.%s","version":"1.0.0","main":"build/main.js"}\n' "${name}" >"${dir}/package.json"
  # deliberately do NOT create build/main.js
}

# mk_incomplete_no_pkg <name> : directory present but no package.json (the
# "present shell, tree truncated" case, e.g. admin left with only adminWww gone
# AND manifest stripped; here we model the manifest-missing variant).
mk_incomplete_no_pkg() {
  local name="$1" dir
  dir="${IOB_NODE_MODULES_DIR}/iobroker.${name}"
  mkdir -p "${dir}/admin"
  printf 'x\n' >"${dir}/admin/placeholder"
  # no package.json
}

# mk_default_main <name> : package.json WITHOUT a `main` field; Node defaults to
# main.js, which we DO create -> complete.
mk_default_main() {
  local name="$1" dir
  dir="${IOB_NODE_MODULES_DIR}/iobroker.${name}"
  mkdir -p "${dir}"
  printf '{"name":"iobroker.%s","version":"1.0.0"}\n' "${name}" >"${dir}/package.json"
  printf '// entry\n' >"${dir}/main.js"
}

# Populate the fixture set.
mk_complete           good            # complete, explicit main.js
mk_complete           nested build/index.js   # complete, main in a subdir
mk_default_main       nomain          # complete via default main.js
mk_incomplete_no_main partial         # present but entry file missing
mk_incomplete_no_pkg  shell           # present but no manifest

fail=""

# expect_complete <dir-name> <yes|no> <why>
expect_complete() {
  local name="$1" want="$2" why="$3" got
  if adapter_dir_complete "${IOB_NODE_MODULES_DIR}/iobroker.${name}"; then got="yes"; else got="no"; fi
  if [[ "${got}" == "${want}" ]]; then
    printf '  ok   [complete=%-3s] %-10s %s\n' "${got}" "${name}" "${why}"
  else
    printf '  FAIL want=%-3s got=%-3s  %-10s %s\n' "${want}" "${got}" "${name}" "${why}" >&2
    fail="${fail} [adapter_dir_complete:${name}]"
  fi
}

echo "=== adapter_dir_complete ==="
expect_complete good    yes "complete tree (explicit main.js) -> complete"
expect_complete nested  yes "complete tree (main in subdir) -> complete"
expect_complete nomain  yes "no main field, default main.js present -> complete"
expect_complete partial no  "package.json present but entry file missing -> incomplete"
expect_complete shell   no  "no package.json -> incomplete"

# installed_adapters should list ONLY the complete adapters, sorted, unique.
echo "=== installed_adapters (only complete trees reported) ==="
got_list="$(installed_adapters | tr '\n' ' ' | sed 's/ *$//')"
want_list="good nested nomain"
if [[ "${got_list}" == "${want_list}" ]]; then
  printf '  ok   list=[%s]\n' "${got_list}"
else
  printf '  FAIL want=[%s] got=[%s]\n' "${want_list}" "${got_list}" >&2
  fail="${fail} [installed_adapters-list]"
fi

# An empty node_modules yields an empty list (and no error).
echo "=== installed_adapters (empty node_modules) ==="
empty_nm="$(mktemp -d 2>/dev/null || echo "/tmp/iac-nm-empty.$$")"
if out="$(IOB_NODE_MODULES_DIR="${empty_nm}" installed_adapters)" && [[ -z "${out}" ]]; then
  printf '  ok   empty node_modules -> empty list\n'
else
  printf '  FAIL empty node_modules -> [%s]\n' "${out}" >&2
  fail="${fail} [installed_adapters-empty]"
fi
rm -rf -- "${empty_nm}" 2>/dev/null || true

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} failures:${fail}" >&2
  echo "=== installed-adapters completeness FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} all completeness expectations held"
echo "=== installed-adapters completeness PASSED ==="
exit 0
