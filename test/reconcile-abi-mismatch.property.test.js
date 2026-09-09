// Property test for ABI-mismatch reconciliation handling (task 6.5).
//
// Feature: rootless-iobroker-container-image, Property 6: ABI-mismatch handling always ends in a started runtime
//
// Property 6: ABI-mismatch handling always ends in a started runtime.
//
// Regardless of whether a Node.js ABI mismatch is detected and regardless of
// whether the rebuild resources are reachable, the reconciliation plan always
// ends with the Iobroker_Runtime started:
//   - An npm rebuild of the affected native modules is attempted if and only if
//     an ABI mismatch is detected AND the rebuild resources are reachable
//     (Req 8.12).
//   - When an ABI mismatch is detected but the rebuild resources are NOT
//     reachable, a warning naming the affected native modules is emitted and the
//     runtime still starts (Req 8.13).
//
// Validates: Requirements 8.12, 8.13

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { planReconciliation, RECONCILE_ACTIONS } from '../lib/reconcile-plan.js';

// Native module names: non-empty strings so they survive normalization and can
// be meaningfully named in the warning / rebuild step.
const nativeModulesArb = fc.array(fc.string({ minLength: 1 }));

describe('Property 6: ABI-mismatch handling always ends in a started runtime', () => {
  it('always starts the runtime; rebuilds iff mismatch and reachable, else warns naming affected modules', () => {
    fc.assert(
      fc.property(
        fc.boolean(), // abiMismatch
        fc.boolean(), // rebuildResourcesReachable
        fc.boolean(), // registryReachable — vary the reconciliation path
        nativeModulesArb, // native modules subject to an ABI rebuild
        (abiMismatch, rebuildResourcesReachable, registryReachable, nativeModules) => {
          const plan = planReconciliation({
            abiMismatch,
            rebuildResourcesReachable,
            registryReachable,
            nativeModules,
          });

          // Core invariant: reconciliation never fails startup (Req 8.12, 8.13).
          expect(plan.started).toBe(true);

          const attemptedRebuild = plan.actions.includes(RECONCILE_ACTIONS.NPM_REBUILD);

          // npm rebuild is attempted iff there is a mismatch AND rebuild
          // resources are reachable (Req 8.12).
          expect(attemptedRebuild).toBe(abiMismatch && rebuildResourcesReachable);

          if (abiMismatch && !rebuildResourcesReachable) {
            // ABI mismatch that cannot be rebuilt: a warn-and-start step is
            // emitted for the ABI condition, it names the affected modules, and
            // the runtime still starts (Req 8.13).
            const abiWarnStep = plan.steps.find(
              (s) => s.action === RECONCILE_ACTIONS.WARN_AND_START && Array.isArray(s.modules),
            );
            expect(abiWarnStep).toBeDefined();

            // The affected native modules are identified in the warning. Every
            // (normalized, non-empty) native module name appears in the warning
            // text; when none were provided, a generic "native modules" phrase
            // stands in.
            const uniqueModules = [...new Set(nativeModules.filter((m) => m.length > 0))];
            const abiWarning = plan.warnings.find((w) => w.includes('ABI mismatch'));
            expect(abiWarning).toBeDefined();
            if (uniqueModules.length > 0) {
              for (const mod of uniqueModules) {
                expect(abiWarning).toContain(mod);
              }
            } else {
              expect(abiWarning).toContain('native modules');
            }
          } else {
            // No ABI mismatch, or a mismatch that was rebuilt: no ABI-driven
            // warn-and-start step should be present. (A warn-and-start step from
            // the registry/persistence branch has no `modules` field, so it is
            // distinguishable and not asserted against here.)
            const abiWarnStep = plan.steps.find(
              (s) => s.action === RECONCILE_ACTIONS.WARN_AND_START && Array.isArray(s.modules),
            );
            expect(abiWarnStep).toBeUndefined();
          }
        },
      ),
      assertParams,
    );
  });
});
