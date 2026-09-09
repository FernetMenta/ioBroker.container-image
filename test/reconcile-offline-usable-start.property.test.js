// Property test for offline-usable reconciliation startup (task 6.4).
//
// Feature: rootless-iobroker-container-image, Property 5: Reconciliation always starts the runtime when modules are usable offline
//
// Property 5: Reconciliation always starts the runtime when modules are usable
// offline.
//
// Whenever the adapter registry is unreachable, reconciliation MUST start the
// runtime using the adapters currently present in node_modules, without failing
// startup — regardless of the desired adapter set, the present set, whether the
// Data_Volume is empty, or whether a Node.js ABI mismatch is present. No
// install work is performed offline; the present content is carried through
// unchanged, and when desired adapters could not be installed a warning is
// emitted (Req 8.11).
//
// Validates: Requirements 8.11

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { planReconciliation, RECONCILE_ACTIONS } from '../lib/reconcile-plan.js';

const adapterArb = fc.string({ minLength: 1 });
const adapterSetArb = fc.array(adapterArb);

function toSortedSet(list) {
  return [...new Set(list.filter((s) => typeof s === 'string' && s.length > 0))].sort();
}

describe('Property 5: reconciliation always starts the runtime when modules are usable offline', () => {
  it('starts with present node_modules and never fails when the registry is unreachable', () => {
    fc.assert(
      fc.property(
        adapterSetArb, // desiredAdapters (Data_Volume source of truth)
        adapterSetArb, // installedAdapters present in node_modules
        fc.boolean(), // dataVolumeEmpty — must not affect the offline-start guarantee
        fc.boolean(), // abiMismatch — must not affect the offline-start guarantee
        fc.boolean(), // rebuildResourcesReachable
        (desiredAdapters, installedAdapters, dataVolumeEmpty, abiMismatch, rebuildResourcesReachable) => {
          const plan = planReconciliation({
            desiredAdapters,
            installedAdapters,
            registryReachable: false, // registry unreachable (offline)
            dataVolumeEmpty,
            abiMismatch,
            rebuildResourcesReachable,
          });

          // Startup never fails offline.
          expect(plan.started).toBe(true);

          // No install work happens offline: the present set is carried through
          // unchanged (nothing is added to node_modules).
          expect(plan.installedAdapters).toEqual(toSortedSet(installedAdapters));

          // No install-missing step is ever emitted while offline.
          expect(plan.actions).not.toContain(RECONCILE_ACTIONS.INSTALL_MISSING);

          // If any desired adapter was missing, a warn-and-start step explains it.
          const presentSet = new Set(toSortedSet(installedAdapters));
          const missing = toSortedSet(desiredAdapters).filter((a) => !presentSet.has(a));
          if (missing.length > 0) {
            expect(plan.actions).toContain(RECONCILE_ACTIONS.WARN_AND_START);
          }
        },
      ),
      assertParams,
    );
  });
});
