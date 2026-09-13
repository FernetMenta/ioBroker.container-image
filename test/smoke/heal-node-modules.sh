#!/usr/bin/env bash
# heal-node-modules.sh (smoke) - verify the node_modules self-heal wrapper's
# control flow WITHOUT touching the network.
#
# scripts/heal-node-modules.sh runs a single `npm install` against
# /opt/iobroker/package.json to rebuild any missing (hoisted) adapter
# dependencies after a prune left the tree incomplete. This test stubs `npm` on
# PATH so we can assert:
#   * it is SKIPPED when IOB_HEAL_NODE_MODULES=false,
#   * it is SKIPPED when there is no package.json,
#   * when enabled it runs `npm install` from IOB_ROOT with the expected flags
#     (--omit=dev, non-pruning: no --production/--force),
#   * an npm failure is TOLERATED (script still exits 0; startup not blocked).
#
# No docker, no real npm, no network -> never skips.
#
# Exit codes: 0 all cases held; 1 a regression.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
HEAL_SH="${REPO_ROOT}/scripts/heal-node-modules.sh"

PASS_PREFIX="heal-node-modules: PASS:"
FAIL_PREFIX="heal-node-modules: FAIL:"

if [[ ! -r "${HEAL_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot read ${HEAL_SH}" >&2
  exit 1
fi

fail=""

# Build a sandbox: a fake IOB_ROOT and a stub `npm` on PATH that records how it
# was invoked (argv + cwd) into a log file instead of doing anything.
SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/iac-heal.$$")"
BIN="${SANDBOX}/bin"
mkdir -p "${BIN}"
NPM_LOG="${SANDBOX}/npm-invocations.log"

make_npm_stub() {
  local exit_code="$1"
  cat >"${BIN}/npm" <<STUB
#!/usr/bin/env bash
{ echo "cwd=\$(pwd)"; echo "args=\$*"; } >>"${NPM_LOG}"
exit ${exit_code}
STUB
  chmod +x "${BIN}/npm"
}

new_root_with_pkg() {
  local root
  root="$(mktemp -d 2>/dev/null || echo "/tmp/iac-heal-root.$$.${RANDOM}")"
  mkdir -p "${root}/node_modules"
  printf '{"name":"iobroker.inst","dependencies":{"iobroker.js-controller":"7.2.2"}}\n' >"${root}/package.json"
  printf '%s' "${root}"
}

run_heal() {
  local root="$1"; shift
  : >"${NPM_LOG}"
  PATH="${BIN}:${PATH}" IOB_ROOT="${root}" IOB_HEAL_TIMEOUT=0 "$@" bash "${HEAL_SH}"
}

echo "=== heal-node-modules ==="

# --- Case 1: disabled -> skip, npm never called, exit 0. ---------------------
make_npm_stub 0
r1="$(new_root_with_pkg)"
if PATH="${BIN}:${PATH}" IOB_ROOT="${r1}" IOB_HEAL_NODE_MODULES=false IOB_HEAL_TIMEOUT=0 bash "${HEAL_SH}"; then rc=0; else rc=$?; fi
: >"${NPM_LOG}.chk"; [[ -s "${NPM_LOG}" ]] && cp "${NPM_LOG}" "${NPM_LOG}.chk"
if [[ "${rc}" -eq 0 ]] && [[ ! -s "${NPM_LOG}" ]]; then
  printf '  ok   disabled -> skipped, npm not called, exit 0\n'
else
  printf '  FAIL disabled: rc=%s npm-called=%s\n' "${rc}" "$([[ -s ${NPM_LOG} ]] && echo yes || echo no)" >&2
  fail="${fail} [disabled]"
fi
rm -rf -- "${r1}"

# --- Case 2: no package.json -> skip, npm never called, exit 0. --------------
make_npm_stub 0
r2="$(mktemp -d)"; mkdir -p "${r2}/node_modules"  # no package.json
: >"${NPM_LOG}"
if PATH="${BIN}:${PATH}" IOB_ROOT="${r2}" IOB_HEAL_TIMEOUT=0 bash "${HEAL_SH}"; then rc=0; else rc=$?; fi
if [[ "${rc}" -eq 0 ]] && [[ ! -s "${NPM_LOG}" ]]; then
  printf '  ok   no package.json -> skipped, npm not called, exit 0\n'
else
  printf '  FAIL no-package.json: rc=%s npm-called=%s\n' "${rc}" "$([[ -s ${NPM_LOG} ]] && echo yes || echo no)" >&2
  fail="${fail} [no-package.json]"
fi
rm -rf -- "${r2}"

# --- Case 3: enabled + npm ok -> runs `npm install` in IOB_ROOT, correct flags.
make_npm_stub 0
r3="$(new_root_with_pkg)"
: >"${NPM_LOG}"
if PATH="${BIN}:${PATH}" IOB_ROOT="${r3}" IOB_HEAL_TIMEOUT=0 bash "${HEAL_SH}"; then rc=0; else rc=$?; fi
inv="$(cat "${NPM_LOG}" 2>/dev/null)"
ok=1
[[ "${rc}" -eq 0 ]] || ok=0
grep -q "cwd=${r3}\$" "${NPM_LOG}" || ok=0
echo "${inv}" | grep -q 'args=install' || ok=0
echo "${inv}" | grep -q -- '--omit=dev' || ok=0
# must NOT prune/rewrite:
if echo "${inv}" | grep -qE -- '--production|--force'; then ok=0; fi
if [[ "${ok}" -eq 1 ]]; then
  printf '  ok   enabled -> npm install --omit=dev in IOB_ROOT, no prune flags\n'
else
  printf '  FAIL enabled invocation wrong: rc=%s inv=[%s]\n' "${rc}" "${inv//$'\n'/ | }" >&2
  fail="${fail} [enabled-invocation]"
fi
rm -rf -- "${r3}"

# --- Case 4: npm fails -> tolerated (script still exits 0). ------------------
make_npm_stub 7
r4="$(new_root_with_pkg)"
: >"${NPM_LOG}"
if PATH="${BIN}:${PATH}" IOB_ROOT="${r4}" IOB_HEAL_TIMEOUT=0 bash "${HEAL_SH}"; then rc=0; else rc=$?; fi
if [[ "${rc}" -eq 0 ]] && [[ -s "${NPM_LOG}" ]]; then
  printf '  ok   npm failure tolerated (script exit 0, npm was attempted)\n'
else
  printf '  FAIL npm-failure: rc=%s npm-called=%s\n' "${rc}" "$([[ -s ${NPM_LOG} ]] && echo yes || echo no)" >&2
  fail="${fail} [npm-failure-tolerated]"
fi
rm -rf -- "${r4}"

rm -rf -- "${SANDBOX}"

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} failures:${fail}" >&2
  echo "=== heal-node-modules FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} self-heal control flow correct"
echo "=== heal-node-modules PASSED ==="
exit 0
