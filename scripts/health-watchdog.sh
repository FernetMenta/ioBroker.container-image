#!/usr/bin/env bash
# health-watchdog.sh - in-container health watchdog for `podman kube play`.
#
# WHY THIS EXISTS
# ---------------
# The image ships a Docker-style HEALTHCHECK (Dockerfile) that runs
# scripts/healthcheck.sh with --interval=30s --retries=3. Under `docker run` /
# `podman run` the runtime schedules that HEALTHCHECK and reacts to it. But under
# `podman kube play` (the operator's deployment) the runtime does NOT schedule
# the image HEALTHCHECK: `podman inspect` reports `State.Health` as null and
# `podman healthcheck run` errors "has no defined healthcheck". So healthcheck.sh
# is never run on a schedule, the Dockerfile `--retries=3` budget is inert, and
# nothing reacts to an unhealthy container.
#
# This watchdog closes that gap. It runs INSIDE the container, started in the
# background by scripts/entrypoint.sh just before it execs js-controller. Every
# INTERVAL seconds it runs scripts/healthcheck.sh AS-IS and reads its EXIT CODE
# (0 = healthy/starting, 1 = unhealthy; see lib/health-state.js). It keeps a
# CONSECUTIVE-unhealthy counter (exit 1 increments, exit 0 resets) and, at
# THRESHOLD consecutive unhealthy results, sends ONE SIGTERM to the controller so
# the controller exits, the pod exits, and systemd's quadlet `Restart=always`
# restarts the whole pod. The consecutive-count debounce is what replaces the now-
# inert Dockerfile --retries=3.
#
# It does NOT re-implement any health logic: it invokes healthcheck.sh and
# branches on its exit code only. Because healthcheck.sh returns 0 ("starting")
# throughout the startup-grace / live-reconcile / upgrade windows, the watchdog
# inherits all of that tolerance for free and will not restart during boot or
# reconcile.
#
# SIGNAL / PROCESS MODEL (the tricky piece — reasoned explicitly)
# ---------------------------------------------------------------
# ENTRYPOINT is ["/usr/bin/tini","--","/opt/scripts/entrypoint.sh"] (Dockerfile),
# so tini is PID 1. tini execs entrypoint.sh, which runs as a child of tini at
# some PID `P` (NOT 1). entrypoint.sh backgrounds THIS script (`... &`) just
# before its final line:
#     scripts/entrypoint.sh:847  exec node ${IOB_NODE_OPTIONS} "${JS_CONTROLLER}" "$@"
# (JS_CONTROLLER is defined at scripts/entrypoint.sh:60.) Because the watchdog is
# backgrounded from the entrypoint shell, the watchdog's parent (`$PPID`) at
# launch is that entrypoint shell `P`. The `exec` on line 847 then REPLACES the
# entrypoint shell's process image with node WITHOUT changing its PID, so the
# js-controller `node` process IS pid `P` — the watchdog's own parent. node does
# NOT become PID 1; tini stays PID 1 and remains node's parent.
#
# Therefore the controller PID the watchdog must signal is its own `$PPID`,
# captured ONCE at startup (before any reparenting risk). This is robust and
# needs no process-table scraping: the kernel guarantees `$PPID` at launch is the
# entrypoint shell that `exec` turns into node.
#
# SIGNAL CHOICE: send SIGTERM to the controller `node` (the captured PPID), NOT to
# PID 1 (tini). node/js-controller installs a SIGTERM handler and shuts down
# gracefully (clean DB disconnect, adapter teardown); test/smoke/pid1-signals.sh
# proves `podman stop` (SIGTERM via tini -> node) yields a clean/terminating exit
# (0 or 143) within the stop timeout. Sending SIGTERM directly to node reproduces
# exactly that graceful path. When node (tini's only supervised child) exits, tini
# exits, the container exits, the pod exits, and systemd restarts it. Signaling
# tini (PID 1) directly would rely on tini forwarding SIGTERM to node; tini is a
# signal-forwarding init so that also works, but targeting node directly is
# simpler, is the SAME path the controller already handles for `stop`, and avoids
# any ambiguity about tini's forwarding/process-group semantics.
#
# GRACEFUL-THEN-FORCED, WITH THE BACKSTOP INSIDE THE WATCHDOG:
# We send SIGTERM FIRST so the controller can shut down gracefully. But the
# SIGTERM is sent INTERNALLY (watchdog -> node); it does NOT put systemd/podman
# into a stop operation, so `TimeoutStopSec=30` and the pod
# `terminationGracePeriodSeconds` are NOT armed as backstops on this path (they
# only bound a stop that systemd or podman itself initiated). js-controller's
# SIGTERM handler is a JavaScript callback (packages/controller main, SIGTERM ->
# stop(false)); if the health failure is an event-loop hang that callback can
# never run, or async shutdown can stall before process.exit — node and tini
# would stay alive, the pod would never exit, and `Restart=always` would never
# get an exit to act on. So the watchdog MUST provide the hard backstop itself:
# after SIGTERM it waits up to IOB_WATCHDOG_KILL_GRACE seconds for the controller
# to exit (polling `kill -0`), and if it is still alive it escalates to a single
# SIGKILL. SIGKILL cannot be caught or stall, so node is torn down, tini exits,
# and the pod restarts even in the hang case. This is strictly stronger than the
# old fire-one-SIGTERM-and-latch-forever behavior, which could leave an unhealthy
# pod running indefinitely.
#
# NO SIGNAL SPAM / DO NOT FIGHT A DELIBERATE STOP:
#   * The threshold triggers the SIGTERM->(grace)->SIGKILL escalation EXACTLY
#     ONCE (via the pure module's `triggerRestart`/`alreadyTriggered` latch); the
#     watchdog never re-enters the escalation on later cycles. The bounded
#     escalation — not an unbounded retry — is what replaces the inert
#     Dockerfile --retries=3: at most one SIGTERM and, only if that does not take
#     effect within the grace, one SIGKILL.
#   * The watchdog installs `trap 'running=0' TERM INT` so a signal delivered to
#     it interrupts the loop promptly without sending a restart signal. On a
#     DELIBERATE `systemctl stop`, though, tini runs WITHOUT `-g`, so it forwards
#     the stop SIGTERM only to its direct child (node), NOT to this watchdog
#     grandchild — the trap usually does NOT fire from that forwarding. What
#     actually keeps the watchdog from racing a deliberate stop is TIMING: the
#     pod `terminationGracePeriodSeconds` (10s) and `TimeoutStopSec=30` are far
#     shorter than the default THRESHOLD*INTERVAL (~90s), so during a stop the
#     watchdog can run at most a cycle or two and cannot reach the threshold; and
#     when node exits the pod namespace is torn down, taking the watchdog with
#     it. (An operator who sets a very short interval with a low threshold owns
#     that tuning.) The trap still guarantees a prompt, quiet exit if the signal
#     ever is delivered directly to the watchdog.
#   * Before each kill the captured controller PID is checked with `kill -0`; if it
#     is already gone the container is on its way down anyway — exit quietly, do
#     not signal.
#
# OPT-OUT: the entrypoint gates the launch on IOB_HEALTHCHECK_WATCHDOG (default
# enabled; only `=false` disables). This script is simply not started when the
# knob is false, so behavior is exactly as before.
#
# Usage:
#   health-watchdog.sh        # long-running; run in the background
#
# Environment:
#   IOB_WATCHDOG_INTERVAL   seconds between healthcheck runs (default 30).
#                           Validated with the healthcheck.sh numeric idiom; a
#                           malformed or < 1 value falls back to the default.
#   IOB_WATCHDOG_THRESHOLD  consecutive unhealthy results before SIGTERM
#                           (default 3; ~90s at the default interval, aligned with
#                           js-controller's ~90s DB give-up). Same validation.
#   IOB_WATCHDOG_KILL_GRACE seconds to wait for the controller to exit after the
#                           graceful SIGTERM before escalating to SIGKILL
#                           (default 15). Same validation; a malformed or < 1
#                           value falls back to the default. This is the hard
#                           backstop for a controller that hangs on SIGTERM.
#
# Test/override hooks (NOT operator knobs — used only by test/smoke):
#   IOB_WATCHDOG_HEALTHCHECK_CMD  command to run as the healthcheck (default the
#                                 real scripts/healthcheck.sh path). Word-split so
#                                 a stub may include arguments.
#   IOB_WATCHDOG_TARGET_PID       PID to signal instead of the captured $PPID, so
#                                 a smoke test can point at a disposable process.
#   IOB_WATCHDOG_MAX_CYCLES       if set to a positive integer, exit after that
#                                 many loop iterations (keeps smoke tests bounded;
#                                 unset in production = loop forever).
#   IOB_WATCHDOG_SIGNAL_LOG       if set to a path, every signal the watchdog
#                                 sends is appended as "<SIG> <pid>" (e.g.
#                                 "TERM 1234"). Lets a smoke test COUNT signal
#                                 attempts across cycles (prove fire-once) even
#                                 when the target ignores SIGTERM.
set -u

