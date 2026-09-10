// Property test for the reconcile-liveness tolerance condition.
//
// Feature: rootless-iobroker-container-image, Requirement 9 (Upgrade-Tolerant
// Healthcheck) extended with a reconcile-liveness condition.
//
// The entrypoint runs reconciliation (init default config, install adapters,
// npm rebuild) BEFORE js-controller starts, so `iobroker status` fails for the
// whole reconcile phase. That phase has no meaningful upper time bound (a slow
// connection, a slow SD card, and many adapters can push it well past any fixed
// grace window). Rather than gate it on an elapsed-since-start window, the
// mechanism tolerates a failing check for ANY total duration as long as
// reconciliation keeps advancing a heartbeat; only when the heartbeat goes stale
// (older than the stall-tolerance window) does reconcile stop being tolerated.
//
// This test pins two properties of that third, independent tolerance condition:
//
//   P-A. A live reconcile (in progress AND heartbeat age within the stall
//        tolerance) NEVER reports unhealthy, regardless of how the two elapsed
//        windows are set — even when the runtime is well outside both of them.
//        This is the "unbounded total duration" guarantee: the heartbeat age,
//        not any elapsed-since-start time, is what matters.
//
//   P-B. The full unhealthy iff, now over THREE independent conditions: the
//        mechanism reports unhealthy exactly when the check failed AND the
//        runtime is outside the startup grace window AND it is not protected by
//        the upgrade window AND it is not protected by a live reconcile.
//
// Validates: Requirements 9.3, 9.4, 9.5, 9.10, 9.11.

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { computeHealthState, HealthState, ExitCode } from '../lib/health-state.js';

const checkSucceededArb = fc.boolean();
const elapsedArb = fc.nat({ max: 7200 });
const windowArb = fc.nat({ max: 3600 });
const boolArb = fc.boolean();

/**
 * Independent reference for the module's inclusive within-window semantics,
 * deliberately not reusing the module's own helper.
 *
 * @param {number} elapsed
 * @param {number} window
 * @returns {boolean}
 */
function within(elapsed, window) {
  return elapsed >= 0 && window >= 0 && elapsed <= window;
}

describe('reconcile-liveness tolerance (Req 9.3, 9.4, 9.5, 9.10, 9.11)', () => {
  it('P-A: a live reconcile suppresses unhealthy regardless of the two elapsed windows', () => {
    fc.assert(
      fc.property(
        // The check may pass or fail; when it fails, only the live reconcile
        // can rescue it here because we place the runtime OUTSIDE both windows.
        checkSucceededArb,
        // Startup/upgrade windows are sized to a fixed small value and the
        // elapsed times are pushed beyond them, so neither elapsed window is
        // ever inside — isolating the reconcile condition as the sole rescuer.
        windowArb, // reconcileStallToleranceSeconds
        (checkSucceeded, reconcileStallToleranceSeconds) =>
          fc.assert(
            // Heartbeat age guaranteed within the stall tolerance (0..tolerance)
            // => reconcile is alive.
            fc.property(fc.nat({ max: reconcileStallToleranceSeconds }), (reconcileHeartbeatAgeSeconds) => {
              const result = computeHealthState({
                checkSucceeded,
                // Both elapsed windows are firmly in the past / disabled.
                startupElapsedSeconds: 7200,
                startupGracePeriodSeconds: 300,
                upgradeInProgress: false,
                upgradeElapsedSeconds: 7200,
                upgradeToleranceWindowSeconds: 600,
                // A live reconcile.
                reconcileInProgress: true,
                reconcileHeartbeatAgeSeconds,
                reconcileStallToleranceSeconds,
              });

              expect(result.reconcileAlive).toBe(true);
              expect(result.state).not.toBe(HealthState.UNHEALTHY);
              expect(result.exitCode).toBe(ExitCode.OK);
            }),
            assertParams,
          ),
      ),
      assertParams,
    );
  });

  it('P-B: reports unhealthy exactly when the check fails outside all three conditions', () => {
    fc.assert(
      fc.property(
        checkSucceededArb,
        elapsedArb, // startupElapsedSeconds
        windowArb, // startupGracePeriodSeconds
        boolArb, // upgradeInProgress
        elapsedArb, // upgradeElapsedSeconds
        windowArb, // upgradeToleranceWindowSeconds
        boolArb, // reconcileInProgress
        elapsedArb, // reconcileHeartbeatAgeSeconds
        windowArb, // reconcileStallToleranceSeconds
        (
          checkSucceeded,
          startupElapsedSeconds,
          startupGracePeriodSeconds,
          upgradeInProgress,
          upgradeElapsedSeconds,
          upgradeToleranceWindowSeconds,
          reconcileInProgress,
          reconcileHeartbeatAgeSeconds,
          reconcileStallToleranceSeconds,
        ) => {
          const result = computeHealthState({
            checkSucceeded,
            startupElapsedSeconds,
            startupGracePeriodSeconds,
            upgradeInProgress,
            upgradeElapsedSeconds,
            upgradeToleranceWindowSeconds,
            reconcileInProgress,
            reconcileHeartbeatAgeSeconds,
            reconcileStallToleranceSeconds,
          });

          const insideStartup = within(startupElapsedSeconds, startupGracePeriodSeconds);
          const insideUpgrade =
            upgradeInProgress && within(upgradeElapsedSeconds, upgradeToleranceWindowSeconds);
          const reconcileAlive =
            reconcileInProgress && within(reconcileHeartbeatAgeSeconds, reconcileStallToleranceSeconds);

          // The exact iff over three INDEPENDENT conditions (Req 9.5, 9.11).
          const expectedUnhealthy =
            !checkSucceeded && !insideStartup && !insideUpgrade && !reconcileAlive;

          expect(result.reconcileAlive).toBe(reconcileAlive);
          expect(result.state === HealthState.UNHEALTHY).toBe(expectedUnhealthy);
          expect(result.exitCode === ExitCode.UNHEALTHY).toBe(expectedUnhealthy);

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
