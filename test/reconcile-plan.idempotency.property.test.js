// Property test for reconciliation idempotency (task 6.3).
//
// Feature: rootless-iobroker-container-image, Property 4: Reconciliation is idempotent
//
// Property 4: Reconciliation is idempotent.
//
// Running the planner, then running it again against the resulting node_modules
// content model (feeding the first run's installedAdapters back in as the next
// run's installedAdapters), converges to the same installed adapter set and
// performs no further install work on the second run. This holds for the
// content-based planner regardless of registry reachability or an empty
// Data_Volume, because the second run observes the already-converged content.
//
// Validates: Requirements 8.9, 8.10, 8.11

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { planReconciliation, RECONCILE_ACTIONS } from '../lib/reconcile-plan.js';

// Adapter names: small, non-empty strings so generated sets overlap between the
// desired set and the present set often enough to exercise the missing/
// already-present branches meaningfully.
const adapterArb = fc.string({ minLength: 1, maxLength: 8 });
const adapterSetArb = fc.array(adapterArb, { maxLength: 8 });

describe('Property 4: reconciliation is idempotent', () => {
  it('converges the installed set and performs no further install work on the second run', () => {
    fc.assert(
      fc.property(
        adapterSetArb,
        adapterSetArb,
        fc.boolean(),
        fc.boolean(),
        (desiredAdapters, installedAdapters, registryReachable, dataVolumeEmpty) => {
          const inputs = {
            desiredAdapters,
            installedAdapters,
            registryReachable,
            dataVolumeEmpty,
          };

          const first = planReconciliation(inputs);

          // Second run: node_modules content is now whatever the first run
          // installed. Feed that back in as the present set.
          const second = planReconciliation({
            ...inputs,
            installedAdapters: first.installedAdapters,
          });

          // The installed set is stable across the two runs (Req 8.9-8.11).
          expect(second.installedAdapters).toEqual(first.installedAdapters);

          // The second run schedules no further install work: any install-missing
          // step installs an empty adapter set (everything is already present).
          for (const step of second.steps) {
            if (step.action === RECONCILE_ACTIONS.INSTALL_MISSING) {
              expect(step.adapters).toEqual([]);
            }
          }
        },
      ),
      assertParams,
    );
  });
});
