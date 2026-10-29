// Unit tests for the messagebox self-probe decision edges (ioBroker #3524).
//
// Feature: the active messagebox round-trip probe (see `lib/messagebox-probe.js`)
// feeds two facts — `messageboxProbed` and `messageboxOk` — into the pure decision
// module. These example-based tests pin the specific interaction cases that the
// probe fact introduces on the SUCCESSFUL status-check path, so a regression names
// the exact broken case. They mirror the style of
// `test/health-state.reconcile-liveness.test.js`.
//
// Key semantics exercised:
//   - a successful status check turns unhealthy IFF the probe ran AND failed AND
//     the runtime is outside every tolerance window;
//   - a probe that did not run, or that succeeded, leaves success healthy;
//   - the three tolerance windows suppress a probe failure the same way they
//     suppress a status failure;
//   - a FAILED status check is completely unaffected by the probe facts.

import { describe, it, expect } from 'vitest';
import { computeHealthState, HealthState, ExitCode } from '../lib/health-state.js';

// Runtime is OUTSIDE every tolerance window (well past a small startup grace, no
// upgrade, no reconcile), so only the messagebox probe can change the verdict of
// an otherwise-healthy successful status check.
const outsideAllWindows = {
  startupElapsedSeconds: 3600,
  startupGracePeriodSeconds: 300,
  upgradeInProgress: false,
  upgradeElapsedSeconds: 3600,
  upgradeToleranceWindowSeconds: 600,
  reconcileInProgress: false,
  reconcileHeartbeatAgeSeconds: 0,
  reconcileStallToleranceSeconds: 120,
};

describe('messagebox-probe decision edges (ioBroker #3524)', () => {
  it('status-ok + messagebox-ok (probed) → healthy, exit 0', () => {
    const result = computeHealthState({
      ...outsideAllWindows,
      checkSucceeded: true,
      messageboxProbed: true,
      messageboxOk: true,
    });

    expect(result.messageboxFailed).toBe(false);
    expect(result.state).toBe(HealthState.HEALTHY);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('status-ok + messagebox-failed + outside all windows → unhealthy, exit 1', () => {
    const result = computeHealthState({
      ...outsideAllWindows,
      checkSucceeded: true,
      messageboxProbed: true,
      messageboxOk: false,
    });

    expect(result.messageboxFailed).toBe(true);
    expect(result.state).toBe(HealthState.UNHEALTHY);
    expect(result.exitCode).toBe(ExitCode.UNHEALTHY);
  });

  it('status-ok + messagebox-failed + INSIDE startup grace → healthy/tolerated, exit 0', () => {
    // The probe should not even run inside the grace window, but if a failure is
    // somehow reported, the tolerance window must still suppress unhealthy.
    const result = computeHealthState({
      ...outsideAllWindows,
      startupElapsedSeconds: 10,
      startupGracePeriodSeconds: 300,
      checkSucceeded: true,
      messageboxProbed: true,
      messageboxOk: false,
    });

    expect(result.withinStartupGrace).toBe(true);
    expect(result.messageboxFailed).toBe(true);
    expect(result.state).toBe(HealthState.HEALTHY);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('status-ok + messagebox-failed + live reconcile → healthy/tolerated, exit 0', () => {
    // A live reconcile is an independent tolerance condition and suppresses a
    // probe failure just like a status failure.
    const result = computeHealthState({
      ...outsideAllWindows,
      checkSucceeded: true,
      reconcileInProgress: true,
      reconcileHeartbeatAgeSeconds: 5,
      reconcileStallToleranceSeconds: 120,
      messageboxProbed: true,
      messageboxOk: false,
    });

    expect(result.reconcileAlive).toBe(true);
    expect(result.messageboxFailed).toBe(true);
    expect(result.state).toBe(HealthState.HEALTHY);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('status-ok + probe NOT run (messageboxProbed=false) → healthy, exit 0', () => {
    const result = computeHealthState({
      ...outsideAllWindows,
      checkSucceeded: true,
      messageboxProbed: false,
      // messageboxOk is irrelevant when not probed; default true path:
    });

    expect(result.messageboxFailed).toBe(false);
    expect(result.state).toBe(HealthState.HEALTHY);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('status-ok + probe omitted entirely (back-compat default) → healthy, exit 0', () => {
    // The pre-existing contract: callers that do not supply the new fields get
    // exactly the old behavior.
    const result = computeHealthState({
      ...outsideAllWindows,
      checkSucceeded: true,
    });

    expect(result.messageboxFailed).toBe(false);
    expect(result.state).toBe(HealthState.HEALTHY);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('status-FAILED + messagebox-ok → unaffected (unhealthy outside windows)', () => {
    const result = computeHealthState({
      ...outsideAllWindows,
      checkSucceeded: false,
      messageboxProbed: true,
      messageboxOk: true,
    });

    expect(result.state).toBe(HealthState.UNHEALTHY);
    expect(result.exitCode).toBe(ExitCode.UNHEALTHY);
  });

  it('status-FAILED + messagebox-failed → unaffected (still just a failed check)', () => {
    // The probe never runs when status failed; even if the facts are present the
    // failed-check path is unchanged.
    const result = computeHealthState({
      ...outsideAllWindows,
      checkSucceeded: false,
      messageboxProbed: true,
      messageboxOk: false,
    });

    expect(result.state).toBe(HealthState.UNHEALTHY);
    expect(result.exitCode).toBe(ExitCode.UNHEALTHY);
  });

  it('status-FAILED inside startup grace + messagebox-failed → starting (unchanged)', () => {
    const result = computeHealthState({
      ...outsideAllWindows,
      startupElapsedSeconds: 10,
      startupGracePeriodSeconds: 300,
      checkSucceeded: false,
      messageboxProbed: true,
      messageboxOk: false,
    });

    expect(result.state).toBe(HealthState.STARTING);
    expect(result.exitCode).toBe(ExitCode.OK);
  });
});
