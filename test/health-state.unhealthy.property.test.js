// Property test for the healthcheck state function (task 5.3).
//
// Feature: rootless-iobroker-container-image, Property 8: Healthcheck reports unhealthy exactly when a check fails outside both windows
//
// Property 8: Healthcheck reports unhealthy exactly when a check fails outside
// both tolerance windows.
//
// The mechanism reports `unhealthy` (exit code 1) if and only if the check
// failed AND the runtime is outside the startup grace window AND it is not
// protected by the upgrade window (either no upgrade in progress, or outside
// the upgrade tolerance window). A successful check is always `healthy`
// (exit code 0), regardless of the windows.
//
// Validates: Requirements 9.2, 9.5, 9.10

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { computeHealthState, HealthState, ExitCode } from '../lib/health-state.js';

// Same generators as task 5.2:
// - check success/failure is a boolean (a 30s timeout is modelled as a failure).
// - elapsed times span 0..7200s (up to twice the max window) so the input space
//   covers both inside- and outside-window cases plus the boundary.
// - window sizes span the operator-configurable 0..3600s range.
// - upgrade-in-progress is a boolean, since the upgrade window only applies
//   while an upgrade is actually running.
const checkSucceededArb = fc.boolean();
const elapsedArb = fc.nat({ max: 7200 });
const windowArb = fc.nat({ max: 3600 });
const upgradeInProgressArb = fc.boolean();

/**
 * Independent reference for "is `elapsed` within a window of size `window`",
 * mirroring the module's inclusive-boundary semantics without reusing its code.
 *
 * @param {number} elapsed
 * @param {number} window
 * @returns {boolean}
 */
function within(elapsed, window) {
  return elapsed >= 0 && window >= 0 && elapsed <= window;
}

describe('Property 8: healthcheck reports unhealthy exactly when a check fails outside both windows', () => {
  it('reports unhealthy iff the check failed and the runtime is outside both tolerance windows', () => {
    fc.assert(
      fc.property(
        checkSucceededArb,
        elapsedArb, // startupElapsedSeconds
        windowArb, // startupGracePeriodSeconds
        upgradeInProgressArb,
        elapsedArb, // upgradeElapsedSeconds
        windowArb, // upgradeToleranceWindowSeconds
        (
          checkSucceeded,
          startupElapsedSeconds,
          startupGracePeriodSeconds,
          upgradeInProgress,
          upgradeElapsedSeconds,
          upgradeToleranceWindowSeconds,
        ) => {
          const result = computeHealthState({
            checkSucceeded,
            startupElapsedSeconds,
            startupGracePeriodSeconds,
            upgradeInProgress,
            upgradeElapsedSeconds,
            upgradeToleranceWindowSeconds,
          });

          // Independently computed window facts.
          const insideStartup = within(startupElapsedSeconds, startupGracePeriodSeconds);
          const insideUpgrade =
            upgradeInProgress && within(upgradeElapsedSeconds, upgradeToleranceWindowSeconds);

          // The exact iff condition for reporting unhealthy: the check failed
          // AND the runtime is outside BOTH tolerance windows (Req 9.5).
          const expectedUnhealthy = !checkSucceeded && !insideStartup && !insideUpgrade;

          expect(result.state === HealthState.UNHEALTHY).toBe(expectedUnhealthy);
          expect(result.exitCode === ExitCode.UNHEALTHY).toBe(expectedUnhealthy);

          // A successful check is always healthy with exit code 0, regardless of
          // the windows (Req 9.2, 9.10).
          if (checkSucceeded) {
            expect(result.state).toBe(HealthState.HEALTHY);
            expect(result.exitCode).toBe(ExitCode.OK);
          }
        },
      ),
      assertParams,
    );
  });
});
