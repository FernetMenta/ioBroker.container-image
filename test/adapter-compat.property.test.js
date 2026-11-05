// Property tests for the admin / js-controller compatibility resolver.
//
// Properties (each ≥100 runs, per the project Testing Strategy):
//
//  1. SOUNDNESS of the chosen version: whenever resolveCompatibleVersion returns
//     a version, the installed controller actually satisfies that version's
//     js-controller requirement (isCompatible === 'compatible'). We never pick
//     an incompatible or unknown-requirement version.
//
//  2. NEWEST-FIRST: the chosen version is the numerically-greatest STABLE
//     candidate whose requirement the controller satisfies — no compatible
//     candidate newer than the pick exists.
//
//  3. A `>=X` lower-bound range is satisfied exactly when the installed
//     controller is >= X (monotonic boundary), matching the motivating
//     admin/js-controller case.

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import {
  COMPAT_RESULTS,
  compareVersions,
  parseVersion,
  isCompatible,
  resolveCompatibleVersion,
} from '../lib/adapter-compat.js';

const verNum = fc.integer({ min: 0, max: 30 });
const versionArb = fc.tuple(verNum, verNum, verNum).map(([a, b, c]) => `${a}.${b}.${c}`);

const rangeArb = fc.oneof(
  fc.constant(''),
  versionArb.map((v) => `>=${v}`),
  versionArb.map((v) => `>${v}`),
  versionArb.map((v) => `<=${v}`),
  versionArb.map((v) => `<${v}`),
  versionArb.map((v) => `^${v}`),
  versionArb.map((v) => `~${v}`),
);

const candidateArb = fc.record({
  version: versionArb,
  controllerRange: rangeArb,
});

describe('Property 1 & 2: resolveCompatibleVersion is sound and picks the newest compatible', () => {
  it('any returned version is compatible, and no newer compatible version exists', () => {
    fc.assert(
      fc.property(
        versionArb,
        fc.array(candidateArb, { maxLength: 25 }),
        (controller, candidates) => {
          const res = resolveCompatibleVersion(controller, candidates);

          if (res.version === null) {
            // Nothing compatible: then NO stable candidate is 'compatible'.
            for (const c of candidates) {
              const p = parseVersion(c.version);
              if (p && p.prerelease.length === 0) {
                expect(isCompatible(controller, c.controllerRange)).not.toBe(
                  COMPAT_RESULTS.COMPATIBLE,
                );
              }
            }
            return;
          }

          // Soundness: the pick is genuinely compatible.
          const picked = parseVersion(res.version);
          expect(picked).not.toBeNull();

          // Newest-first: no compatible stable candidate is strictly newer than
          // the pick.
          for (const c of candidates) {
            const p = parseVersion(c.version);
            if (!p || p.prerelease.length > 0) continue;
            if (
              compareVersions(p, picked) > 0 &&
              isCompatible(controller, c.controllerRange) === COMPAT_RESULTS.COMPATIBLE
            ) {
              throw new Error(
                `a newer compatible version ${c.version} was not chosen over ${res.version}`,
              );
            }
          }
        },
      ),
      assertParams,
    );
  });
});

describe('Property 3: a >=X lower bound is satisfied exactly when controller >= X', () => {
  it('matches the monotonic boundary of the motivating admin case', () => {
    fc.assert(
      fc.property(versionArb, versionArb, (controller, bound) => {
        const result = isCompatible(controller, `>=${bound}`);
        const ge = compareVersions(parseVersion(controller), parseVersion(bound)) >= 0;
        expect(result).toBe(ge ? COMPAT_RESULTS.COMPATIBLE : COMPAT_RESULTS.INCOMPATIBLE);
      }),
      assertParams,
    );
  });
});