# --- Locate ourselves and the sibling lib/ module ---------------------------
# Resolve this script's directory so we can find scripts/healthcheck.sh and
# lib/watchdog-state.js regardless of the working directory we are launched from
# (same approach as healthcheck.sh / reconcile.sh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
WATCHDOG_MODULE="${REPO_ROOT}/lib/watchdog-state.js"
HEALTHCHECK_SH="${SCRIPT_DIR}/healthcheck.sh"

# The healthcheck invocation is overridable for the smoke harness; default to the
# real script. Word-split intentionally so a stub may carry arguments.
IOB_WATCHDOG_HEALTHCHECK_CMD="${IOB_WATCHDOG_HEALTHCHECK_CMD:-${HEALTHCHECK_SH}}"

# Logging goes to BOTH stderr (so it still reaches the container's journald
# stream) AND a dedicated file in the log directory. Under `podman kube play`
# the log dir (${IOB_LOG_DIR:-/opt/iobroker/log}) is a bind-mounted volume, so a
# file there SURVIVES the pod restart this watchdog triggers — which matters,
# because the single most useful record ("I restarted the pod, and why") must
# outlive the restart instead of vanishing with the container's journald scope.
# The separate file also keeps watchdog/health events out of the js-controller
# log noise so they are easy to find without journalctl.
#
# Fail-safe: if the log dir is missing or not writable we fall back to
# stderr-only rather than letting a logging failure disrupt the watchdog.
WATCHDOG_LOG_DIR="${IOB_LOG_DIR:-/opt/iobroker/log}"
WATCHDOG_LOG_FILE="${IOB_WATCHDOG_LOG_FILE:-${WATCHDOG_LOG_DIR}/health-watchdog.log}"
_watchdog_log_file_ok=false
if { [[ -d "${WATCHDOG_LOG_DIR}" ]] && [[ -w "${WATCHDOG_LOG_DIR}" ]]; } \
  && { : >>"${WATCHDOG_LOG_FILE}"; } 2>/dev/null; then
  _watchdog_log_file_ok=true
