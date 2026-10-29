#!/usr/bin/env bash
# healthcheck-messagebox-probe.sh (smoke) - verify the messagebox self-probe
# WIRING in scripts/healthcheck.sh WITHOUT a real DB, controller, or container.
#
# The pure-module tests (test/health-state.messagebox-probe*.test.js) cover the
# decision logic; this harness covers the shell glue the module tests cannot:
#   * the probe is SKIPPED when IOB_MESSAGEBOX_PROBE=false (status-only; exit
#     mirrors the status command),
#   * status ok + probe prints `outcome=failed` + OUTSIDE the grace window => the
#     container is flagged unhealthy (exit 1),
#   * status ok + probe prints `outcome=inconclusive` => NOT a failure (exit 0),
#   * the probe is NOT run INSIDE the startup grace window even when it would
#     report failed (exit 0),
#   * status ok + probe prints `outcome=ok` => healthy (exit 0).
#
# The real DB-touching probe is replaced via MESSAGEBOX_PROBE_MODULE, and the
# status command via IOB_STATUS_CMD, so nothing external is needed.
#
# Exit codes: 0 all cases held; 1 a regression.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
HEALTHCHECK_SH="${REPO_ROOT}/scripts/healthcheck.sh"

PASS_PREFIX="healthcheck-messagebox-probe: PASS:"
FAIL_PREFIX="healthcheck-messagebox-probe: FAIL:"

