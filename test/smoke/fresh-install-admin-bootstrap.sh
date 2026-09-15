# fresh-install-admin-bootstrap.sh - smoke test for the fresh-install `admin`
# bootstrap ACROSS the entrypoint's two reconcile passes (init -> install).
#
# WHY THIS TEST EXISTS
# --------------------
# On a brand-new container the Data_Volume is empty, so reconciliation must seed
# `admin` into the desired adapter set and install it (the setup UI). The
# entrypoint splits reconciliation into two passes around DB configuration:
#
#   pass 1  IOB_RECONCILE_PHASE=init     -> `iobroker setup first` (POPULATES the
#                                           Data_Volume)
#   pass 2  IOB_RECONCILE_PHASE=install  -> install-missing (installs admin)
#
# The bug this pins: the fresh-install signal used to be recomputed per pass with
# `data_volume_empty()`. The init pass fills the volume, so by the install pass
# the volume is no longer empty, the admin seed was dropped, desiredAdapters=0,
# and admin was NEVER installed on a fresh container (8081 never comes up). The
# fix bridges the two passes with a `.iob-fresh-install` marker written by the
# init pass and consumed (then cleared) by the install pass.
#
# This test drives the REAL scripts/reconcile.sh in dry-run mode across both
# passes against temp dirs, with tiny stub `iobroker`/`npm` binaries on PATH so
# it needs no container, no network and no real ioBroker. It asserts the install
# pass plans to install `admin` (proving the seed survived the split), and that a
# subsequent normal restart (non-fresh) does NOT re-seed admin.
#
# Exit codes:
#   0  the bootstrap survives the init->install split (and does not repeat)
#   1  regression (admin not installed on fresh start, or re-installed on restart)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
RECONCILE_SH="${REPO_ROOT}/scripts/reconcile.sh"

PASS_PREFIX="fresh-install-admin-bootstrap: PASS:"
FAIL_PREFIX="fresh-install-admin-bootstrap: FAIL:"

if [[ ! -r "${RECONCILE_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot read ${RECONCILE_SH}" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "${FAIL_PREFIX} node is required to run the planner; skipping" >&2
  # Treat missing node as a skip (exit 0) to match the other node-optional tests.
  exit 0
fi

WORK="$(mktemp -d 2>/dev/null || echo "/tmp/iac-fresh.$$")"
cleanup() { rm -rf -- "${WORK}" 2>/dev/null || true; }
trap cleanup EXIT

DATA_DIR="${WORK}/iobroker-data"
NM_DIR="${WORK}/node_modules"
LOG_DIR="${WORK}/log"
BIN_DIR="${WORK}/bin"
mkdir -p "${NM_DIR}" "${LOG_DIR}" "${BIN_DIR}"
# NOTE: DATA_DIR deliberately does NOT exist yet -> the init pass sees an empty
# Data_Volume, exactly like a brand-new container.

# --- Stub binaries -----------------------------------------------------------
# iobroker: `list instances` prints nothing (no recorded instances yet, like a
# fresh install); every other subcommand is a successful no-op. This makes
# desired_adapters()/enabled_instance_adapters() return empty, so ONLY the
# fresh-install admin seed can drive an install. NOTE: dry-run mode means the
# real script logs "[dry-run] iobroker ..." instead of calling this stub for the
# planned actions, so we do not need this stub to model `add`; it only backs the
# observation queries (list instances / object get).
cat >"${BIN_DIR}/iobroker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "list instances") exit 0 ;;
  "object get")     exit 0 ;;
esac
exit 0
EOF
# npm: `ping` succeeds so registry_reachable() reports online; anything else is
# a successful no-op.
cat >"${BIN_DIR}/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${BIN_DIR}/iobroker" "${BIN_DIR}/npm"

PATH="${BIN_DIR}:${PATH}"
export PATH

# run_phase <phase> : run reconcile.sh for one phase in dry-run mode, capturing
# its combined output. Dry-run makes install/rebuild actions log "[dry-run] ..."
# instead of executing, so we can assert the planned commands without side
# effects. Returns reconcile.sh's exit code; output is left in REPLY_OUT.
REPLY_OUT=""
run_phase() {
  local phase="$1" rc=0
  REPLY_OUT="$(
    IOB_DATA_DIR="${DATA_DIR}" \
    IOB_NODE_MODULES_DIR="${NM_DIR}" \
    IOB_LOG_DIR="${LOG_DIR}" \
    IOB_RECONCILE_DRY_RUN=true \
    IOB_RECONCILE_PHASE="${phase}" \
    IOB_HOSTNAME="testhost" \
    bash "${RECONCILE_SH}" 2>&1
  )" || rc=$?
  return "${rc}"
}

fail=""