fi

# log: everything goes to stderr (journald). Nothing goes to the dedicated file.
log() { printf 'health-watchdog: %s\n' "$*" >&2; }

# logissue: lines worth keeping in the dedicated file — the one-time "started"
# note (so the file records when this watchdog instance began, which is also a
# natural "pod was (re)started here" marker after a restart) plus every unhealthy
# cycle, the restart decision, and the escalation. These go to stderr AND, when
# writable, are appended (timestamped) to the dedicated, restart-surviving log
# file. Routine healthy cycles are NOT logged at all (no heartbeat), so the file
# stays quiet and, apart from the startup note, only fills with things that
# actually went wrong. The file survives the pod restart (bind-mounted log
# volume), so the "why did I restart" record outlives the container.
logissue() {
  local line
  line="$(printf 'health-watchdog: %s' "$*")"
  printf '%s\n' "${line}" >&2
  if [[ "${_watchdog_log_file_ok}" == "true" ]]; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${line}" \
      >>"${WATCHDOG_LOG_FILE}" 2>/dev/null || true
  fi
}

# send_signal: deliver SIG ($1) to PID ($2), recording the attempt to
# IOB_WATCHDOG_SIGNAL_LOG (if set) BEFORE the kill so a smoke test can count how
# many signals the watchdog attempted even when the target ignores them. Returns
# the kill's own exit status. The recorded line is "<SIG> <pid>".
send_signal() {
  local sig="$1" pid="$2"
  if [[ -n "${IOB_WATCHDOG_SIGNAL_LOG:-}" ]]; then
    printf '%s %s\n' "${sig}" "${pid}" >>"${IOB_WATCHDOG_SIGNAL_LOG}" 2>/dev/null || true
  fi
  kill "-${sig}" "${pid}" 2>/dev/null
}

