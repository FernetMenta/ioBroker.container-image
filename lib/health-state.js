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
// The two tolerance windows are INDEPENDENT: being inside either one alone
// prevents an unhealthy report, regardless of the other (Req 9.11).
//
// Requirements: 9.2, 9.3, 9.4, 9.5, 9.10, 9.11.

/**
 * Health states the mechanism can report.
 *
 * - `healthy`   — the check succeeded (js-controller is up and responsive).
 * - `starting`  — the check failed but the runtime is still inside a tolerance
 *                 window (startup grace and/or upgrade tolerance), so failures
 *                 are tolerated and unhealthy is NOT reported.
 * - `unhealthy` — the check failed and the runtime is outside both windows.
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
 */

/**
 * @typedef {object} HealthResult
 * @property {HealthState[keyof HealthState]} state - The reported state.
 * @property {ExitCode[keyof ExitCode]} exitCode - The mapped process exit code.
 * @property {boolean} withinStartupGrace - Whether inside the startup grace window.
 * @property {boolean} withinUpgradeWindow - Whether inside the (active) upgrade window.
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
 *     window), failures are tolerated and the state is `starting` — unhealthy is
 *     NOT reported (Req 9.3, 9.4). The two windows are evaluated independently,
 *     so being inside either alone is sufficient (Req 9.11).
 *  3. Otherwise the check failed outside both windows: the state is `unhealthy`
 *     (Req 9.5).
 *
 * @param {HealthCheckInput} input - The resolved facts for this check run.
 * @returns {HealthResult} The reported state, mapped exit code, and window flags.
 */
export function computeHealthState({
  checkSucceeded,
  startupElapsedSeconds,
  startupGracePeriodSeconds,
  upgradeInProgress,
  upgradeElapsedSeconds,
  upgradeToleranceWindowSeconds,
}) {
  const withinStartupGrace = withinWindow(startupElapsedSeconds, startupGracePeriodSeconds);

  // The upgrade window only applies while an upgrade is actually in progress.
  const withinUpgradeWindow =
    Boolean(upgradeInProgress) &&
    withinWindow(upgradeElapsedSeconds, upgradeToleranceWindowSeconds);

  let state;
  if (checkSucceeded) {
    state = HealthState.HEALTHY;
  } else if (withinStartupGrace || withinUpgradeWindow) {
    // Failed, but inside at least one independent tolerance window: tolerated.
    state = HealthState.STARTING;
  } else {
    // Failed outside both windows.
    state = HealthState.UNHEALTHY;
  }

  return {
    state,
    exitCode: exitCodeForState(state),
    withinStartupGrace,
    withinUpgradeWindow,
  };
}
