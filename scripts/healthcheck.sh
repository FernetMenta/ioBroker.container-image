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
#      the two tolerance-window sizes, and whether an upgrade is in progress —
#      and
#   3. hands those facts to the pure decision module `lib/health-state.js`
#      (computeHealthState) and exits with the exit code it returns: 0 for
#      healthy/starting, 1 for unhealthy (Req 9.5, 9.10).
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
#
# Environment overrides (primarily for testing / non-default layouts):
#   IOB_ROOT              ioBroker install root (default /opt/iobroker)
#   IOB_START_MARKER      path to the runtime start marker written by the
#                         entrypoint (default $IOB_ROOT/iobroker-data/.iob-started)
#   IOB_UPGRADE_MARKER    path to the upgrade-in-progress sentinel written by the
#                         entrypoint/upgrade hook (default
#                         $IOB_ROOT/iobroker-data/.iob-upgrading)
#   IOB_STATUS_CMD        the status command to run (default "iobroker status");
#                         word-split, so it may include arguments
#   IOB_CHECK_TIMEOUT     per-check timeout in seconds (default 30; Req 9.1)
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
IOB_UPGRADE_MARKER="${IOB_UPGRADE_MARKER:-${IOB_DATA_DIR}/.iob-upgrading}"
IOB_STATUS_CMD="${IOB_STATUS_CMD:-iobroker status}"
IOB_CHECK_TIMEOUT="${IOB_CHECK_TIMEOUT:-30}"

# Window sizes come straight from the environment with the documented defaults.
# Out-of-range/malformed values are handled defensively by the pure module
# (a non-finite window is treated as "not inside"), so we do not re-validate
# here; the entrypoint owns range validation of operator config.
STARTUP_GRACE_PERIOD="${IOB_STARTUP_GRACE_PERIOD:-300}"
UPGRADE_TOLERANCE_WINDOW="${IOB_UPGRADE_TOLERANCE_WINDOW:-600}"

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
# 3. Detect upgrade-in-progress and, when in progress, its elapsed time.
#
# Two independent signals (design §6): a sentinel marker file written by the
# entrypoint/upgrade hook, and/or a running js-controller/adapter upgrade
# process. Either one means an upgrade is in progress. When the marker is
# present we take the upgrade's elapsed time from its modification time; a bare
# running-process signal without a marker yields elapsed 0 (freshly detected),
# which keeps us inside the upgrade window.
# ---------------------------------------------------------------------------
upgrade_in_progress=false
upgrade_elapsed_seconds=0

if [[ -f "${IOB_UPGRADE_MARKER}" ]]; then
  upgrade_in_progress=true
  up_mtime="$(stat -c '%Y' -- "${IOB_UPGRADE_MARKER}" 2>/dev/null || echo "")"
  if [[ -n "${up_mtime}" ]]; then
    upgrade_elapsed_seconds=$(( now - up_mtime ))
    if [[ "${upgrade_elapsed_seconds}" -lt 0 ]]; then
      upgrade_elapsed_seconds=0
    fi
  fi
  log "upgrade marker present (${IOB_UPGRADE_MARKER}); elapsed ${upgrade_elapsed_seconds}s"
elif pgrep -f 'iobroker[ ].*(upgrade|update)' >/dev/null 2>&1; then
  # A running controller/adapter upgrade process, no marker: in progress, fresh.
  upgrade_in_progress=true
  upgrade_elapsed_seconds=0
  log "upgrade process detected via process table; treating as in progress"
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
  "upgradeElapsed=${upgrade_elapsed_seconds}/${UPGRADE_TOLERANCE_WINDOW})"

exit "${exit_code}"