# --- Resolve and validate the interval / threshold --------------------------
# healthcheck.sh numeric idiom: under `set -u` a non-integer fed into arithmetic
# aborts the script, so each value is accepted ONLY when it matches ^[0-9]+$ and
# is >= 1; otherwise it logs and falls back to the documented default BEFORE any
# arithmetic touches it.
DEFAULT_INTERVAL=30
DEFAULT_THRESHOLD=3
DEFAULT_KILL_GRACE=15

interval="${IOB_WATCHDOG_INTERVAL:-${DEFAULT_INTERVAL}}"
if ! [[ "${interval}" =~ ^[0-9]+$ ]] || [[ "${interval}" -lt 1 ]]; then
  log "IOB_WATCHDOG_INTERVAL='${interval}' is not an integer >= 1; using ${DEFAULT_INTERVAL}"
  interval="${DEFAULT_INTERVAL}"
fi

threshold="${IOB_WATCHDOG_THRESHOLD:-${DEFAULT_THRESHOLD}}"
if ! [[ "${threshold}" =~ ^[0-9]+$ ]] || [[ "${threshold}" -lt 1 ]]; then
  log "IOB_WATCHDOG_THRESHOLD='${threshold}' is not an integer >= 1; using ${DEFAULT_THRESHOLD}"
  threshold="${DEFAULT_THRESHOLD}"
fi

# Grace period between the graceful SIGTERM and the forced SIGKILL backstop.
kill_grace="${IOB_WATCHDOG_KILL_GRACE:-${DEFAULT_KILL_GRACE}}"
if ! [[ "${kill_grace}" =~ ^[0-9]+$ ]] || [[ "${kill_grace}" -lt 1 ]]; then
  log "IOB_WATCHDOG_KILL_GRACE='${kill_grace}' is not an integer >= 1; using ${DEFAULT_KILL_GRACE}"
  kill_grace="${DEFAULT_KILL_GRACE}"
fi

# --- Capture the controller PID ONCE at startup -----------------------------
# See the SIGNAL / PROCESS MODEL section: our $PPID at launch is the entrypoint
# shell that entrypoint.sh:847 `exec`s into js-controller (same PID). Capture it
# now, before any reparenting could occur. A test may override the target.
controller_pid="${IOB_WATCHDOG_TARGET_PID:-${PPID}}"

# Defensive cross-check (documented, not a hard dependency): we must never blindly
# SIGTERM PID 1 (tini). If the captured target is 1 or otherwise implausible, the
# launch model we rely on (exec-replaces-shell, so $PPID == node) has changed; in
# that case decline to signal and run in observe-only mode rather than kill the
# wrong process. On Linux /proc/<pid>/comm should read `node` for the real target;
# we log a warning on a mismatch but still proceed (the comm name can legitimately
# differ, e.g. a test target), because the kill -0 liveness guard before each
# signal is the real safety net.
signalling_enabled=true
if ! [[ "${controller_pid}" =~ ^[0-9]+$ ]] || [[ "${controller_pid}" -le 1 ]]; then
  log "captured controller PID '${controller_pid}' is implausible (<=1); running in" \
    "observe-only mode (will NOT send any signal) — the exec/PPID launch model may have changed"
  signalling_enabled=false
