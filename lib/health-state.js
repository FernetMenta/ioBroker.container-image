// Upgrade-tolerant healthcheck state computation (pure decision logic).
//
// This module contains the pure decision logic behind the
// `Healthcheck_Mechanism` (see `scripts/healthcheck.sh`, task 12.1). It takes
// the already-resolved facts a check run has gathered — whether the js-controller
// status command succeeded, how long the runtime has been up, and whether a
// controller/adapter upgrade is in progress — and decides the reported state and
// the process exit code.
//
// Deliberately excluded from this module (they belong to the shell glue):
//   - running `iobroker status` and enforcing the 30s per-check timeout. A check
//     that times out is represented here simply as `checkSucceeded === false`
//     (Req 9.1, 9.2). No timers, no shell, no I/O.
//   - detecting upgrade-in-progress (sentinel file / running upgrade process).
//   - reading the window sizes from the environment.
//
// The tolerance conditions are INDEPENDENT: being inside any one alone prevents
// an unhealthy report, regardless of the others (Req 9.11).
//
// There are THREE independent tolerance conditions:
//   1. startup grace         — inside the startup grace window,
//   2. upgrade tolerance     — an upgrade is in progress AND inside its window,
//   3. reconcile liveness     — reconciliation is in progress AND its heartbeat
//                              is still fresh (see below).
//
// Reconcile liveness is deliberately NOT a fixed elapsed-time window. The
// entrypoint runs reconciliation (init default config, install adapters, npm
// rebuild) BEFORE js-controller starts, so `iobroker status` fails for the whole
// reconcile phase. That phase has no meaningful upper bound: a slow connection,
// a slow SD card, and many adapters can push it well past any fixed grace. What
// we can bound is STALL: as long as reconcile keeps advancing a heartbeat, it is
// alive and failures are tolerated no matter how long it runs; only when the
// heartbeat goes stale (older than the stall-tolerance window) do we stop
// tolerating and let the other conditions decide. This turns an unbounded
// total-duration problem into a bounded stall-detection one.
//
// Requirements: 9.2, 9.3, 9.4, 9.5, 9.10, 9.11.

/**
 * Health states the mechanism can report.
 *
 * - `healthy`   — the check succeeded (js-controller is up and responsive).
 * - `starting`  — the check failed but the runtime is still inside a tolerance
 *                 condition (startup grace, upgrade tolerance, or a live
 *                 reconcile), so failures are tolerated and unhealthy is NOT
 *                 reported.
 * - `unhealthy` — the check failed and the runtime is outside every tolerance
 *                 condition.
 *
 * @readonly
 * @enum {string}
 */
export const HealthState = Object.freeze({
  HEALTHY: 'healthy',
  STARTING: 'starting',
  UNHEALTHY: 'unhealthy',
});

/**
 * Process exit codes mapped from health state.
 *
 * Docker treats any non-zero healthcheck exit as unhealthy, so both `healthy`
 * and `starting` map to `0` (a tolerated failure inside a window must not kill
 * the container) and only `unhealthy` maps to `1` (Req 9.5, 9.10).
 *
 * @readonly
 * @enum {number}
 */
export const ExitCode = Object.freeze({
  OK: 0,
  UNHEALTHY: 1,
});

/**
 * True when `elapsed` is still within a window of size `window`.
 *
 * The boundary is inclusive: at exactly `elapsed === window` the runtime is
 * still considered within the window. A window of `0` means "no tolerance",
 * so only `elapsed <= 0` counts as inside it. Negative or non-finite values
 * are treated as "not inside" defensively.
 *
 * @param {number} elapsed - Seconds elapsed relevant to the window.
 * @param {number} window - Window size in seconds.
 * @returns {boolean} Whether the runtime is within the window.
 */
function withinWindow(elapsed, window) {
  if (!Number.isFinite(elapsed) || !Number.isFinite(window)) {
    return false;
  }
  return elapsed >= 0 && window >= 0 && elapsed <= window;
}

/**
 * Map a health state to its process exit code.
 *
 * @param {HealthState[keyof HealthState]} state - A health state.
 * @returns {ExitCode[keyof ExitCode]} `0` for healthy/starting, `1` for unhealthy.
 */
export function exitCodeForState(state) {
  return state === HealthState.UNHEALTHY ? ExitCode.UNHEALTHY : ExitCode.OK;
}

