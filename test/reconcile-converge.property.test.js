// Property test for reconciliation convergence to the Data_Volume set (task 6.2).
//
// Feature: rootless-iobroker-container-image, Property 3: Reconciliation converges the installed adapter set to the Data_Volume when the registry is reachable
//
// Property 3: When the adapter registry is reachable, Reconciliation converges
// the CONTENT of node_modules toward the Data_Volume (the source of truth) by
// installing the desired adapters not already present. The resulting installed
// set is exactly `present ∪ desired`, so every desired adapter ends up
// installed and every already-present adapter is retained — regardless of
// whether node_modules is a mount (the planner is content-based and does not
// consider mount state; Req 8.5, 8.9, 8.10).
//
// Validates: Requirements 8.5, 8.9, 8.10

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { planReconciliation } from '../lib/reconcile-plan.js';

/**
 * Mirror the module's normalization: sorted, de-duplicated, non-empty strings.
 *
 * @param {string[]} list
 * @returns {string[]}
 */
function toSortedSet(list) {
  return [...new Set(list.filter((s) => typeof s === 'string' && s.length > 0))].sort();
}

// Adapter-name generators. fc.string() may produce empty strings, exercising
// the module's empty-string filtering.
const adapterSetArb = fc.array(fc.string());

describe('Property 3: reconciliation converges node_modules content to the Data_Volume (registry reachable)', () => {
  it('makes installed adapters equal the desired set when node_modules is empty', () => {
    fc.assert(
      fc.property(adapterSetArb, (desiredAdapters) => {
        const plan = planReconciliation({
          desiredAdapters,
          installedAdapters: [],
          registryReachable: true,
        });

        const desiredSet = toSortedSet(desiredAdapters);

        // Empty node_modules: install the full desired set.
        expect(plan.installedAdapters).toEqual(desiredSet);
        for (const a of desiredSet) {
          expect(plan.installedAdapters).toContain(a);
        }
        expect(plan.started).toBe(true);
      }),
      assertParams,
    );
  });

  it('installs only the missing desired adapters and retains present ones (content-based)', () => {
    fc.assert(
      fc.property(adapterSetArb, adapterSetArb, (desiredAdapters, installedAdapters) => {
        const plan = planReconciliation({
          desiredAdapters,
          installedAdapters,
          registryReachable: true,
        });

        const desiredSet = toSortedSet(desiredAdapters);
        const presentSet = toSortedSet(installedAdapters);
        // Expected: present ∪ desired (install only what's missing).
        const expected = toSortedSet([...presentSet, ...desiredSet]);

        expect(plan.installedAdapters).toEqual(expected);
        // Convergence: every Data_Volume adapter is installed.
        for (const a of desiredSet) {
          expect(plan.installedAdapters).toContain(a);
        }
        // Already-present adapters are retained (never removed by reconciliation).
        for (const a of presentSet) {
          expect(plan.installedAdapters).toContain(a);
        }
        expect(plan.started).toBe(true);
      }),
      assertParams,
    );
  });
});