else
  target_comm=""
  if [[ -r "/proc/${controller_pid}/comm" ]]; then
    target_comm="$(tr -d '\n' <"/proc/${controller_pid}/comm" 2>/dev/null || echo "")"
  fi
  if [[ -n "${target_comm}" && "${target_comm}" != "node" ]]; then
    log "controller PID ${controller_pid} comm='${target_comm}' (expected 'node');" \
      "proceeding, but verify the launch model if this is production"
  fi
fi

# Optional bounded run for the smoke harness; unset/invalid => loop forever.
max_cycles=0
if [[ "${IOB_WATCHDOG_MAX_CYCLES:-}" =~ ^[0-9]+$ ]]; then
  max_cycles="${IOB_WATCHDOG_MAX_CYCLES}"
fi

# Terminate promptly when the container/pod stops (and do NOT send a restart
# signal on the way out — see the "do not fight a deliberate stop" note).
running=1
trap 'running=0' TERM INT

logissue "started (interval=${interval}s threshold=${threshold} kill_grace=${kill_grace}s" \
  "controller_pid=${controller_pid} signalling=${signalling_enabled}); runs ${HEALTHCHECK_SH} and," \
  "after ${threshold} consecutive unhealthy results, SIGTERMs the controller (then SIGKILLs it if it" \
  "does not exit within ${kill_grace}s) so systemd restarts the pod"

# Word-split the healthcheck command intentionally so a stub may carry arguments.
# shellcheck disable=SC2206
healthcheck_cmd=(${IOB_WATCHDOG_HEALTHCHECK_CMD})

consecutive_count=0
already_triggered=false
cycles=0

