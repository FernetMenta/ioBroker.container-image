#!/usr/bin/env bash
# healthcheck.sh - upgrade-tolerant healthcheck usable by both Docker-style
# HEALTHCHECK and Kubernetes liveness/readiness probes (design §6; Req 9).
#
# A single script (Req 9.6, 9.7) that:
#   1. runs the Js_Controller status command (`iobroker status`) with a 30s
#      per-check timeout, treating the controller as up ONLY on exit 0 within
#      that timeout; a non-zero exit OR a timeout is a failed check
#      (Req 9.1, 9.2),
#   2. gathers the facts a decision needs — how long the runtime has been up,
#      the tolerance-window sizes, and whether a reconcile is in progress
#      together with its heartbeat age — and
#   3. hands those facts to the pure decision module `lib/health-state.js`
#      (computeHealthState) and exits with the exit code it returns: 0 for
#      healthy/starting, 1 for unhealthy (Req 9.5, 9.10).
#
# NOTE on the Upgrade_Tolerance_Window (Req 9.4/9.9): the pure module still
# supports an independent upgrade-tolerance window and the operator knob
# `IOB_UPGRADE_TOLERANCE_WINDOW` remains available, but this script does NOT try
# to detect an in-progress upgrade. In this image, js-controller/adapter upgrades
# are quick and do not restart the whole container long enough to matter, and the
# genuinely slow phase (first-boot / post-upgrade reconciliation) is covered by
# the reconcile-liveness heartbeat below rather than a fixed window. The upgrade
# window is therefore left dormant (upgradeInProgress is always reported false)
# unless a future component supplies the fact; the knob is retained so operators
# can still widen tolerance if their environment needs it.
#
# All decision logic (the two independent tolerance windows, the healthy /
# starting / unhealthy mapping) lives in the pure module so it can be
# property-tested without a container. This script owns only the thin,
# side-effecting parts: running the status command under a timeout, reading the
# environment, inspecting the filesystem / process table for markers, and
# mapping the result to a process exit code. This mirrors the observe -> plan
# -> act pattern of `scripts/ensure-npmrc.sh` and `scripts/reconcile.sh`.
#
# The two tolerance windows are INDEPENDENT: being inside either one alone
# prevents an unhealthy report (Req 9.11). The module enforces that; this script
# only supplies the facts.
#
# Usage:
#   healthcheck.sh
#
# Environment (Req 9.8, 9.9; design §10 env table):
#   IOB_STARTUP_GRACE_PERIOD      Startup_Grace_Period in seconds  (default 300)
#   IOB_UPGRADE_TOLERANCE_WINDOW  Upgrade_Tolerance_Window seconds (default 600)
#   IOB_RECONCILE_STALL_TOLERANCE Reconcile_Stall_Tolerance seconds (default 120):
#                                 max the reconcile heartbeat may go stale before
#                                 a live reconcile is no longer assumed. This
#                                 bounds STALL, not total reconcile duration.
#
# Environment overrides (primarily for testing / non-default layouts):
#   IOB_ROOT              ioBroker install root (default /opt/iobroker)
#   IOB_START_MARKER      path to the runtime start marker written by the
#                         entrypoint (default $IOB_ROOT/iobroker-data/.iob-started)
#   IOB_RECONCILE_MARKER  path to the reconcile-in-progress marker written by
#                         scripts/reconcile.sh (default
#                         $IOB_ROOT/iobroker-data/.iob-reconciling)
#   IOB_RECONCILE_HEARTBEAT path to the reconcile liveness heartbeat advanced by
#                         scripts/reconcile.sh (default
#                         $IOB_ROOT/iobroker-data/.iob-reconcile-heartbeat)
#   IOB_STATUS_CMD        the status command to run (default "iobroker status");
#                         word-split, so it may include arguments
#   IOB_CHECK_TIMEOUT     per-check timeout in seconds (default 30; Req 9.1)
#
# Messagebox self-probe (ioBroker issue #3524; opt-out + tuning):
#   IOB_MESSAGEBOX_PROBE  enable the active messagebox round-trip self-probe
#                         (true/false, default true). When false the healthcheck
#                         behaves EXACTLY as before (status-only). The probe runs
#                         ONLY after a successful status check and ONLY outside the
#                         startup-grace / reconcile windows; it detects a host whose
#                         inbound messagebox subscription died silently after a DB
#                         reconnect while `iobroker status` still reports healthy.
#   IOB_MESSAGEBOX_PROBE_TIMEOUT  probe round-trip timeout in seconds (default 5).
#
# Exit codes (Req 9.5, 9.10):
#   0  healthy or starting (a tolerated failure inside a window must NOT kill the
#      container; Docker treats any non-zero healthcheck exit as unhealthy)
#   1  unhealthy (check failed outside both tolerance windows)
set -euo pipefail

