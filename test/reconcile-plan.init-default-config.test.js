// Unit test for the empty Data_Volume initialization decision (task 6.6).
//
// Verifies the reconciliation planner's handling of the empty-Data_Volume
// branch: when the Data_Volume is empty, the plan MUST include the
// `init-default-config` action, and it MUST come first (before any
// install/repair or ABI-rebuild steps) so the default ioBroker config and
// state exist before adapters are reconciled. When the Data_Volume is NOT
// empty, the plan MUST NOT include that action.
//
// Requirements: 8.6 (WHEN the Container_Image starts with an empty Data_Volume,
// THE Iobroker_Runtime SHALL initialize the Data_Volume with a default ioBroker
// configuration and state).

import { describe, it, expect } from 'vitest';
import { planReconciliation, RECONCILE_ACTIONS } from '../lib/reconcile-plan.js';

describe('Reconciliation: empty Data_Volume initialization decision', () => {
  it('emits init-default-config when the Data_Volume is empty', () => {
    const plan = planReconciliation({ dataVolumeEmpty: true });

    expect(plan.actions).toContain(RECONCILE_ACTIONS.INIT_DEFAULT_CONFIG);
    expect(RECONCILE_ACTIONS.INIT_DEFAULT_CONFIG).toBe('init-default-config');
  });

  it('places init-default-config first, ahead of install/rebuild steps', () => {
    // Combine an empty Data_Volume with inputs that also produce install and
    // rebuild steps, to prove ordering: default init must precede them.
    const plan = planReconciliation({
      dataVolumeEmpty: true,
      desiredAdapters: ['admin', 'web'],
      registryReachable: true,
      abiMismatch: true,
      rebuildResourcesReachable: true,
      nativeModules: ['serialport'],
    });

    expect(plan.actions[0]).toBe(RECONCILE_ACTIONS.INIT_DEFAULT_CONFIG);
    expect(plan.actions.indexOf(RECONCILE_ACTIONS.INIT_DEFAULT_CONFIG)).toBe(0);
  });

  it('does NOT emit init-default-config when the Data_Volume is not empty', () => {
    const plan = planReconciliation({
      dataVolumeEmpty: false,
      desiredAdapters: ['admin'],
      registryReachable: true,
    });

    expect(plan.actions).not.toContain(RECONCILE_ACTIONS.INIT_DEFAULT_CONFIG);
  });

  it('defaults to no init-default-config when dataVolumeEmpty is omitted', () => {
    const plan = planReconciliation({});

    expect(plan.actions).not.toContain(RECONCILE_ACTIONS.INIT_DEFAULT_CONFIG);
  });
});