/**
 * @typedef {object} HealthCheckInput
 * @property {boolean} checkSucceeded
 *   Whether the js-controller status command returned success (exit 0) within
 *   the 30s per-check timeout. A non-zero exit OR a timeout is `false` (the
 *   timeout is represented as a failed check, not modelled here). (Req 9.1, 9.2)
 * @property {number} startupElapsedSeconds
 *   Seconds since the runtime started (used against `startupGracePeriodSeconds`).
 * @property {number} startupGracePeriodSeconds
 *   The `Startup_Grace_Period` in seconds (default 300).
 * @property {boolean} upgradeInProgress
 *   Whether a js-controller/adapter upgrade is currently in progress.
 * @property {number} upgradeElapsedSeconds
 *   Seconds since the upgrade began (only meaningful when `upgradeInProgress`).
 * @property {number} upgradeToleranceWindowSeconds
 *   The `Upgrade_Tolerance_Window` in seconds (default 600).
 * @property {boolean} [reconcileInProgress]
 *   Whether the entrypoint's reconciliation phase is currently in progress
 *   (js-controller has not been started yet). Optional; defaults to `false`.
 * @property {number} [reconcileHeartbeatAgeSeconds]
 *   Seconds since reconciliation last advanced its heartbeat (now minus the
 *   heartbeat file mtime). Only meaningful when `reconcileInProgress`. A small
 *   value means reconcile is alive; a value exceeding
 *   `reconcileStallToleranceSeconds` means it has stalled.
 * @property {number} [reconcileStallToleranceSeconds]
 *   The `Reconcile_Stall_Tolerance` in seconds (default 120): the maximum age
 *   the reconcile heartbeat may reach before a live reconcile is no longer
 *   assumed. Optional; defaults to `0` (no reconcile tolerance) when absent.
 */

/**
 * @typedef {object} HealthResult
 * @property {HealthState[keyof HealthState]} state - The reported state.
 * @property {ExitCode[keyof ExitCode]} exitCode - The mapped process exit code.
 * @property {boolean} withinStartupGrace - Whether inside the startup grace window.
 * @property {boolean} withinUpgradeWindow - Whether inside the (active) upgrade window.
 * @property {boolean} reconcileAlive - Whether a reconcile is in progress with a fresh heartbeat.
 */

/**
 * Compute the healthcheck state and exit code from a single check's facts.
 *
 * Decision logic:
 *  1. If the check succeeded, the state is `healthy` regardless of the windows
 *     (a successful check is never unhealthy — Req 9.10; and success recovers
 *     from any prior state).
 *  2. Otherwise (the check failed): if the runtime is inside the startup grace
 *     window OR (an upgrade is in progress AND inside the upgrade tolerance
 *     window) OR (a reconcile is in progress AND its heartbeat is still fresh),
 *     failures are tolerated and the state is `starting` — unhealthy is NOT
 *     reported (Req 9.3, 9.4). The three conditions are evaluated independently,
 *     so being inside any one alone is sufficient (Req 9.11).
 *  3. Otherwise the check failed outside every tolerance condition: the state is
 *     `unhealthy` (Req 9.5).
 *
 * The reconcile-liveness condition uses the SAME inclusive `withinWindow`
 * semantics as the other windows, but against the heartbeat AGE rather than an
 * elapsed-since-start time: reconcile is "alive" while its heartbeat age is
 * within the stall-tolerance window. Because a live reconcile keeps resetting
 * that age, the tolerance has no upper bound on total reconcile duration — only
 * on how long it may stall.
 *
 * @param {HealthCheckInput} input - The resolved facts for this check run.
 * @returns {HealthResult} The reported state, mapped exit code, and condition flags.
 */
export function computeHealthState({
  checkSucceeded,
  startupElapsedSeconds,
  startupGracePeriodSeconds,
  upgradeInProgress,
  upgradeElapsedSeconds,
  upgradeToleranceWindowSeconds,
  reconcileInProgress = false,
  reconcileHeartbeatAgeSeconds = 0,
  reconcileStallToleranceSeconds = 0,
}) {
  const withinStartupGrace = withinWindow(startupElapsedSeconds, startupGracePeriodSeconds);

  // The upgrade window only applies while an upgrade is actually in progress.
  const withinUpgradeWindow =
    Boolean(upgradeInProgress) &&
    withinWindow(upgradeElapsedSeconds, upgradeToleranceWindowSeconds);

  // Reconcile liveness only applies while a reconcile is actually in progress,
  // and holds only while the heartbeat age is within the stall-tolerance window
  // (a stale heartbeat means reconcile is stuck, not merely slow).
  const reconcileAlive =
    Boolean(reconcileInProgress) &&
    withinWindow(reconcileHeartbeatAgeSeconds, reconcileStallToleranceSeconds);

  let state;
  if (checkSucceeded) {
    state = HealthState.HEALTHY;
  } else if (withinStartupGrace || withinUpgradeWindow || reconcileAlive) {
    // Failed, but inside at least one independent tolerance condition: tolerated.
    state = HealthState.STARTING;
  } else {
    // Failed outside every tolerance condition.
    state = HealthState.UNHEALTHY;
  }

  return {
    state,
    exitCode: exitCodeForState(state),
    withinStartupGrace,
    withinUpgradeWindow,
    reconcileAlive,
  };
}