# --- Pass 1: init (empty Data_Volume) ---------------------------------------
echo "=== pass 1: init (fresh empty Data_Volume) ==="
if run_phase init; then
  # The init pass runs `iobroker setup first` (dry-run) and must write the
  # fresh-install handoff marker so the install pass can still see the fresh
  # start after the volume is populated.
  if grep -q "init-default-config" <<<"${REPLY_OUT}"; then
    printf '  ok   init pass planned init-default-config\n'
  else
    printf '  FAIL init pass did not plan init-default-config\n' >&2
    fail="${fail} [init-no-default-config]"
  fi
  if [[ -f "${DATA_DIR}/.iob-fresh-install" ]]; then
    printf '  ok   init pass wrote the fresh-install handoff marker\n'
  else
    printf '  FAIL init pass did not write .iob-fresh-install marker\n' >&2
    fail="${fail} [init-no-marker]"
  fi
else
  printf '  FAIL init pass exited non-zero\n%s\n' "${REPLY_OUT}" >&2
  fail="${fail} [init-nonzero]"
fi

# Simulate what `iobroker setup first` does: populate the Data_Volume, so the
# install pass sees a NON-empty volume (the exact condition that used to drop
# the admin seed).
mkdir -p "${DATA_DIR}"
printf '{}\n' >"${DATA_DIR}/objects.jsonl"
printf '{}\n' >"${DATA_DIR}/states.jsonl"

# --- Pass 2: install (volume now populated) ---------------------------------
echo "=== pass 2: install (volume populated by init) ==="
if run_phase install; then
  # The seed must have survived the split: the install pass should plan to
  # install admin (dry-run logs the concrete `iobroker install ... admin` or
  # `iobroker url ...` command).
  if grep -Eq '\[dry-run\].*iobroker (install|url).*admin' <<<"${REPLY_OUT}"; then
    printf '  ok   install pass planned to install admin (seed survived split)\n'
  else
    printf '  FAIL install pass did NOT plan to install admin (regression)\n%s\n' "${REPLY_OUT}" >&2
    fail="${fail} [install-no-admin]"
  fi
  # Installing admin CODE is not enough: a fresh install must also CREATE the
  # admin.0 INSTANCE, or js-controller starts with nothing to run and the Admin
  # UI never comes up (the "container hangs after starting js-controller"
  # symptom). Assert the install pass planned `iobroker add admin 0 --enabled`.
  if grep -Eq '\[dry-run\].*iobroker add admin 0 --enabled' <<<"${REPLY_OUT}"; then
    printf '  ok   install pass planned to create the admin.0 instance\n'
  else
    printf '  FAIL install pass did NOT plan to create admin.0 (Admin UI would never start)\n%s\n' "${REPLY_OUT}" >&2
    fail="${fail} [install-no-admin-instance]"
  fi
  # desiredAdapters must be 1 (admin), not 0.
  if grep -q "desiredAdapters=1" <<<"${REPLY_OUT}"; then
    printf '  ok   install pass observed desiredAdapters=1\n'
  else
    printf '  FAIL install pass did not observe desiredAdapters=1\n' >&2
    fail="${fail} [install-desired-count]"
  fi
  # The marker must be consumed (cleared) by the install pass.
  if [[ ! -f "${DATA_DIR}/.iob-fresh-install" ]]; then
    printf '  ok   install pass cleared the fresh-install marker\n'
  else
    printf '  FAIL install pass left the fresh-install marker in place\n' >&2
    fail="${fail} [install-marker-not-cleared]"
  fi
else
  printf '  FAIL install pass exited non-zero\n%s\n' "${REPLY_OUT}" >&2
  fail="${fail} [install-nonzero]"
fi

# --- Pass 3: install on a normal restart (NOT fresh) ------------------------
# The volume is populated and the marker is gone, so this models a routine
# restart. Admin must NOT be re-seeded/re-installed (no recorded instances ->
# empty desired set).
echo "=== pass 3: install on a normal (non-fresh) restart ==="
if run_phase install; then
  if grep -Eq '\[dry-run\].*iobroker (install|url).*admin' <<<"${REPLY_OUT}"; then
    printf '  FAIL restart re-installed admin (marker not respected)\n%s\n' "${REPLY_OUT}" >&2
    fail="${fail} [restart-reinstalls-admin]"
  else
    printf '  ok   restart did not re-install admin\n'
  fi
  # A normal restart must NOT re-create the admin instance either (fresh_install
  # is false, so the instance bootstrap must not run).
  if grep -Eq '\[dry-run\].*iobroker add admin' <<<"${REPLY_OUT}"; then
    printf '  FAIL restart re-created the admin instance (bootstrap not gated)\n%s\n' "${REPLY_OUT}" >&2
    fail="${fail} [restart-recreates-instance]"
  else
    printf '  ok   restart did not re-create the admin instance\n'
  fi
  if grep -q "desiredAdapters=0" <<<"${REPLY_OUT}"; then
    printf '  ok   restart observed desiredAdapters=0\n'
  else
    printf '  FAIL restart did not observe desiredAdapters=0\n' >&2
    fail="${fail} [restart-desired-count]"
  fi
else
  printf '  FAIL restart install pass exited non-zero\n%s\n' "${REPLY_OUT}" >&2
  fail="${fail} [restart-nonzero]"
fi

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} failures:${fail}" >&2
  echo "=== fresh-install admin bootstrap FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} admin bootstrap survives the init->install split and does not repeat"
echo "=== fresh-install admin bootstrap PASSED ==="
exit 0
