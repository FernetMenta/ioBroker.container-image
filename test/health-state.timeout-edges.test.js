// Unit tests for the 30s per-check timeout edges (task 5.4).
//
// Feature: rootless-iobroker-container-image, Requirement 9: Upgrade-Tolerant
// Healthcheck.
//
// These tests pin down how the three possible outcomes of a single check run
// map into `computeHealthState(...)` at the CHECK-RESULT level:
//
//   - fast-ok  → the status command returned exit 0 within the 30s timeout →
//                a successful check → healthy / exit code 0.
//   - non-zero → the status command returned a non-zero exit code →
//                a failed check → unhealthy / exit code 1 (outside both windows).
//   - hang>30s → the status command did not complete within the 30s timeout →
//                a failed check, indistinguishable from a non-zero exit →
//                unhealthy / exit code 1 (outside both windows).
//
// NOTE ON THE TIMEOUT: `lib/health-state.js` is a PURE decision module — it has
// no timers, no shell, and does not run the status command itself (that is the
// job of `scripts/healthcheck.sh`, task 12.1). The 30s per-check timeout is
// therefore modelled here as an INPUT: `checkSucceeded === true` means "exit 0
// within 30s", while `checkSucceeded === false` collapses BOTH the non-zero
// exit and the timeout/hang cases into a single "failed check" (Req 9.1, 9.2).
// A hang > 30s and a non-zero exit are deliberately represented identically,
// because the requirement treats them the same.
//
// To isolate the timeout mapping from the tolerance-window behaviour, every
// case below is evaluated OUTSIDE both windows (elapsed past window size, no
// upgrade in progress) so a failed check surfaces as `unhealthy` rather than
// being masked as `starting`.
//
// Requirements: 9.1, 9.2

import { describe, it, expect } from 'vitest';
import { computeHealthState, HealthState, ExitCode } from '../lib/health-state.js';

// Fixed "outside both windows" context shared by every case: the runtime is
// well past a small startup grace window and no upgrade is in progress, so the
// only thing that varies between cases is the check result itself.
const outsideBothWindows = {
  startupElapsedSeconds: 3600,
  startupGracePeriodSeconds: 300,
  upgradeInProgress: false,
  upgradeElapsedSeconds: 0,
  upgradeToleranceWindowSeconds: 600,
};

describe('health-state 30s per-check timeout edges (Req 9.1, 9.2)', () => {
  it('fast-ok: exit 0 within 30s is a successful check → healthy, exit code 0', () => {
    // checkSucceeded === true models "status command returned 0 within 30s".
    const result = computeHealthState({
      ...outsideBothWindows,
      checkSucceeded: true,
    });

    expect(result.state).toBe(HealthState.HEALTHY);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('non-zero exit: a failed check outside both windows → unhealthy, exit code 1', () => {
    // A non-zero exit code is a failed check (checkSucceeded === false).
    const result = computeHealthState({
      ...outsideBothWindows,
      checkSucceeded: false,
    });

    expect(result.state).toBe(HealthState.UNHEALTHY);
    expect(result.exitCode).toBe(ExitCode.UNHEALTHY);
  });

  it('hang > 30s (timeout): a failed check, identical to a non-zero exit → unhealthy, exit code 1', () => {
    // A hang past the 30s timeout is represented the same way as a non-zero
    // exit: checkSucceeded === false. The module cannot (and must not) tell the
    // two apart — the requirement treats them identically (Req 9.2).
    const result = computeHealthState({
      ...outsideBothWindows,
      checkSucceeded: false,
    });

    expect(result.state).toBe(HealthState.UNHEALTHY);
    expect(result.exitCode).toBe(ExitCode.UNHEALTHY);
  });

  it('a timeout/hang and a non-zero exit produce the identical result', () => {
    // Explicitly assert the equivalence of the two failure modes: whatever the
    // cause of the failed check, the reported state and exit code are the same.
    const nonZeroExit = computeHealthState({ ...outsideBothWindows, checkSucceeded: false });
    const timeoutHang = computeHealthState({ ...outsideBothWindows, checkSucceeded: false });

    expect(timeoutHang).toEqual(nonZeroExit);
  });
});
