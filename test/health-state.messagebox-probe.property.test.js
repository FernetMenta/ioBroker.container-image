// Property test for the messagebox-probe decision rule (ioBroker #3524).
//
// Feature: the active messagebox round-trip probe feeds two facts
// (`messageboxProbed`, `messageboxOk`) into the pure decision module. This test
// pins the full unhealthy iff once the probe rule is layered onto the existing
// three tolerance conditions.
//
// Property: a SUCCESSFUL status check is unhealthy IFF the messagebox probe ran
// AND failed AND the runtime is outside every tolerance window. A FAILED status
// check keeps its pre-existing behavior (the probe never changes it). Together
// this is: report unhealthy exactly when
//   (status failed  OR  (status ok AND messagebox probed-and-failed))
//   AND outside every tolerance window.
//
// Validates: the new probe rule preserves Req 9.5/9.10/9.11 independence.

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { computeHealthState, HealthState, ExitCode } from '../lib/health-state.js';

const elapsedArb = fc.nat({ max: 7200 });
const windowArb = fc.nat({ max: 3600 });
const boolArb = fc.boolean();

/**
 * Independent reference for the module's inclusive within-window semantics.
 *
 * @param {number} elapsed
 * @param {number} window
 * @returns {boolean}
 */
function within(elapsed, window) {
  return elapsed >= 0 && window >= 0 && elapsed <= window;
}

describe('messagebox-probe tolerance rule (ioBroker #3524)', () => {
  it('unhealthy iff (status-failed OR status-ok+probe-failed) AND outside every window', () => {
    fc.assert(
      fc.property(
        boolArb, // checkSucceeded
        elapsedArb, // startupElapsedSeconds
        windowArb, // startupGracePeriodSeconds
        boolArb, // upgradeInProgress
        elapsedArb, // upgradeElapsedSeconds
        windowArb, // upgradeToleranceWindowSeconds
        boolArb, // reconcileInProgress
        elapsedArb, // reconcileHeartbeatAgeSeconds
        windowArb, // reconcileStallToleranceSeconds
        boolArb, // messageboxProbed
        boolArb, // messageboxOk
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
          messageboxProbed,
          messageboxOk,
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
            messageboxProbed,
            messageboxOk,
          });

          const insideStartup = within(startupElapsedSeconds, startupGracePeriodSeconds);
          const insideUpgrade =
            upgradeInProgress && within(upgradeElapsedSeconds, upgradeToleranceWindowSeconds);
          const reconcileAlive =
            reconcileInProgress &&
            within(reconcileHeartbeatAgeSeconds, reconcileStallToleranceSeconds);
          const insideAnyWindow = insideStartup || insideUpgrade || reconcileAlive;

          const messageboxFailed = messageboxProbed && messageboxOk === false;

          // The failing driver is the status failure OR, on the success path, a
          // positive messagebox failure.
          const hasFailure = !checkSucceeded || (checkSucceeded && messageboxFailed);
          const expectedUnhealthy = hasFailure && !insideAnyWindow;

          expect(result.messageboxFailed).toBe(messageboxFailed);
          expect(result.state === HealthState.UNHEALTHY).toBe(expectedUnhealthy);
          expect(result.exitCode === ExitCode.UNHEALTHY).toBe(expectedUnhealthy);

          // A successful status check with no positive probe failure is always
          // healthy, exactly as before the probe existed.
          if (checkSucceeded && !messageboxFailed) {
            expect(result.state).toBe(HealthState.HEALTHY);
            expect(result.exitCode).toBe(ExitCode.OK);
          }
        },
      ),
      assertParams,
    );
  });
});