# --- Locate ourselves and the sibling lib/ module ---------------------------
# Resolve this script's directory so we can find lib/ regardless of the working
# directory Docker/k8s launches us from (same approach as reconcile.sh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
HEALTH_MODULE="${REPO_ROOT}/lib/health-state.js"

IOB_ROOT="${IOB_ROOT:-/opt/iobroker}"
IOB_DATA_DIR="${IOB_DATA_DIR:-${IOB_ROOT}/iobroker-data}"
IOB_START_MARKER="${IOB_START_MARKER:-${IOB_DATA_DIR}/.iob-started}"
IOB_RECONCILE_MARKER="${IOB_RECONCILE_MARKER:-${IOB_DATA_DIR}/.iob-reconciling}"
IOB_RECONCILE_HEARTBEAT="${IOB_RECONCILE_HEARTBEAT:-${IOB_DATA_DIR}/.iob-reconcile-heartbeat}"
IOB_STATUS_CMD="${IOB_STATUS_CMD:-iobroker status}"
IOB_CHECK_TIMEOUT="${IOB_CHECK_TIMEOUT:-30}"

# Messagebox self-probe knobs (issue #3524). Enabled by default; disabling reverts
# to status-only behavior. The probe module path is overridable for the wiring
# harness (test/smoke) so a stub can stand in for the real DB-touching probe.
IOB_MESSAGEBOX_PROBE="${IOB_MESSAGEBOX_PROBE:-true}"
IOB_MESSAGEBOX_PROBE_TIMEOUT="${IOB_MESSAGEBOX_PROBE_TIMEOUT:-5}"
MESSAGEBOX_PROBE_MODULE="${MESSAGEBOX_PROBE_MODULE:-${REPO_ROOT}/lib/messagebox-probe.js}"

# Window sizes come straight from the environment with the documented defaults.
# Out-of-range/malformed values are handled defensively by the pure module
# (a non-finite window is treated as "not inside"), so we do not re-validate
# here; the entrypoint owns range validation of operator config.
STARTUP_GRACE_PERIOD="${IOB_STARTUP_GRACE_PERIOD:-300}"
UPGRADE_TOLERANCE_WINDOW="${IOB_UPGRADE_TOLERANCE_WINDOW:-600}"
RECONCILE_STALL_TOLERANCE="${IOB_RECONCILE_STALL_TOLERANCE:-120}"

# Wall-clock at script entry. Used to budget the messagebox probe against the
# time ALREADY spent in this invocation (status command + fact gathering), so the
# probe can never push the WHOLE healthcheck past Docker's single --timeout bound
# (review finding #2: Docker applies one 30s limit to the entire script, not
# separate limits to the status check and the probe).
HEALTHCHECK_START="$(date +%s)"

# Docker's HEALTHCHECK --timeout for this image (Dockerfile). Kept in sync with the
# Dockerfile directive; the probe budget below is derived from it so a slow status
# command plus the probe never reach this outer bound. Overridable for tests.
IOB_HC_DOCKER_TIMEOUT="${IOB_HC_DOCKER_TIMEOUT:-30}"
# Safety margin (seconds) reserved below the Docker timeout for the final decision
# node call and process teardown, so the probe's own hard stop lands comfortably
# inside the outer bound.
IOB_HC_PROBE_SAFETY_MARGIN="${IOB_HC_PROBE_SAFETY_MARGIN:-3}"

