// Property test for the health-watchdog decision logic.
//
// Feature: in-container health watchdog (see lib/watchdog-state.js). Over random
// sequences of healthcheck exit codes and random thresholds, two invariants must
// hold when the watchdog state is carried step-to-step exactly as the shell loop
// carries it:
//
//   Property 1 (fire once): `triggerRestart` is true on AT MOST one step of any
//     sequence — the watchdog sends a single SIGTERM and then latches, which is
//     what plays the role of an orchestrator --retries setting (no signal spam).
//
//   Property 2 (fire correctly): the step where it fires (if any) is exactly the
//     first step at which the running count of consecutive unhealthy (exit 1)
//     results, with any healthy/other result resetting the run, reaches the
//     clamped threshold. Equivalently: it fires iff there is a window of >=
//     threshold consecutive exit-1 results, and it fires at the end of the FIRST
//     such window.

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { evaluateWatchdog } from '../lib/watchdog-state.js';

// Exit codes mostly 0/1 (the healthcheck's defined values), with an occasional
// odd value mixed in so the "anything but 1 resets the streak" rule is exercised.
const exitCodeArb = fc.oneof(
  { weight: 9, arbitrary: fc.constantFrom(0, 1) },
  { weight: 1, arbitrary: fc.integer({ min: 2, max: 130 }) },
);
const sequenceArb = fc.array(exitCodeArb, { minLength: 0, maxLength: 40 });
// Thresholds include values <1 to exercise the clamp-to-1 path.
const thresholdArb = fc.integer({ min: 0, max: 6 });

/**
 * Independent reference: the index of the end of the FIRST run of `>= threshold`
 * consecutive exit-1 values (any other value resets the run), or -1 if none.
 * Mirrors the clamp-to-1 semantics of the module without reusing its code.
 *
 * @param {number[]} sequence
 * @param {number} threshold
 * @returns {number}
 */
function firstTriggerIndex(sequence, threshold) {
  const effective = Number.isFinite(threshold) && threshold >= 1 ? Math.floor(threshold) : 1;
  let run = 0;
  for (let i = 0; i < sequence.length; i += 1) {
    run = sequence[i] === 1 ? run + 1 : 0;
    if (run >= effective) {
      return i;
    }
  }
  return -1;
}

describe('watchdog decision properties', () => {
  it('triggers on at most one step, and exactly at the first threshold-length unhealthy run', () => {
    fc.assert(
      fc.property(sequenceArb, thresholdArb, (sequence, threshold) => {
        let consecutiveCount = 0;
        let alreadyTriggered = false;
        const triggeredAt = [];

        sequence.forEach((currentExitCode, index) => {
          const result = evaluateWatchdog({
            currentExitCode,
            consecutiveCount,
            threshold,
            alreadyTriggered,
          });
          consecutiveCount = result.consecutiveCount;
          alreadyTriggered = result.alreadyTriggered;
          if (result.triggerRestart) {
            triggeredAt.push(index);
          }
        });

        // Property 1: fire at most once.
        expect(triggeredAt.length).toBeLessThanOrEqual(1);

        // Property 2: fires iff an eligible run exists, and at its first end.
        const expectedIndex = firstTriggerIndex(sequence, threshold);
        if (expectedIndex === -1) {
          expect(triggeredAt).toEqual([]);
          expect(alreadyTriggered).toBe(false);
        } else {
          expect(triggeredAt).toEqual([expectedIndex]);
          expect(alreadyTriggered).toBe(true);
        }
      }),
      assertParams,
    );
  });

  it('the latch, once set, is never cleared by any later result', () => {
    fc.assert(
      fc.property(sequenceArb, thresholdArb, (sequence, threshold) => {
        let consecutiveCount = 0;
        let alreadyTriggered = false;
        let everLatched = false;

        sequence.forEach((currentExitCode) => {
          const result = evaluateWatchdog({
            currentExitCode,
            consecutiveCount,
            threshold,
            alreadyTriggered,
          });
          consecutiveCount = result.consecutiveCount;
          alreadyTriggered = result.alreadyTriggered;
          if (alreadyTriggered) {
            everLatched = true;
          }
          // Monotonic: the latch never goes back to false once it has been set.
          expect(alreadyTriggered).toBe(everLatched);
        });
      }),
      assertParams,
    );
  });
});
