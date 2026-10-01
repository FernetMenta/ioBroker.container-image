// Unit test for the native-seed-driven ABI repair decision.
//
// Background: js-controller ships two source-only NAN native modules (diskusage,
// unix-dgram). The runtime image is deliberately toolchain-free, so on a
// Node-major upgrade (ABI change) the reconciler cannot `npm rebuild` them from
// source. Instead the image stashes pristine, correct-ABI copies and the
// reconciler OVERLAYS them (a local copy, needing no registry and no compiler).
//
// The planner models this via `nativeSeedAvailable`: an ABI mismatch is
// repairable when EITHER a local seed is available OR rebuild resources are
// reachable, so the plan emits `npm-rebuild` (whose shell handler overlays the
// seed and only compiles what the seed does not cover). Only when NEITHER repair
// is possible does it degrade to warn-and-start. (Req 8.12, 8.13)

import { describe, it, expect } from 'vitest';
import { planReconciliation, RECONCILE_ACTIONS } from '../lib/reconcile-plan.js';

describe('Reconciliation: native-seed-driven ABI repair', () => {
  it('emits npm-rebuild on ABI mismatch when a local seed is available, even offline', () => {
    // The key offline case: registry unreachable (so rebuildResourcesReachable
    // is false) but the image ships a seed we can overlay locally.
    const plan = planReconciliation({
      abiMismatch: true,
      rebuildResourcesReachable: false,
      nativeSeedAvailable: true,
      nativeModules: ['diskusage', 'unix-dgram'],
    });

    expect(plan.actions).toContain(RECONCILE_ACTIONS.NPM_REBUILD);
    // No ABI-driven warn-and-start step (one carrying `modules`) when repairable.
    const abiWarn = plan.steps.find(
      (s) => s.action === RECONCILE_ACTIONS.WARN_AND_START && Array.isArray(s.modules),
    );
    expect(abiWarn).toBeUndefined();
    expect(plan.started).toBe(true);
  });

  it('still emits npm-rebuild when rebuild resources are reachable but no seed', () => {
    const plan = planReconciliation({
      abiMismatch: true,
      rebuildResourcesReachable: true,
      nativeSeedAvailable: false,
      nativeModules: ['diskusage'],
    });

    expect(plan.actions).toContain(RECONCILE_ACTIONS.NPM_REBUILD);
  });

  it('degrades to warn-and-start only when NEITHER seed nor rebuild resources are available', () => {
    const plan = planReconciliation({
      abiMismatch: true,
      rebuildResourcesReachable: false,
      nativeSeedAvailable: false,
      nativeModules: ['diskusage', 'unix-dgram'],
    });

    expect(plan.actions).not.toContain(RECONCILE_ACTIONS.NPM_REBUILD);
    const abiWarn = plan.steps.find(
      (s) => s.action === RECONCILE_ACTIONS.WARN_AND_START && Array.isArray(s.modules),
    );
    expect(abiWarn).toBeDefined();
    // The affected modules are named in the warning.
    const abiWarning = plan.warnings.find((w) => w.includes('ABI mismatch'));
    expect(abiWarning).toBeDefined();
    expect(abiWarning).toContain('diskusage');
    expect(abiWarning).toContain('unix-dgram');
    // Startup still proceeds (Req 8.13).
    expect(plan.started).toBe(true);
  });

  it('does nothing ABI-related when there is no mismatch, regardless of seed', () => {
    const plan = planReconciliation({
      abiMismatch: false,
      nativeSeedAvailable: true,
      nativeModules: ['diskusage'],
    });

    expect(plan.actions).not.toContain(RECONCILE_ACTIONS.NPM_REBUILD);
    const abiWarn = plan.steps.find(
      (s) => s.action === RECONCILE_ACTIONS.WARN_AND_START && Array.isArray(s.modules),
    );
    expect(abiWarn).toBeUndefined();
  });

  it('defaults nativeSeedAvailable to false (back-compat): mismatch + unreachable => warn', () => {
    const plan = planReconciliation({
      abiMismatch: true,
      rebuildResourcesReachable: false,
      nativeModules: ['unix-dgram'],
    });

    expect(plan.actions).not.toContain(RECONCILE_ACTIONS.NPM_REBUILD);
    const abiWarn = plan.steps.find(
      (s) => s.action === RECONCILE_ACTIONS.WARN_AND_START && Array.isArray(s.modules),
    );
    expect(abiWarn).toBeDefined();
  });
});
