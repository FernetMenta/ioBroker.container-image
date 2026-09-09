// Property test for database-backend configuration idempotency (task 7.2).
//
// Feature: rootless-iobroker-container-image, Property 10: Database/multihost configuration is re-applied if and only if the IOB_* values change
//
// Property 10: `planDbConfig(desired, current)` proposes a change (`changed:
// true`) if and only if a field the operator SPECIFIED differs from the current
// config; when the specified fields already match, it is a no-op (`changed:
// false`, Req 12.7). Applying the plan and re-planning against the applied
// values is a no-op (idempotent, Req 12.8). Fields the operator did not specify
// are never proposed for change (Req 12.3).
//
// Validates: Requirements 12.3, 12.7, 12.8

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { planDbConfig } from '../lib/db-plan.js';

// A DB section using only valid values so plans are always accepted.
const sectionArb = fc.record(
  {
    type: fc.constantFrom('jsonl', 'file', 'redis'),
    host: fc.string({ minLength: 1, maxLength: 12 }),
    port: fc.integer({ min: 1, max: 65535 }),
  },
  { requiredKeys: [] }, // any subset may be specified (or none)
);

const desiredArb = fc.record(
  {
    objects: sectionArb,
    states: sectionArb,
    role: fc.constantFrom('master', 'slave'),
  },
  { requiredKeys: [] },
);

describe('Property 10: DB/multihost config is re-applied iff specified IOB_* values change', () => {
  it('changed iff a specified field differs from current; applying then re-planning is a no-op', () => {
    fc.assert(
      fc.property(desiredArb, desiredArb, (previous, desired) => {
        // Current config = what "previous" would have applied. Build a current
        // shape from previous's specified fields.
        const current = {
          objects: { ...previous.objects },
          states: { ...previous.states },
          role: previous.role ?? '',
        };

        const plan = planDbConfig(desired, current);
        expect(plan.valid).toBe(true);

        // Independently compute whether any specified field differs.
        const differs = (sect, cur) =>
          Object.keys(sect ?? {}).some((k) => {
            const d = k === 'port' ? Number(sect[k]) : sect[k];
            const c = k === 'port' ? Number(cur?.[k]) : cur?.[k];
            return d !== c;
          });
        const roleDiff = (desired.role ?? '') !== '' && (desired.role ?? '') !== (current.role ?? '');
        const expectedChanged =
          differs(desired.objects, current.objects) ||
          differs(desired.states, current.states) ||
          roleDiff;
        expect(plan.changed).toBe(expectedChanged);

        // Idempotency: apply the plan (its specified fields become current) and
        // re-plan against the same desired -> no change.
        const applied = {
          objects: { ...current.objects, ...plan.objects },
          states: { ...current.states, ...plan.states },
          role: plan.role || current.role || '',
        };
        const replan = planDbConfig(desired, applied);
        expect(replan.valid).toBe(true);
        expect(replan.changed).toBe(false);
        expect(replan.changes).toEqual([]);
      }),
      assertParams,
    );
  });
});
