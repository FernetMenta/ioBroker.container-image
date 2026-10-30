// Health-watchdog decision logic (pure counting/debounce).
//
// This module contains the pure decision logic behind the in-container health
// watchdog (see `scripts/health-watchdog.sh`). The image has no Dockerfile
// HEALTHCHECK (`podman kube play` and Kubernetes ignore one), so it enforces its
// own health: the watchdog shell loop runs `scripts/healthcheck.sh` itself every INTERVAL
// seconds and feeds its EXIT CODE (0 = healthy/starting, 1 = unhealthy) into
// this module to decide when enough consecutive unhealthy results have
// accumulated to restart the controller.
//
// The pure/shell split mirrors `lib/health-state.js`: this module owns only the
// consecutive-unhealthy counting and the fire-once debounce; all side effects
// (the loop, the sleep, running healthcheck.sh, sending the signal) live in the
// shell glue so the decision is property-testable without a container.
//
// Deliberately excluded from this module (they belong to the shell glue):
//   - running `scripts/healthcheck.sh` and reading its exit code,
//   - sleeping INTERVAL seconds between checks,
//   - locating and signalling the controller process,
//   - reading/validating the INTERVAL/THRESHOLD knobs from the environment
//     (the shell validates them; this module only clamps THRESHOLD defensively
//     so a bad value can never make the pure layer misbehave).

/**
 * Healthcheck exit codes the watchdog reacts to.
 *
 * These mirror `scripts/healthcheck.sh` / `lib/health-state.js` `ExitCode`: `0`
 * means healthy OR starting (a tolerated failure inside a grace/upgrade/live-
 * reconcile window), `1` means unhealthy. The watchdog treats ONLY `1` as an
 * unhealthy result; any other value (including a non-standard exit) is treated
 * as "not unhealthy" and resets the streak, so a transient problem running the
 * healthcheck itself never accumulates toward a restart.
 *
 * @readonly
 * @enum {number}
 */
export const WatchdogExitCode = Object.freeze({
  HEALTHY: 0,
  UNHEALTHY: 1,
});

/**
 * The smallest threshold the decision logic will honour. A non-finite or `< 1`
 * threshold is clamped to this so the pure layer never triggers on a malformed
 * value (the shell independently validates/falls back to the default, but the
 * module stays correct even if a bad value reaches it).
 *
 * @type {number}
 */
const MIN_THRESHOLD = 1;

/**
 * Clamp a threshold to a usable positive integer.
 *
 * A non-finite value, or anything below {@link MIN_THRESHOLD}, is clamped to
 * {@link MIN_THRESHOLD}; a finite value is floored so a fractional threshold
 * (e.g. from a stray `3.5`) behaves as a whole count.
 *
 * @param {number} threshold - The requested consecutive-unhealthy threshold.
 * @returns {number} A positive integer threshold `>= MIN_THRESHOLD`.
 */
function clampThreshold(threshold) {
  if (!Number.isFinite(threshold) || threshold < MIN_THRESHOLD) {
    return MIN_THRESHOLD;
  }
  return Math.floor(threshold);
}

/**
 * @typedef {object} WatchdogInput
 * @property {number} currentExitCode
 *   The exit code of the most recent `scripts/healthcheck.sh` run: `1` is an
 *   unhealthy result (increments the streak), anything else (`0` healthy/
 *   starting, or an unexpected value) resets the streak to `0`.
 * @property {number} consecutiveCount
 *   The consecutive-unhealthy count carried over from the previous evaluation
 *   (start at `0`). A negative or non-finite carry-in is treated as `0`.
 * @property {number} threshold
 *   The number of consecutive unhealthy results that triggers a restart
 *   (default 3 in the shell). Clamped to a positive integer defensively.
 * @property {boolean} [alreadyTriggered]
 *   Whether a restart has already been triggered in this watchdog's lifetime.
 *   Once `true` it stays `true` (the latch): the watchdog fires SIGTERM exactly
 *   once and then lets systemd own the restart, so it never spams signals.
 *   Optional; defaults to `false`.
 */

/**
 * @typedef {object} WatchdogResult
 * @property {number} consecutiveCount
 *   The updated consecutive-unhealthy count: `previous + 1` on an unhealthy
 *   result, `0` otherwise.
 * @property {boolean} triggerRestart
 *   `true` ONLY on the single evaluation where the (incremented) count first
 *   reaches the threshold AND no restart had been triggered before. It is
 *   `false` on every other evaluation, including every one after the latch is
 *   set — so the caller sends at most one SIGTERM.
 * @property {boolean} alreadyTriggered
 *   The updated latch: `true` once a restart has ever been triggered, otherwise
 *   the carried-in value.
 */

/**
 * Decide the new consecutive-unhealthy count and whether to trigger a restart.
 *
 * Rules:
 *  1. An unhealthy result (`currentExitCode === 1`) increments the streak; any
 *     other exit code resets it to `0` (a single healthy/starting result clears
 *     the debounce — sustained unhealthiness is required, not a flap).
 *  2. `triggerRestart` is `true` only when the incremented streak first reaches
 *     the (clamped) threshold AND `alreadyTriggered` was `false`. On that
 *     evaluation the latch flips to `true`.
 *  3. Once the latch is set it never clears, and `triggerRestart` never fires
 *     again — the watchdog sends one SIGTERM and lets systemd take over, so a
 *     controller that is slow to exit is not signalled repeatedly.
 *
 * The function is pure: same inputs always yield the same output, no I/O.
 *
 * @param {WatchdogInput} input - The current exit code, carried state, and threshold.
 * @returns {WatchdogResult} The updated count, the one-shot restart decision, and the latch.
 */
export function evaluateWatchdog({
  currentExitCode,
  consecutiveCount,
  threshold,
  alreadyTriggered = false,
}) {
  const effectiveThreshold = clampThreshold(threshold);

  // Carry-in must be a non-negative integer; a bad value starts the streak over.
  const priorCount =
    Number.isFinite(consecutiveCount) && consecutiveCount > 0 ? Math.floor(consecutiveCount) : 0;

  const isUnhealthy = currentExitCode === WatchdogExitCode.UNHEALTHY;
  const newCount = isUnhealthy ? priorCount + 1 : 0;

  const latched = Boolean(alreadyTriggered);
  // Fire exactly once: the first time the streak reaches the threshold and we
  // have not fired before. `>=` (not `===`) is defensive — if the count somehow
  // jumped past the threshold we still fire rather than skip it.
  const triggerRestart = !latched && newCount >= effectiveThreshold;

  return {
    consecutiveCount: newCount,
    triggerRestart,
    alreadyTriggered: latched || triggerRestart,
  };
}
