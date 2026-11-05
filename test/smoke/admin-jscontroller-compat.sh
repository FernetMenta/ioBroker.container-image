# admin-jscontroller-compat.sh - smoke test for the fresh-install admin /
# js-controller COMPATIBILITY resolution in scripts/reconcile.sh.
#
# WHY THIS TEST EXISTS
# --------------------
# On a fresh container the newest STABLE admin can require a NEWER js-controller
# than the image ships (the real case: admin 8.3.5 requires js-controller
# >=7.2.5 while the image ships 7.2.2). Installing the unpinned newest admin
# then lands an admin incompatible with the baked-in controller. The fix: during
# the fresh-install admin bootstrap ONLY, resolve the NEWEST admin version
# COMPATIBLE with the installed controller and install THAT exact version via
# `iobroker url iobroker.admin@<ver>`. If NONE is compatible this is FATAL and
# the container is held unhealthy (block_unhealthy), never a clean exit.
#
# This drives the REAL scripts/reconcile.sh in NON-dry-run mode against temp
# dirs, with tiny stub `iobroker` / `npm` / `curl` binaries on PATH so it needs
# no container, no network and no real ioBroker. The stubs model:
#   * a baked-in js-controller version (node_modules package.json),
#   * `npm view iobroker.admin versions --json` (the candidate list),
#   * the GitHub raw io-package.json per tag via a stub `curl`,
#   * `iobroker url` / `iobroker install` as successful no-ops.
#
# Scenarios:
#   A. newest admin is INCOMPATIBLE -> resolver falls back to the newest
#      COMPATIBLE older version and installs `iobroker url iobroker.admin@<ver>`.
#   B. newest admin is already compatible -> installs the newest.
#   C. NOTHING compatible -> block_unhealthy (FATAL log, js-controller NOT
#      started, no clean exit) rather than installing an incompatible admin.
#
# Exit codes:
#   0  all scenarios behaved as specified
#   1  a regression in the compatibility resolution
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
RECONCILE_SH="${REPO_ROOT}/scripts/reconcile.sh"

PASS_PREFIX="admin-jscontroller-compat: PASS:"
FAIL_PREFIX="admin-jscontroller-compat: FAIL:"

if [[ ! -r "${RECONCILE_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot read ${RECONCILE_SH}" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "${FAIL_PREFIX} node is required; skipping" >&2
  exit 0
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "${FAIL_PREFIX} timeout(1) is required; skipping" >&2
  exit 0
fi

fail=""

# run_scenario <controller-version> <versions-json> <ranges-spec>
#   ranges-spec: newline list of "<ver>=<range>" entries the stub curl serves as
#   that tag's io-package.json common.dependencies. A version with no entry
#   serves a manifest with no js-controller requirement.
# Sets REPLY_OUT (combined output) and REPLY_RC (reconcile.sh exit code; 124 if
# it was held by block_unhealthy and killed by timeout).
REPLY_OUT=""
REPLY_RC=0
run_scenario() {
  local controller="$1" versions_json="$2" ranges_spec="$3"
  local WORK DATA_DIR NM_DIR LOG_DIR BIN_DIR
  WORK="$(mktemp -d)"
  DATA_DIR="${WORK}/iobroker-data"   # absent -> fresh install
  NM_DIR="${WORK}/node_modules"
  LOG_DIR="${WORK}/log"
  BIN_DIR="${WORK}/bin"
  mkdir -p "${NM_DIR}/iobroker.js-controller" "${LOG_DIR}" "${BIN_DIR}"
  printf '{"version":"%s"}\n' "${controller}" >"${NM_DIR}/iobroker.js-controller/package.json"

  # Stub iobroker: observation queries print nothing; url/install succeed.
  cat >"${BIN_DIR}/iobroker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "list instances") exit 0 ;;
  "object get")     exit 0 ;;
esac
exit 0
EOF

  # Stub npm: `view iobroker.admin versions --json` prints the candidate list;
  # `ping` succeeds (registry reachable); everything else is a no-op.
  cat >"${BIN_DIR}/npm" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "view iobroker.admin versions" ]]; then
  printf '%s\n' '${versions_json}'
  exit 0
fi
exit 0
EOF

  # Stub curl: serve a minimal io-package.json for the requested admin tag. The
  # URL ends in /v<ver>/io-package.json; map <ver> through the ranges spec.
  cat >"${BIN_DIR}/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do url="\$a"; done
ver="\$(printf '%s' "\$url" | sed -n 's#.*/v\\([0-9][0-9.]*\\)/io-package.json#\\1#p')"
[[ -n "\$ver" ]] || exit 22
range="\$(printf '%s\n' "${ranges_spec}" | sed -n "s/^\${ver}=//p")"
if [[ -n "\$range" ]]; then
  printf '{"common":{"dependencies":[{"js-controller":"%s"}]}}\n' "\$range"
else
  printf '{"common":{"dependencies":[]}}\n'