log() { echo "healthcheck: $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Run the Js_Controller status command with a 30s per-check timeout.
#
# Success is exit 0 within the timeout. `timeout` exits 124 when the command
# exceeds the deadline, and forwards the command's own exit code otherwise; any
# non-zero value (including 124) is a failed check (Req 9.1, 9.2). We never let
# a failed status command abort the script itself (set -e), so the failure is
# captured as a fact and handed to the decision module.
# ---------------------------------------------------------------------------
check_succeeded=false
# Word-split IOB_STATUS_CMD intentionally so operators/tests can pass arguments.
# shellcheck disable=SC2206
status_cmd=(${IOB_STATUS_CMD})
if timeout "${IOB_CHECK_TIMEOUT}" "${status_cmd[@]}" >/dev/null 2>&1; then
  check_succeeded=true
else
  status_rc=$?
  if [[ "${status_rc}" -eq 124 ]]; then
    log "status command timed out after ${IOB_CHECK_TIMEOUT}s -> check failed"
  else
    log "status command returned exit ${status_rc} -> check failed"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Determine how long the runtime has been up (startup elapsed seconds).
#
# Preference order:
#   a. a start marker file written by the entrypoint — elapsed is now minus its
#      modification time (most accurate for "since this runtime started"),
#   b. the js-controller process start time from /proc (elapsed since the
#      controller process began),
#   c. this container's own uptime via PID 1 start time (fallback).
# If none is available we report 0, which keeps us conservatively inside the
# startup grace window (failures tolerated) rather than prematurely unhealthy.
# ---------------------------------------------------------------------------
now="$(date +%s)"

startup_elapsed_seconds=0
if [[ -f "${IOB_START_MARKER}" ]]; then
  marker_mtime="$(stat -c '%Y' -- "${IOB_START_MARKER}" 2>/dev/null || echo "")"
  if [[ -n "${marker_mtime}" ]]; then
    startup_elapsed_seconds=$(( now - marker_mtime ))
    log "elapsed-since-start from marker ${IOB_START_MARKER}: ${startup_elapsed_seconds}s"
  fi
elif proc_start="$(stat -c '%Y' -- /proc/1 2>/dev/null)" && [[ -n "${proc_start}" ]]; then
  # Fall back to PID 1's start time as the container/runtime start.
  startup_elapsed_seconds=$(( now - proc_start ))
  log "elapsed-since-start from PID 1 start time: ${startup_elapsed_seconds}s"
fi
# Guard against a clock skew producing a negative elapsed value; the module
# treats negatives as "not inside a window", but 0 is the safer intent here.
if [[ "${startup_elapsed_seconds}" -lt 0 ]]; then
  startup_elapsed_seconds=0
fi

# ---------------------------------------------------------------------------
# 3. Upgrade-in-progress: not detected in this image (dormant window).
#
# The pure module keeps an independent Upgrade_Tolerance_Window and the operator
# knob `IOB_UPGRADE_TOLERANCE_WINDOW` is retained, but this script does not probe
# for an in-progress upgrade: js-controller/adapter upgrades here are quick, and
# the slow first-boot / post-upgrade phase is covered by the reconcile-liveness
# heartbeat (step 3b), not a fixed window. So we always report upgradeInProgress
# = false, which — since the window only applies while an upgrade is in progress
# — leaves the upgrade window inert without changing the module's contract. If a
# future component learns to signal an in-progress upgrade, set these two facts.
# ---------------------------------------------------------------------------
upgrade_in_progress=false
upgrade_elapsed_seconds=0

# ---------------------------------------------------------------------------
# 3b. Detect reconcile-in-progress and, when in progress, its heartbeat age.
#
# The entrypoint runs reconciliation BEFORE js-controller starts, so the status
# command fails for that whole phase. Unlike startup/upgrade, reconcile has no
# meaningful upper time bound (slow link / slow SD card / many adapters), so we
# do NOT gate it on an elapsed-since-start window. Instead reconcile.sh publishes
# a marker (in progress) and a heartbeat it advances around every step; we report
# the heartbeat AGE and let the pure module tolerate failures only while that age
# stays under the stall tolerance. A live reconcile is thus tolerated for any
# duration; a stalled one (stale heartbeat) is not.
# ---------------------------------------------------------------------------
reconcile_in_progress=false
reconcile_heartbeat_age_seconds=0

if [[ -f "${IOB_RECONCILE_MARKER}" ]]; then
  reconcile_in_progress=true
  hb_mtime="$(stat -c '%Y' -- "${IOB_RECONCILE_HEARTBEAT}" 2>/dev/null || echo "")"
  if [[ -n "${hb_mtime}" ]]; then
    reconcile_heartbeat_age_seconds=$(( now - hb_mtime ))
    if [[ "${reconcile_heartbeat_age_seconds}" -lt 0 ]]; then
      reconcile_heartbeat_age_seconds=0
    fi
    log "reconcile in progress (${IOB_RECONCILE_MARKER}); heartbeat age ${reconcile_heartbeat_age_seconds}s"
  else
    # Marker present but no readable heartbeat: treat as maximally stale so we do
    # not tolerate indefinitely on a missing heartbeat. A value past any sane
    # stall tolerance makes the module fall through to the other conditions.
    reconcile_heartbeat_age_seconds=$(( RECONCILE_STALL_TOLERANCE + 1 ))
    log "reconcile marker present but heartbeat unreadable; treating heartbeat as stale"
  fi
fi

# ---------------------------------------------------------------------------
# 3c. Active messagebox self-probe (issue #3524).
#
# The existing status check stays green when a multihost slave's inbound message
# channel (messagebox.system.host.<name>) dies silently after a states/objects DB
# reconnect. This block actively verifies the host can still RECEIVE and ANSWER a
# host message (a getVersion round-trip) and, when it positively cannot, feeds a
# messagebox FAILED fact to the decision module so the container is flagged
# unhealthy (the quadlet then restarts it, which re-subscribes and recovers).
#
# Guard rails (avoid false positives / restart loops): the probe runs ONLY when
#   - IOB_MESSAGEBOX_PROBE is enabled (default true), AND
#   - the status check SUCCEEDED (a failed status is already handled above), AND
#   - we are OUTSIDE the startup grace window, AND
#   - no reconcile is in progress.
# Those are exactly the windows where a transient messagebox absence is expected,
# so we deliberately do not probe during boot/reconcile.
#
# The UPGRADE tolerance window is deliberately NOT re-checked here. This image
# never signals an in-progress upgrade (upgrade_in_progress is always false, see
# step 3; the window is dormant), so gating the probe on it in the shell would be
# a no-op. More importantly, the "three tolerance windows apply to the probe
# failure too" guarantee is enforced AUTHORITATIVELY in the pure decision module:
# computeHealthState suppresses a probe failure inside ANY of the three windows
# (startup grace, upgrade tolerance, live reconcile). So even if a future change
# starts signalling an in-progress upgrade, a probe failure during it is already
# tolerated at the decision layer — this bash gate is a performance/short-circuit
# optimisation (don't even run the probe during boot/reconcile), not the place
# that enforces window tolerance. This reliance on the module layer is intentional.
#
# Outcome mapping (the probe prints a single `outcome=...` line, exit code ignored):
#   ok            -> messagebox_ok=true,  messagebox_probed=true
#   failed        -> messagebox_ok=false, messagebox_probed=true  (the #3524 signature)
#   inconclusive  -> messagebox_probed=false  (e.g. DB unreachable — already caught
#                    by `iobroker status`; never reported as a messagebox failure)
#   node error / timeout -> messagebox_probed=false (fail safe: not a failure)
# ---------------------------------------------------------------------------
messagebox_ok=true
messagebox_probed=false

# The probe is eligible only outside the startup grace window. STARTUP_GRACE_PERIOD
# is an operator-supplied string that the pure module validates defensively (a
# non-finite window is treated as "not inside"); we must NOT feed a raw value into
# Bash arithmetic, because under `set -u` a non-numeric value like `oops` is treated
# as an (unset) arithmetic variable and ABORTS the whole script — which would flip a
# healthy host to failing. So we gate the probe on a numeric check: the probe runs
# only when STARTUP_GRACE_PERIOD is a valid non-negative integer AND startup elapsed
# is strictly past it. A malformed grace value simply skips the probe, preserving the
# prior status-only (healthy) behavior rather than turning the host unhealthy.
grace_is_valid=false
if [[ "${STARTUP_GRACE_PERIOD}" =~ ^[0-9]+$ ]]; then
  grace_is_valid=true
fi

if [[ "${IOB_MESSAGEBOX_PROBE}" == "true" ]] \
  && [[ "${check_succeeded}" == "true" ]] \
  && [[ "${grace_is_valid}" == "true" ]] \
  && [[ "${startup_elapsed_seconds}" -gt "${STARTUP_GRACE_PERIOD}" ]] \
  && [[ "${reconcile_in_progress}" != "true" ]]; then
  probe_out=""
  # Outer `timeout` is a BACKSTOP only — the module applies its own single overall
  # deadline (the inner timeout) across connect + round-trip + cleanup and prints a
  # conclusive `outcome=` line within it. The backstop must therefore be the inner
  # budget PLUS headroom for Node process start and module load, so the module can
  # emit `outcome=failed` on the #3524 path BEFORE the hard kill (an equal
  # outer/inner bound would preempt `failed`, the one outcome that must wait out the
  # full timeout). A backstop timeout/error yields no parseable outcome below and is
  # treated as inconclusive (not a messagebox failure).
  #
  # WHOLE-HEALTHCHECK BUDGET (review finding #2): Docker applies ONE --timeout
  # (IOB_HC_DOCKER_TIMEOUT, default 30s) to the ENTIRE script — the status command
  # (up to IOB_CHECK_TIMEOUT) AND the probe together, not to each separately. If the
  # status command and fact gathering already consumed much of that budget, a probe
  # sized only against its own knob could push the whole script past Docker's bound;
  # Docker would then record a FAILED check and could restart the container for a
  # slow-DB/setup hang that the messagebox probe is explicitly required NOT to
  # penalize. So we budget the probe's OUTER backstop against the time ALREADY
  # elapsed in this invocation, reserving a safety margin for the final decision
  # node call:
  #     remaining = IOB_HC_DOCKER_TIMEOUT - elapsed_so_far - IOB_HC_PROBE_SAFETY_MARGIN
  # The outer backstop is clamped to that remaining budget, and the inner deadline is
  # derived from the backstop (backstop - PROBE_BACKSTOP_HEADROOM, floor 1). If too
  # little time remains to run even a minimal probe, we SKIP it (status-only;
  # messagebox_probed stays false — never a failure), exactly as if the probe were
  # disabled. This keeps the complete healthcheck inside Docker's unchanged
  # --timeout while never turning a slow-but-healthy host unhealthy.
  #
  # The inner knob is still validated and clamped 1..MAX first (same `set -u` hazard
  # as the grace value: a non-integer must not reach arithmetic); a malformed/
  # out-of-range value falls back to the default 5.
  MESSAGEBOX_PROBE_TIMEOUT_MAX=15
  # Headroom (s) the outer backstop keeps over the inner deadline for Node start +
  # module load, so the module emits `outcome=failed` before the hard kill.
  PROBE_BACKSTOP_HEADROOM=10
  if [[ "${IOB_MESSAGEBOX_PROBE_TIMEOUT}" =~ ^[0-9]+$ ]] \
    && [[ "${IOB_MESSAGEBOX_PROBE_TIMEOUT}" -ge 1 ]] \
    && [[ "${IOB_MESSAGEBOX_PROBE_TIMEOUT}" -le "${MESSAGEBOX_PROBE_TIMEOUT_MAX}" ]]; then
    probe_inner_timeout="${IOB_MESSAGEBOX_PROBE_TIMEOUT}"
  else
    probe_inner_timeout=5
    log "IOB_MESSAGEBOX_PROBE_TIMEOUT='${IOB_MESSAGEBOX_PROBE_TIMEOUT}' is not an integer in" \
      "1..${MESSAGEBOX_PROBE_TIMEOUT_MAX}; using 5"
  fi
  # Desired outer backstop from the (clamped) inner knob.
  probe_hard_timeout=$(( probe_inner_timeout + PROBE_BACKSTOP_HEADROOM ))

  # Budget against the whole-healthcheck Docker timeout (review finding #2). Only
  # apply the budget when IOB_HC_DOCKER_TIMEOUT is a sane positive integer; a
  # malformed override simply disables the budget (keeps the knob-sized backstop).
  elapsed_so_far=$(( $(date +%s) - HEALTHCHECK_START ))
  if [[ "${elapsed_so_far}" -lt 0 ]]; then
    elapsed_so_far=0
  fi
  run_probe=true
  if [[ "${IOB_HC_DOCKER_TIMEOUT}" =~ ^[0-9]+$ ]] && [[ "${IOB_HC_DOCKER_TIMEOUT}" -gt 0 ]]; then
    safety_margin="${IOB_HC_PROBE_SAFETY_MARGIN}"
    if ! [[ "${safety_margin}" =~ ^[0-9]+$ ]]; then
      safety_margin=3
    fi
    remaining_budget=$(( IOB_HC_DOCKER_TIMEOUT - elapsed_so_far - safety_margin ))
    # A minimal probe needs its 1s inner deadline plus start/load headroom. If less
    # than that remains, skip the probe entirely (status-only; not a failure).
    probe_min_backstop=$(( 1 + PROBE_BACKSTOP_HEADROOM ))
    if [[ "${remaining_budget}" -lt "${probe_min_backstop}" ]]; then
      run_probe=false
      log "insufficient time budget for messagebox probe" \
        "(elapsed=${elapsed_so_far}s remaining=${remaining_budget}s <" \
        "min=${probe_min_backstop}s of Docker --timeout=${IOB_HC_DOCKER_TIMEOUT}s);" \
        "skipping probe (status-only, not a messagebox failure)"
    elif [[ "${probe_hard_timeout}" -gt "${remaining_budget}" ]]; then
      # Shrink the backstop to fit the remaining budget, and derive the inner
      # deadline from it (keep the start/load headroom, floor the inner at 1s).
      probe_hard_timeout="${remaining_budget}"
      probe_inner_timeout=$(( probe_hard_timeout - PROBE_BACKSTOP_HEADROOM ))
      if [[ "${probe_inner_timeout}" -lt 1 ]]; then
        probe_inner_timeout=1
      fi
      log "reduced messagebox probe budget to fit Docker --timeout" \
        "(elapsed=${elapsed_so_far}s -> backstop=${probe_hard_timeout}s inner=${probe_inner_timeout}s)"
    fi
  fi

  if [[ "${run_probe}" == "true" ]]; then
    if probe_out="$(IOB_MESSAGEBOX_PROBE_TIMEOUT="${probe_inner_timeout}" \
        timeout "${probe_hard_timeout}" \
        node "${MESSAGEBOX_PROBE_MODULE}" 2>/dev/null)"; then
      :
    else
      probe_rc=$?
      log "messagebox probe process exited ${probe_rc} -> treating as inconclusive"
    fi
    # Extract the outcome token from the single `outcome=<value>` line.
    probe_outcome="$(printf '%s\n' "${probe_out}" | sed -n 's/.*outcome=\([a-z]*\).*/\1/p' | head -n1)"
    case "${probe_outcome}" in
      ok)
        messagebox_probed=true
        messagebox_ok=true
        ;;
      failed)
        messagebox_probed=true
        messagebox_ok=false
        ;;
      *)
        # inconclusive / empty / unexpected: do NOT treat as a messagebox failure.
        messagebox_probed=false
        ;;
    esac
    log "messagebox probe outcome=${probe_outcome:-<none>}" \
      "(probed=${messagebox_probed} ok=${messagebox_ok})"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Ask the pure module for the state + exit code and act on it.
