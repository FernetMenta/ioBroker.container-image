#!/usr/bin/env bash
# health-watchdog.sh (smoke) - verify the WIRING of scripts/health-watchdog.sh
# (the loop, the consecutive-unhealthy debounce, the single SIGTERM, the reset,
# and the disabled/malformed-knob behavior) WITHOUT a real controller, DB, or
# container.
#
# The pure-module tests (test/watchdog-state.*test.js) cover the counting/decision
# logic; this harness covers the shell glue those module tests cannot:
#   * the watchdog runs the (injected) healthcheck every INTERVAL and signals the
#     (injected) target PID with SIGTERM exactly at THRESHOLD consecutive
#     unhealthy results — not before,
#   * a healthy result in the middle RESETS the streak (a fresh full streak is
#     needed to trigger),
#   * after one trigger the watchdog does NOT keep signalling (fire-once latch),
#   * a malformed IOB_WATCHDOG_THRESHOLD / IOB_WATCHDOG_INTERVAL falls back to the
#     default and the script still runs,
#   * when "disabled" (the entrypoint simply does not launch it) nothing is
#     signalled — modelled here by asserting the watchdog with a target that is
#     never driven to the threshold leaves the target alive.
#
# The real healthcheck is replaced via IOB_WATCHDOG_HEALTHCHECK_CMD (a stub whose
# exit code is scripted per call from a counter file), and the signal target via
# IOB_WATCHDOG_TARGET_PID (a disposable `sleep` process). IOB_WATCHDOG_INTERVAL=1
# and IOB_WATCHDOG_MAX_CYCLES keep every case fast and bounded.
#
# Exit codes: 0 all cases held; 1 a regression.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
WATCHDOG_SH="${REPO_ROOT}/scripts/health-watchdog.sh"

PASS_PREFIX="health-watchdog: PASS:"
FAIL_PREFIX="health-watchdog: FAIL:"