while [[ "${running}" -eq 1 ]]; do
  # 1. Run the healthcheck AS-IS and capture its exit code (0 healthy/starting,
  #    1 unhealthy). We never let a non-zero exit abort this loop. We also capture
  #    the healthcheck's own stderr (its `healthcheck: ...` diagnostics) so that,
  #    when a cycle is unhealthy, the REASON is recorded in our dedicated log file
  #    alongside the watchdog's own lines — that is the "healthcheck issues in a
  #    separate logfile" the operator wants, not buried in journald.
  hc_exit=0
  hc_output="$("${healthcheck_cmd[@]}" 2>&1)" || hc_exit=$?

  # 2. Feed (exitCode, count, threshold, latch) to the pure decision module and
  #    read back the new count + whether to trigger a restart. Same node
  #    invocation style as healthcheck.sh step 4 — values passed via env to avoid
  #    any shell quoting hazards.
  decision="$(
    IOB_WD_EXIT="${hc_exit}" \
    IOB_WD_COUNT="${consecutive_count}" \
    IOB_WD_THRESHOLD="${threshold}" \
    IOB_WD_TRIGGERED="${already_triggered}" \
    node --input-type=module -e "
      import { evaluateWatchdog } from '${WATCHDOG_MODULE}';
      const num = (v) => Number(String(v ?? '').trim());
      const { consecutiveCount, triggerRestart, alreadyTriggered } = evaluateWatchdog({
        currentExitCode: num(process.env.IOB_WD_EXIT),
        consecutiveCount: num(process.env.IOB_WD_COUNT),
        threshold: num(process.env.IOB_WD_THRESHOLD),
        alreadyTriggered: process.env.IOB_WD_TRIGGERED === 'true',
      });
      // Emit '<count> <triggerRestart> <alreadyTriggered>' for the shell.
      process.stdout.write(consecutiveCount + ' ' + triggerRestart + ' ' + alreadyTriggered);
    " 2>/dev/null
  )"

  if [[ -z "${decision}" ]]; then
    # The decision module produced nothing parseable (node missing, module error).
    # Fail SAFE: do not restart on a broken decision surface; keep the prior state
    # and try again next cycle.
    log "could not evaluate watchdog decision (exit=${hc_exit}); keeping count=${consecutive_count}"
  else
    read -r new_count trigger_restart new_triggered <<<"${decision}"
    consecutive_count="${new_count}"
    already_triggered="${new_triggered}"

    if [[ "${hc_exit}" -eq 1 ]]; then
      logissue "healthcheck unhealthy (exit 1); consecutive=${consecutive_count}/${threshold}"
      # Record the healthcheck's own diagnostics (why it was unhealthy) to the
      # issue log, not only journald. Keep it to the last few lines to avoid
      # flooding on a persistent failure.
      if [[ -n "${hc_output}" ]]; then
        while IFS= read -r _hc_line; do
          [[ -n "${_hc_line}" ]] && logissue "  healthcheck> ${_hc_line}"
        done < <(printf '%s\n' "${hc_output}" | tail -n 5)
      fi
    fi

    if [[ "${trigger_restart}" == "true" ]]; then
      # 3. Threshold reached for the FIRST time (the pure module latches so this
      #    branch runs exactly once): drive the bounded escalation that makes the
      #    controller exit so the pod restarts. Guard with kill -0 so we never
      #    signal a dead/absent target, and never signal in observe-only mode.
      if [[ "${signalling_enabled}" != "true" ]]; then
        logissue "THRESHOLD reached (${consecutive_count} consecutive unhealthy) but signalling is" \
          "disabled (implausible target); not sending any signal"
      elif ! kill -0 "${controller_pid}" 2>/dev/null; then
        logissue "THRESHOLD reached but controller pid ${controller_pid} is already gone;" \
          "container is already terminating — not signalling"
      else
        # 3a. Graceful SIGTERM first: js-controller's handler shuts down cleanly
        #     (DB disconnect, adapter teardown), the same path `podman stop`
        #     drives.
        logissue "THRESHOLD reached (${consecutive_count} consecutive unhealthy): sending SIGTERM to" \
          "controller pid ${controller_pid} so it exits and systemd restarts the pod"
        if ! send_signal TERM "${controller_pid}"; then
          logissue "WARNING failed to send SIGTERM to controller pid ${controller_pid}"
        fi

        # 3b. Hard backstop: this SIGTERM is internal, so systemd/podman timeouts
        #     are NOT armed on this path. Wait up to kill_grace seconds for the
        #     controller to actually exit (poll once per second, interruptible so
        #     a real container stop still tears us down promptly). If it is still
        #     alive at the end of the grace — e.g. an event-loop hang where the
        #     JS SIGTERM handler can never run — escalate to a single SIGKILL,
        #     which cannot be caught or stall. node is then torn down, tini exits,
        #     and the pod restarts even in the hang case.
        waited=0
        while [[ "${waited}" -lt "${kill_grace}" ]] && kill -0 "${controller_pid}" 2>/dev/null && [[ "${running}" -eq 1 ]]; do
          sleep 1 &
          wait $! 2>/dev/null || true
          waited=$(( waited + 1 ))
        done
        if kill -0 "${controller_pid}" 2>/dev/null; then
          if [[ "${running}" -ne 1 ]]; then
            logissue "controller pid ${controller_pid} still up but the watchdog is stopping; not escalating"
          else
            logissue "controller pid ${controller_pid} did not exit within ${kill_grace}s of SIGTERM" \
              "(likely a hang); escalating to SIGKILL so the pod is torn down and restarted"
            if ! send_signal KILL "${controller_pid}"; then
              logissue "WARNING failed to send SIGKILL to controller pid ${controller_pid}"
            fi
          fi
        else
          logissue "controller pid ${controller_pid} exited after SIGTERM; systemd will restart the pod"
        fi
      fi
      # The pure module's latch prevents this branch from ever running again; we
      # do not spam signals or re-enter the escalation on later cycles.
    fi
  fi

  # Bounded run for the smoke harness only.
  if [[ "${max_cycles}" -gt 0 ]]; then
    cycles=$(( cycles + 1 ))
    if [[ "${cycles}" -ge "${max_cycles}" ]]; then
      log "reached IOB_WATCHDOG_MAX_CYCLES=${max_cycles}; exiting loop"
      break
    fi
  fi

  # 4. Sleep the interval in the background and wait, so a TERM (container stop)
  #    interrupts the wait promptly rather than after a full interval.
  sleep "${interval}" &
  wait $! 2>/dev/null || true
done

log "stopping"
exit 0
