// Unit tests for the reconcile-liveness tolerance edges.
//
// Feature: rootless-iobroker-container-image, Requirement 9 extended with a
// reconcile-liveness condition. These example-based tests pin the specific
// boundary and interaction cases that the property tests cover only in
// aggregate, so a regression names the exact broken case.
//
// Context shared by every case: the runtime is OUTSIDE both elapsed windows
// (past a small startup grace, no upgrade in progress), so the ONLY thing that
// can suppress an unhealthy report is a live reconcile. This isolates the
// reconcile-liveness condition.
//
// Requirements: 9.3, 9.4, 9.5, 9.10, 9.11.

import { describe, it, expect } from 'vitest';
import { computeHealthState, HealthState, ExitCode } from '../lib/health-state.js';

// Outside both elapsed windows, so only reconcile liveness can rescue a failed
// check.
const outsideElapsedWindows = {
  startupElapsedSeconds: 3600,
  startupGracePeriodSeconds: 300,
  upgradeInProgress: false,
  upgradeElapsedSeconds: 3600,
  upgradeToleranceWindowSeconds: 600,
};

describe('reconcile-liveness edges (Req 9.3, 9.4, 9.5, 9.11)', () => {
  it('failed check + live reconcile (fresh heartbeat) → starting, exit 0', () => {
    const result = computeHealthState({
      ...outsideElapsedWindows,
      checkSucceeded: false,
      reconcileInProgress: true,
      reconcileHeartbeatAgeSeconds: 5,
      reconcileStallToleranceSeconds: 120,
    });

    expect(result.reconcileAlive).toBe(true);
    expect(result.state).toBe(HealthState.STARTING);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('failed check + reconcile in progress but STALE heartbeat → unhealthy, exit 1', () => {
    const result = computeHealthState({
      ...outsideElapsedWindows,
      checkSucceeded: false,
      reconcileInProgress: true,
      reconcileHeartbeatAgeSeconds: 121, // just past the tolerance
      reconcileStallToleranceSeconds: 120,
    });

    expect(result.reconcileAlive).toBe(false);
    expect(result.state).toBe(HealthState.UNHEALTHY);
    expect(result.exitCode).toBe(ExitCode.UNHEALTHY);
  });

  it('heartbeat age exactly equal to the stall tolerance is still inside (inclusive boundary)', () => {
    const result = computeHealthState({
      ...outsideElapsedWindows,
      checkSucceeded: false,
      reconcileInProgress: true,
      reconcileHeartbeatAgeSeconds: 120,
      reconcileStallToleranceSeconds: 120,
    });

    expect(result.reconcileAlive).toBe(true);
    expect(result.state).toBe(HealthState.STARTING);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('a fresh heartbeat does NOT rescue when no reconcile is in progress', () => {
    // The heartbeat age is meaningless unless a reconcile is actually running;
    // reconcileInProgress=false must never be treated as alive.
    const result = computeHealthState({
      ...outsideElapsedWindows,
      checkSucceeded: false,
      reconcileInProgress: false,
      reconcileHeartbeatAgeSeconds: 0,
      reconcileStallToleranceSeconds: 120,
    });

    expect(result.reconcileAlive).toBe(false);
    expect(result.state).toBe(HealthState.UNHEALTHY);
    expect(result.exitCode).toBe(ExitCode.UNHEALTHY);
  });

  it('a successful check is healthy even while a reconcile is in progress', () => {
    // Success always wins; the reconcile condition only ever suppresses an
    // otherwise-unhealthy FAILED check.
    const result = computeHealthState({
      ...outsideElapsedWindows,
      checkSucceeded: true,
      reconcileInProgress: true,
      reconcileHeartbeatAgeSeconds: 5,
      reconcileStallToleranceSeconds: 120,
    });

    expect(result.state).toBe(HealthState.HEALTHY);
    expect(result.exitCode).toBe(ExitCode.OK);
  });

  it('reconcile liveness is independent: it rescues even with zero-sized elapsed windows', () => {
    // Both elapsed windows are 0 (no tolerance) and elapsed, yet a live
    // reconcile alone suppresses unhealthy (Req 9.11 independence).
    const result = computeHealthState({
      checkSucceeded: false,
      startupElapsedSeconds: 10,
      startupGracePeriodSeconds: 0,
      upgradeInProgress: false,
      upgradeElapsedSeconds: 10,
      upgradeToleranceWindowSeconds: 0,
      reconcileInProgress: true,
      reconcileHeartbeatAgeSeconds: 1,
      reconcileStallToleranceSeconds: 120,
    });

    expect(result.reconcileAlive).toBe(true);
    expect(result.state).toBe(HealthState.STARTING);
    expect(result.exitCode).toBe(ExitCode.OK);
  });
});