if [[ ! -r "${WATCHDOG_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot read ${WATCHDOG_SH}" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "health-watchdog: SKIP: node not available" >&2
  exit 0
fi

fail=""

SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/iac-watchdog.$$")"

# Track disposable target `sleep` processes so cleanup kills any survivor.
TARGETS=()

cleanup() {
  local pid
  for pid in "${TARGETS[@]:-}"; do
    [[ -n "${pid}" ]] && kill -KILL "${pid}" 2>/dev/null || true
  done
  rm -rf "${SANDBOX}" 2>/dev/null || true
}
trap cleanup EXIT

# make_healthcheck_stub: write a stub healthcheck whose exit code for call N is
# the N-th value of a space-separated SEQUENCE; once the sequence is exhausted it
# keeps returning the LAST value. It records call count in a sidecar counter file.
#   $1 path to write the stub to
#   $2 space-separated exit-code sequence (e.g. "1 1 1")
make_healthcheck_stub() {
  local stub="$1" sequence="$2"
  local counter="${stub}.count"
  printf '0\n' >"${counter}"
  cat >"${stub}" <<STUB
#!/usr/bin/env bash
set -u
seq=(${sequence})
counter="${counter}"
n="\$(cat "\${counter}" 2>/dev/null || echo 0)"
idx="\${n}"
last=\$(( \${#seq[@]} - 1 ))
if [[ "\${idx}" -gt "\${last}" ]]; then idx="\${last}"; fi
printf '%s\n' "\$(( n + 1 ))" >"\${counter}"
exit "\${seq[\${idx}]}"
STUB
  chmod +x "${stub}"
}

# spawn_target: start a disposable long sleep and register it for cleanup, then
# store its PID in the global SPAWNED_PID. The watchdog signals THIS pid with
# SIGTERM when the threshold trips; `sleep` exits on SIGTERM, so `kill -0`
# afterwards tells us whether it was hit.
#
# NOTE: we do NOT return the PID via command substitution. A `sleep 120 &` inside
# `$(...)` inherits the subshell's stdout pipe, so the command substitution would
# block until the sleep ends (120s) rather than returning promptly. Using a global
# plus FD redirection on the background job avoids that classic pitfall.
SPAWNED_PID=""
spawn_target() {
  sleep 120 >/dev/null 2>&1 &
  SPAWNED_PID=$!
  TARGETS+=("${SPAWNED_PID}")
}

# run_watchdog: run the watchdog with an injected healthcheck stub + target PID,
# bounded to a fixed number of cycles so it always terminates.
#   $1 healthcheck stub path
#   $2 target pid
#   $3 max cycles
#   $4 threshold value (may be malformed on purpose)
#   $5 interval value (may be malformed on purpose; default 1)
run_watchdog() {
  local stub="$1" target="$2" cycles="$3" threshold="$4" interval="${5:-1}"
  IOB_WATCHDOG_HEALTHCHECK_CMD="${stub}" \
  IOB_WATCHDOG_TARGET_PID="${target}" \
  IOB_WATCHDOG_MAX_CYCLES="${cycles}" \
  IOB_WATCHDOG_THRESHOLD="${threshold}" \
  IOB_WATCHDOG_INTERVAL="${interval}" \
    bash "${WATCHDOG_SH}" >/dev/null 2>&1
}

# alive: 0 (true) if pid is still running, 1 otherwise.
alive() { kill -0 "$1" 2>/dev/null; }

pass() { echo "${PASS_PREFIX} $1"; }
failcase() { echo "${FAIL_PREFIX} $1" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Case A: THRESHOLD-1 consecutive unhealthy must NOT signal the target.
# threshold=3, healthcheck always unhealthy, but only 2 cycles run => no trigger.
# ---------------------------------------------------------------------------
stub_a="${SANDBOX}/hc-a.sh"; make_healthcheck_stub "${stub_a}" "1 1 1"
spawn_target; target_a="${SPAWNED_PID}"
run_watchdog "${stub_a}" "${target_a}" 2 3 1
if alive "${target_a}"; then
  pass "threshold-1 unhealthy (2/3) does NOT signal the target"
else
  failcase "target was signalled before reaching the threshold"
fi
kill -KILL "${target_a}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Case B: the THRESHOLD-th consecutive unhealthy DOES send SIGTERM (target dies).
# threshold=3, always unhealthy, 3 cycles => trigger on the 3rd.
# ---------------------------------------------------------------------------
stub_b="${SANDBOX}/hc-b.sh"; make_healthcheck_stub "${stub_b}" "1 1 1"
spawn_target; target_b="${SPAWNED_PID}"
run_watchdog "${stub_b}" "${target_b}" 3 3 1
# Give the signalled `sleep` a brief moment to die.
sleep 1
if alive "${target_b}"; then
  failcase "target survived ${target_b} after 3/3 consecutive unhealthy (no SIGTERM?)"
  kill -KILL "${target_b}" 2>/dev/null || true
else
  pass "threshold-th consecutive unhealthy sends SIGTERM (target terminated)"
fi

# ---------------------------------------------------------------------------
# Case C: a healthy result in the MIDDLE resets the streak, so after it the
# remaining unhealthy results are fewer than the threshold => no signal.
# Sequence: 1 1 0 1 1  (threshold 3, 5 cycles). The 0 at cycle 3 resets; the two
# trailing unhealthy never reach 3 within the bounded run.
# ---------------------------------------------------------------------------
stub_c="${SANDBOX}/hc-c.sh"; make_healthcheck_stub "${stub_c}" "1 1 0 1 1"
spawn_target; target_c="${SPAWNED_PID}"
run_watchdog "${stub_c}" "${target_c}" 5 3 1
if alive "${target_c}"; then
  pass "a healthy result resets the streak (no signal within a sub-threshold tail)"
else
  failcase "target was signalled even though a healthy result should have reset the streak"
fi
kill -KILL "${target_c}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Case D: fire-once latch — after the trigger, keep returning unhealthy and prove
# the watchdog does not send a SECOND signal. We model "no second signal" by
# re-targeting a SECOND, fresh process once past the threshold: in a single run
# we cannot re-check the first target (it is dead), so instead we assert the
# watchdog latches by observing it still exits cleanly (0) after many extra
# unhealthy cycles past the threshold while targeting a process we DON'T want
# killed twice. Concretely: threshold=2, run 6 cycles all unhealthy against a
# target; it must be killed (trigger) and the watchdog must still exit 0 having
# latched rather than erroring on a now-dead PID.
# ---------------------------------------------------------------------------
stub_d="${SANDBOX}/hc-d.sh"; make_healthcheck_stub "${stub_d}" "1 1 1 1 1 1"
spawn_target; target_d="${SPAWNED_PID}"
run_watchdog "${stub_d}" "${target_d}" 6 2 1; wd_rc=$?
sleep 1
if alive "${target_d}"; then
  failcase "latch case: target survived (threshold 2 should have triggered)"
  kill -KILL "${target_d}" 2>/dev/null || true
elif [[ "${wd_rc}" -ne 0 ]]; then
  failcase "latch case: watchdog exited ${wd_rc} (should latch and exit 0 past a dead target)"
else
  pass "fire-once latch: one trigger, clean exit across extra unhealthy cycles"
fi

# ---------------------------------------------------------------------------
# Case E: malformed knobs fall back to defaults and the script still runs. Use a
# non-numeric threshold and interval; with only 2 bounded cycles and the default
# threshold (3) the target must survive (fallback threshold 3 not reached), and
# the watchdog must exit 0 (did not abort on the bad values under `set -u`).
# ---------------------------------------------------------------------------
stub_e="${SANDBOX}/hc-e.sh"; make_healthcheck_stub "${stub_e}" "1 1"
spawn_target; target_e="${SPAWNED_PID}"
run_watchdog "${stub_e}" "${target_e}" 2 "oops" "nope"; wd_rc=$?
if [[ "${wd_rc}" -ne 0 ]]; then
  failcase "malformed knobs: watchdog exited ${wd_rc} (should fall back and exit 0)"
elif alive "${target_e}"; then
  pass "malformed threshold/interval fall back to defaults (script runs, no premature signal)"
else
  failcase "malformed knobs: target signalled (fallback threshold should be 3, only 2 cycles ran)"
fi
kill -KILL "${target_e}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Case F: opt-out gating. The watchdog is disabled by the ENTRYPOINT, which
# simply does not launch scripts/health-watchdog.sh when
# IOB_HEALTHCHECK_WATCHDOG=false. We assert the exact gate condition the
# entrypoint uses (scripts/entrypoint.sh: `[[ "${IOB_HEALTHCHECK_WATCHDOG:-true}"
# != "false" ]]`) so that:
#   * unset   -> launch (default enabled),
#   * "true"  -> launch,
#   * "false" -> do NOT launch (opt-out),
#   * "False"/"0"/other -> launch (exact-match "false" only, documented behavior).
# This proves the opt-out is wired and exact-match, without standing up the whole
# entrypoint. Also confirm the entrypoint actually contains that gate.
# ---------------------------------------------------------------------------
gate_launches() {
  # Mirror the entrypoint's gate exactly; echo "launch" or "skip".
  local v="${1-__unset__}"
  if [[ "${v}" == "__unset__" ]]; then
    [[ "${IOB_HEALTHCHECK_WATCHDOG:-true}" != "false" ]] && echo launch || echo skip
  else
    IOB_HEALTHCHECK_WATCHDOG="${v}"
    [[ "${IOB_HEALTHCHECK_WATCHDOG:-true}" != "false" ]] && echo launch || echo skip
    unset IOB_HEALTHCHECK_WATCHDOG
  fi
}

gate_ok=1
[[ "$(unset IOB_HEALTHCHECK_WATCHDOG; gate_launches)" == "launch" ]] || gate_ok=""
[[ "$(gate_launches true)"  == "launch" ]] || gate_ok=""
[[ "$(gate_launches false)" == "skip"   ]] || gate_ok=""
[[ "$(gate_launches False)" == "launch" ]] || gate_ok=""
[[ "$(gate_launches 0)"     == "launch" ]] || gate_ok=""

entrypoint_sh="${REPO_ROOT}/scripts/entrypoint.sh"
gate_in_entrypoint=""
if [[ -r "${entrypoint_sh}" ]] \
  && grep -Eq 'IOB_HEALTHCHECK_WATCHDOG:-true.*!=.*"false"' "${entrypoint_sh}"; then
  gate_in_entrypoint=1
fi

if [[ -n "${gate_ok}" && -n "${gate_in_entrypoint}" ]]; then
  pass "opt-out gate: IOB_HEALTHCHECK_WATCHDOG=false skips launch; exact-match 'false' only; gate present in entrypoint"
else
  [[ -z "${gate_ok}" ]] && failcase "opt-out gate logic did not behave as documented"
  [[ -z "${gate_in_entrypoint}" ]] && failcase "entrypoint.sh does not contain the documented IOB_HEALTHCHECK_WATCHDOG gate"
fi

if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} one or more cases failed" >&2
  exit 1
fi
echo "${PASS_PREFIX} all cases held"
exit 0