#
# We pass the resolved facts via environment variables (avoiding any shell
# quoting hazards) and let computeHealthState decide. The module returns the
# state and its mapped exit code; we log the state and exit with that code.
# ---------------------------------------------------------------------------
result="$(
  IOB_HC_CHECK_OK="${check_succeeded}" \
  IOB_HC_STARTUP_ELAPSED="${startup_elapsed_seconds}" \
  IOB_HC_STARTUP_GRACE="${STARTUP_GRACE_PERIOD}" \
  IOB_HC_UPGRADE_IN_PROGRESS="${upgrade_in_progress}" \
  IOB_HC_UPGRADE_ELAPSED="${upgrade_elapsed_seconds}" \
  IOB_HC_UPGRADE_WINDOW="${UPGRADE_TOLERANCE_WINDOW}" \
  IOB_HC_RECONCILE_IN_PROGRESS="${reconcile_in_progress}" \
  IOB_HC_RECONCILE_HB_AGE="${reconcile_heartbeat_age_seconds}" \
  IOB_HC_RECONCILE_STALL="${RECONCILE_STALL_TOLERANCE}" \
  IOB_HC_MESSAGEBOX_OK="${messagebox_ok}" \
  IOB_HC_MESSAGEBOX_PROBED="${messagebox_probed}" \
  node --input-type=module -e "
    import { computeHealthState } from '${HEALTH_MODULE}';
    const num = (v) => Number(String(v ?? '').trim());
    const { state, exitCode } = computeHealthState({
      checkSucceeded: process.env.IOB_HC_CHECK_OK === 'true',
      startupElapsedSeconds: num(process.env.IOB_HC_STARTUP_ELAPSED),
      startupGracePeriodSeconds: num(process.env.IOB_HC_STARTUP_GRACE),
      upgradeInProgress: process.env.IOB_HC_UPGRADE_IN_PROGRESS === 'true',
      upgradeElapsedSeconds: num(process.env.IOB_HC_UPGRADE_ELAPSED),
      upgradeToleranceWindowSeconds: num(process.env.IOB_HC_UPGRADE_WINDOW),
      reconcileInProgress: process.env.IOB_HC_RECONCILE_IN_PROGRESS === 'true',
      reconcileHeartbeatAgeSeconds: num(process.env.IOB_HC_RECONCILE_HB_AGE),
      reconcileStallToleranceSeconds: num(process.env.IOB_HC_RECONCILE_STALL),
      messageboxOk: process.env.IOB_HC_MESSAGEBOX_OK === 'true',
      messageboxProbed: process.env.IOB_HC_MESSAGEBOX_PROBED === 'true',
    });
    // Emit '<state> <exitCode>' on a single line for the shell to consume.
    process.stdout.write(state + ' ' + exitCode);
  "
)"

state="${result%% *}"
exit_code="${result##* }"

# Defensive: if the module produced nothing parseable, treat as unhealthy so a
# broken check surface fails closed rather than silently reporting healthy.
if [[ -z "${exit_code}" || ! "${exit_code}" =~ ^[0-9]+$ ]]; then
  log "could not determine health state (got: '${result}'); reporting unhealthy"
  exit 1
fi

log "state=${state} exit=${exit_code} (checkSucceeded=${check_succeeded}" \
  "startupElapsed=${startup_elapsed_seconds}/${STARTUP_GRACE_PERIOD}" \
  "upgradeInProgress=${upgrade_in_progress}" \
  "upgradeElapsed=${upgrade_elapsed_seconds}/${UPGRADE_TOLERANCE_WINDOW}" \
  "reconcileInProgress=${reconcile_in_progress}" \
  "reconcileHeartbeatAge=${reconcile_heartbeat_age_seconds}/${RECONCILE_STALL_TOLERANCE}" \
  "messageboxProbed=${messagebox_probed}" \
  "messageboxOk=${messagebox_ok})"

exit "${exit_code}"