if [[ ! -r "${HEALTHCHECK_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot read ${HEALTHCHECK_SH}" >&2
  exit 1
fi

fail=""

SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/iac-hc-probe.$$")"
DATA_DIR="${SANDBOX}/iobroker-data"
mkdir -p "${DATA_DIR}"
START_MARKER="${DATA_DIR}/.iob-started"

# A stub probe module: a tiny node script that prints a chosen outcome line after
# an optional delay, then exits 0 — exactly like lib/messagebox-probe.js's CLI
# contract. The delay lets a case exercise the OUTER `timeout` backstop against a
# probe that does not answer instantly (the real module waits out its own deadline
# before emitting `outcome=failed`).
#   $1 outcome to print
#   $2 optional delay in seconds before printing (default 0)
make_probe_stub() {
  local outcome="$1" delay="${2:-0}"
  cat >"${SANDBOX}/stub-probe.mjs" <<STUB
const delayMs = ${delay} * 1000;
setTimeout(() => {
  process.stdout.write('messagebox-probe: outcome=${outcome}\n');
}, delayMs);
STUB
  printf '%s' "${SANDBOX}/stub-probe.mjs"
}

# Run healthcheck.sh with a given set of facts. Returns its exit code.
#   $1 outcome for the stub probe (or empty => point at a nonexistent module)
#   $2 marker age in seconds (controls startup_elapsed vs grace window)
#   $3 IOB_MESSAGEBOX_PROBE value (true/false)
#   $4 IOB_STATUS_CMD (default "true")
#   $5 optional probe inner timeout (IOB_MESSAGEBOX_PROBE_TIMEOUT), default 5
#   $6 optional stub delay in seconds before the stub prints its outcome
run_hc() {
  local outcome="$1" marker_age="$2" probe_enabled="$3" status_cmd="${4:-true}"
  local probe_timeout="${5:-5}" stub_delay="${6:-0}"
  local probe_module
  if [[ -n "${outcome}" ]]; then
    probe_module="$(make_probe_stub "${outcome}" "${stub_delay}")"
  else
    probe_module="${SANDBOX}/does-not-exist.mjs"
  fi

  # Place the start marker so startup_elapsed_seconds = marker_age.
  local now; now="$(date +%s)"
  touch -d "@$(( now - marker_age ))" "${START_MARKER}" 2>/dev/null \
    || touch -t "$(date -d "@$(( now - marker_age ))" +%Y%m%d%H%M.%S 2>/dev/null)" "${START_MARKER}" 2>/dev/null \
    || :

  IOB_ROOT="${SANDBOX}" \
  IOB_DATA_DIR="${DATA_DIR}" \
  IOB_START_MARKER="${START_MARKER}" \
  IOB_STARTUP_GRACE_PERIOD=300 \
  IOB_STATUS_CMD="${status_cmd}" \
  IOB_MESSAGEBOX_PROBE="${probe_enabled}" \
  IOB_MESSAGEBOX_PROBE_TIMEOUT="${probe_timeout}" \
  MESSAGEBOX_PROBE_MODULE="${probe_module}" \
    bash "${HEALTHCHECK_SH}" >/dev/null 2>&1
  return $?
}

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "${PASS_PREFIX} ${desc} (exit ${actual})"
  else
    echo "${FAIL_PREFIX} ${desc} (expected exit ${expected}, got ${actual})" >&2
    fail=1
  fi
}

# Case A: probe disabled => status-only. Status ok (true) => exit 0.
run_hc "failed" 3600 "false" "true"; check "probe disabled + status ok => healthy" 0 $?

# Case A2: probe disabled + status FAILS outside windows => unhealthy (status-only).
run_hc "ok" 3600 "false" "false"; check "probe disabled + status failed (outside grace) => unhealthy" 1 $?

# Case B: status ok + probe failed + outside grace => unhealthy.
run_hc "failed" 3600 "true" "true"; check "status ok + probe failed + outside grace => unhealthy" 1 $?

# Case C: status ok + probe inconclusive => not a failure => healthy.
run_hc "inconclusive" 3600 "true" "true"; check "status ok + probe inconclusive => healthy" 0 $?

# Case D: status ok + probe WOULD report failed, but INSIDE grace => probe not
# run => healthy.
run_hc "failed" 10 "true" "true"; check "status ok + inside grace (probe skipped) => healthy" 0 $?

# Case E: status ok + probe ok => healthy.
run_hc "ok" 3600 "true" "true"; check "status ok + probe ok => healthy" 0 $?

# Case F: status ok + probe module missing/crashes => inconclusive => healthy.
run_hc "" 3600 "true" "true"; check "status ok + probe module missing => healthy" 0 $?

# Case H (whole-healthcheck budget, review finding #2): a SLOW successful status
# command plus a probe that would hang must not push the WHOLE script past Docker's
# single --timeout. With a tiny Docker timeout (6s) and a status command that
# succeeds after ~2s, the remaining budget is too small to run even a minimal probe,
# so the script SKIPS the probe (status-only) and exits 0 WELL BEFORE the Docker
# boundary — never restarting the container for a slow-DB/setup hang. We also assert
# the whole invocation completes quickly (it must not wait out a full probe backstop).
# The stub would print `outcome=failed` after a long delay; if the budget logic were
# missing, the script would either hang toward the boundary or (worse) the probe
# would run and could flip to unhealthy. The budget skip keeps it status-only => 0.
run_hc_budget() {
  local now; now="$(date +%s)"
  touch -d "@$(( now - 3600 ))" "${START_MARKER}" 2>/dev/null \
    || touch -t "$(date -d "@$(( now - 3600 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "${START_MARKER}" 2>/dev/null \
    || :
  # A probe stub that would answer `failed` only after a long delay (never reached
  # because the budget skips the probe). Status command sleeps 2s then succeeds.
  local probe_module; probe_module="$(make_probe_stub "failed" 20)"
  IOB_ROOT="${SANDBOX}" \
  IOB_DATA_DIR="${DATA_DIR}" \
  IOB_START_MARKER="${START_MARKER}" \
  IOB_STARTUP_GRACE_PERIOD=300 \
  IOB_STATUS_CMD="sleep 2" \
  IOB_CHECK_TIMEOUT=5 \
  IOB_HC_DOCKER_TIMEOUT=6 \
  IOB_MESSAGEBOX_PROBE=true \
  IOB_MESSAGEBOX_PROBE_TIMEOUT=5 \
  MESSAGEBOX_PROBE_MODULE="${probe_module}" \
    bash "${HEALTHCHECK_SH}" >/dev/null 2>&1
  return $?
}

budget_start="$(date +%s)"
run_hc_budget; budget_rc=$?
budget_elapsed=$(( $(date +%s) - budget_start ))
check "slow status + tiny Docker budget => probe skipped => healthy" 0 "${budget_rc}"
if [[ "${budget_elapsed}" -lt 6 ]]; then
  echo "${PASS_PREFIX} budget case completed before Docker boundary (${budget_elapsed}s < 6s)"
else
  echo "${FAIL_PREFIX} budget case took ${budget_elapsed}s (>= Docker 6s boundary)" >&2
  fail=1
fi

# Case G (timing/backstop): the outer `timeout` must have HEADROOM over the inner
# probe budget so a real probe that waits out its own deadline before emitting
# `outcome=failed` is NOT preempted by the hard kill. With inner timeout 2s the
# script's backstop is 2+10=12s; a stub that only prints after 3s (past the inner
# budget, well under the backstop) must still deliver `failed` => unhealthy. If the
# outer `timeout` equalled the inner budget (the fixed blocking bug) this would be
# killed before printing and wrongly map to inconclusive => exit 0.
run_hc "failed" 3600 "true" "true" 2 3; check "status ok + delayed probe failed (inside backstop) => unhealthy" 1 $?

rm -rf "${SANDBOX}" 2>/dev/null || :

if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} one or more cases failed" >&2
  exit 1
fi
echo "${PASS_PREFIX} all cases held"
exit 0
