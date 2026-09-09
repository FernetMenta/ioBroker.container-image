// Property test for the upgrade-tolerant healthcheck state function (task 5.2).
//
// Feature: rootless-iobroker-container-image, Property 7: Healthcheck never reports unhealthy while inside either tolerance window
//
// Property 7: Healthcheck never reports unhealthy while inside either tolerance
// window.
//
// Whenever the runtime is inside the startup grace window OR (an upgrade is in
// progress AND the runtime is inside the upgrade tolerance window), the computed
// state is never `unhealthy` and the mapped exit code is `0` — regardless of
// whether the individual check succeeded or failed. The two tolerance windows
// are independent: being inside either one alone is sufficient to suppress an
// unhealthy report.
//
// Validates: Requirements 9.3, 9.4, 9.11

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { computeHealthState, HealthState, ExitCode } from '../lib/health-state.js';

// Elapsed times cover a range well beyond the largest window so that inputs
// land both inside and outside the windows (windows max at 3600).
const elapsedArb = fc.nat({ max: 7200 });

// Window sizes span from 0 (no tolerance) up to 3600 seconds.
const windowArb = fc.nat({ max: 3600 });

/**
 * Assert the core invariant of Property 7 for a single set of inputs: if the
 * runtime is inside either independent tolerance window, the state is never
 * `unhealthy` and the exit code is `0`.
 *
 * @param {import('../lib/health-state.js').HealthCheckInput} input
 */
function assertToleratedWhenInsideEitherWindow(input) {
  const result = computeHealthState(input);

  // Independently recompute window membership using the module's inclusive
  // (elapsed <= window) semantics.
  const insideStartupGrace =
    input.startupElapsedSeconds <= input.startupGracePeriodSeconds;
  const insideUpgradeWindow =
    input.upgradeInProgress &&
    input.upgradeElapsedSeconds <= input.upgradeToleranceWindowSeconds;

  // This helper is only exercised for inputs that are inside at least one
  // window, so the invariant must always hold here.
  expect(insideStartupGrace || insideUpgradeWindow).toBe(true);
  expect(result.state).not.toBe(HealthState.UNHEALTHY);
  expect(result.exitCode).toBe(ExitCode.OK);
}

describe('Property 7: healthcheck never reports unhealthy while inside either tolerance window', () => {
  it('tolerates failures while inside the startup grace window regardless of the upgrade window', () => {
    fc.assert(
      fc.property(
        fc.boolean(), // checkSucceeded — inside a window, success and failure alike are non-unhealthy
        windowArb, // startupGracePeriodSeconds
        fc.boolean(), // upgradeInProgress
        elapsedArb, // upgradeElapsedSeconds
        windowArb, // upgradeToleranceWindowSeconds
        (
          checkSucceeded,
          startupGracePeriodSeconds,
          upgradeInProgress,
          upgradeElapsedSeconds,
          upgradeToleranceWindowSeconds,
        ) =>
          fc.assert(
            // Draw a startup elapsed time guaranteed to be inside the grace
            // window (0..grace), so the startup window alone must suppress
            // unhealthy no matter what the upgrade window says.
            fc.property(fc.nat({ max: startupGracePeriodSeconds }), (startupElapsedSeconds) => {
              assertToleratedWhenInsideEitherWindow({
                checkSucceeded,
                startupElapsedSeconds,
                startupGracePeriodSeconds,
                upgradeInProgress,
                upgradeElapsedSeconds,
                upgradeToleranceWindowSeconds,
              });
            }),
            assertParams,
          ),
      ),
      assertParams,
    );
  });

  it('tolerates failures while an upgrade is in progress and inside the upgrade window regardless of the startup window', () => {
    fc.assert(
      fc.property(
        fc.boolean(), // checkSucceeded
        elapsedArb, // startupElapsedSeconds — may be outside the startup window
        windowArb, // startupGracePeriodSeconds
        windowArb, // upgradeToleranceWindowSeconds
        (checkSucceeded, startupElapsedSeconds, startupGracePeriodSeconds, upgradeToleranceWindowSeconds) =>
          fc.assert(
            // Draw an upgrade elapsed time guaranteed to be inside the upgrade
            // window (0..window); with upgradeInProgress = true the upgrade
            // window alone must suppress unhealthy even when the startup window
            // has already elapsed.
            fc.property(fc.nat({ max: upgradeToleranceWindowSeconds }), (upgradeElapsedSeconds) => {
              assertToleratedWhenInsideEitherWindow({
                checkSucceeded,
                startupElapsedSeconds,
                startupGracePeriodSeconds,
                upgradeInProgress: true,
                upgradeElapsedSeconds,
                upgradeToleranceWindowSeconds,
              });
            }),
            assertParams,
          ),
      ),
      assertParams,
    );
  });
});