fi
exit 0
EOF
  chmod +x "${BIN_DIR}/iobroker" "${BIN_DIR}/npm" "${BIN_DIR}/curl"

  REPLY_RC=0
  REPLY_OUT="$(
    PATH="${BIN_DIR}:${PATH}" \
    IOB_DATA_DIR="${DATA_DIR}" \
    IOB_NODE_MODULES_DIR="${NM_DIR}" \
    IOB_LOG_DIR="${LOG_DIR}" \
    IOB_RECONCILE_DRY_RUN=false \
    IOB_RECONCILE_PHASE=install \
    IOB_HOSTNAME="testhost" \
    IOB_INSTALL_SETTLE=0 \
    timeout 30 bash "${RECONCILE_SH}" 2>&1
  )" || REPLY_RC=$?
  rm -rf -- "${WORK}" 2>/dev/null || true
}

# --- Scenario A: newest incompatible -> fall back to newest compatible -------
echo "=== scenario A: newest admin incompatible with controller 7.2.2 ==="
run_scenario "7.2.2" '["8.1.0","8.2.0","8.3.5"]' $'8.3.5=>=7.2.5\n8.2.0=>=7.0.0\n8.1.0=>=6.0.0'
# run_install does not echo the command in non-dry-run mode (it runs the stub
# silently), so assert on the resolver's own "installing compatibility-resolved
# version" log line and the summary action it records for the chosen version.
if grep -Eq 'installing compatibility-resolved version 8\.2\.0' <<<"${REPLY_OUT}" \
  && grep -Eq 'admin-compat: installed iobroker\.admin@8\.2\.0' <<<"${REPLY_OUT}"; then
  printf '  ok   resolved to the newest COMPATIBLE admin 8.2.0 (skipping 8.3.5)\n'
else
  printf '  FAIL did not install iobroker.admin@8.2.0\n%s\n' "${REPLY_OUT}" >&2
  fail="${fail} [A-wrong-version]"
fi
if grep -Eq 'installing compatibility-resolved version 8\.3\.5' <<<"${REPLY_OUT}"; then
  printf '  FAIL installed the INCOMPATIBLE admin 8.3.5\n' >&2
  fail="${fail} [A-installed-incompatible]"
fi

# --- Scenario B: newest already compatible -----------------------------------
echo "=== scenario B: newest admin already compatible with controller 7.5.0 ==="
run_scenario "7.5.0" '["8.2.0","8.3.5"]' $'8.3.5=>=7.2.5\n8.2.0=>=7.0.0'
if grep -Eq 'installing compatibility-resolved version 8\.3\.5' <<<"${REPLY_OUT}" \
  && grep -Eq 'admin-compat: installed iobroker\.admin@8\.3\.5' <<<"${REPLY_OUT}"; then
  printf '  ok   installed the newest compatible admin 8.3.5\n'
else
  printf '  FAIL did not install iobroker.admin@8.3.5\n%s\n' "${REPLY_OUT}" >&2
  fail="${fail} [B-wrong-version]"
fi

# --- Scenario C: nothing compatible -> block_unhealthy (FATAL) ---------------
echo "=== scenario C: NO compatible admin for controller 7.2.2 (fatal) ==="
run_scenario "7.2.2" '["8.3.4","8.3.5"]' $'8.3.5=>=7.2.5\n8.3.4=>=7.2.5'
if grep -q "no compatible iobroker.admin version found" <<<"${REPLY_OUT}"; then
  printf '  ok   logged the FATAL no-compatible-version message\n'
else
  printf '  FAIL did not log the fatal no-compatible-version message\n%s\n' "${REPLY_OUT}" >&2
  fail="${fail} [C-no-fatal-log]"
fi
if grep -q "not starting js-controller" <<<"${REPLY_OUT}"; then
  printf '  ok   held the container unhealthy (did not start js-controller)\n'
else
  printf '  FAIL did not block_unhealthy (js-controller not held back)\n' >&2
  fail="${fail} [C-not-blocked]"
fi
# block_unhealthy sleeps forever, so timeout(1) kills it with exit 124. A clean
# exit 0 here would mean we did NOT hold the container (regression).
if [[ "${REPLY_RC}" -eq 124 ]]; then
  printf '  ok   container was held (timeout killed the block_unhealthy sleep)\n'
else
  printf '  FAIL reconcile did not hold the container (rc=%s)\n' "${REPLY_RC}" >&2
  fail="${fail} [C-did-not-hold]"
fi
if grep -Eq 'installing compatibility-resolved version' <<<"${REPLY_OUT}"; then
  printf '  FAIL installed an admin version despite no compatible one\n' >&2
  fail="${fail} [C-installed-anyway]"
fi

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} failures:${fail}" >&2
  echo "=== admin-jscontroller-compat FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} compatibility resolution picks the newest compatible admin and blocks when none exists"
echo "=== admin-jscontroller-compat PASSED ==="
exit 0
