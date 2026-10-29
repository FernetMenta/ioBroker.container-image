// Unit tests for the health-watchdog decision logic.
//
// Feature: in-container health watchdog (see lib/watchdog-state.js and
// scripts/health-watchdog.sh). These example-based tests pin the specific
// counting/debounce cases that the property test covers only in aggregate, so a
// regression names the exact broken case: the consecutive-unhealthy count, the
// reset-on-healthy behaviour, the fire-exactly-at-threshold trigger, and the
// fire-once latch that replaces the inert Dockerfile --retries budget.

import { describe, it, expect } from 'vitest';
import { evaluateWatchdog, WatchdogExitCode } from '../lib/watchdog-state.js';

const HEALTHY = WatchdogExitCode.HEALTHY; // 0
const UNHEALTHY = WatchdogExitCode.UNHEALTHY; // 1

/**
 * Drive a full sequence of healthcheck exit codes through the watchdog exactly
 * as the shell loop would (carrying count + latch between steps), and record on
 * which step indices `triggerRestart` fired.
 *
 * @param {number[]} sequence - Exit codes, one per watchdog cycle.
 * @param {number} threshold - Consecutive-unhealthy threshold.
 * @returns {{ triggeredAt: number[], finalCount: number, latched: boolean }}
 */
function run(sequence, threshold) {
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
  return { triggeredAt, finalCount: consecutiveCount, latched: alreadyTriggered };
}

describe('evaluateWatchdog counting and debounce', () => {
  it('a run of healthy results keeps the count at 0 and never triggers', () => {
    const { triggeredAt, finalCount, latched } = run([HEALTHY, HEALTHY, HEALTHY, HEALTHY], 3);
    expect(triggeredAt).toEqual([]);
    expect(finalCount).toBe(0);
    expect(latched).toBe(false);
  });

  it('threshold-1 consecutive unhealthy results do NOT trigger', () => {
    const { triggeredAt, finalCount } = run([UNHEALTHY, UNHEALTHY], 3);
    expect(triggeredAt).toEqual([]);
    expect(finalCount).toBe(2);
  });

  it('the threshold-th consecutive unhealthy result triggers exactly once', () => {
    const { triggeredAt } = run([UNHEALTHY, UNHEALTHY, UNHEALTHY], 3);
    expect(triggeredAt).toEqual([2]);
  });

  it('a healthy result in the middle resets the counter so a fresh full streak is needed', () => {
    // two unhealthy, then healthy (reset), then three unhealthy -> trigger only
    // on the final step.
    const { triggeredAt, finalCount } = run(
      [UNHEALTHY, UNHEALTHY, HEALTHY, UNHEALTHY, UNHEALTHY, UNHEALTHY],
      3,
    );
    expect(triggeredAt).toEqual([5]);
    expect(finalCount).toBe(3);
  });

  it('after a trigger, further unhealthy results do NOT re-trigger (fire-once latch)', () => {
    const { triggeredAt, latched } = run(
      [UNHEALTHY, UNHEALTHY, UNHEALTHY, UNHEALTHY, UNHEALTHY],
      3,
    );
    expect(triggeredAt).toEqual([2]);
    expect(latched).toBe(true);
  });

  it('threshold of 1 triggers on the first unhealthy result', () => {
    const { triggeredAt } = run([UNHEALTHY], 1);
    expect(triggeredAt).toEqual([0]);
  });

  it('an unexpected (non-0, non-1) exit code resets the streak rather than counting as unhealthy', () => {
    // 124 (a timeout-style code) is NOT exit 1, so it must reset the streak: the
    // watchdog only reacts to the healthcheck's defined unhealthy exit (1).
    const { triggeredAt, finalCount } = run([UNHEALTHY, UNHEALTHY, 124, UNHEALTHY], 3);
    expect(triggeredAt).toEqual([]);
    expect(finalCount).toBe(1);
  });
});

describe('evaluateWatchdog defensive threshold handling', () => {
  it('a threshold below 1 is clamped to 1 (first unhealthy triggers)', () => {
    const result = evaluateWatchdog({
      currentExitCode: UNHEALTHY,
      consecutiveCount: 0,
      threshold: 0,
    });
    expect(result.triggerRestart).toBe(true);
    expect(result.consecutiveCount).toBe(1);
  });

  it('a non-finite threshold is clamped to 1', () => {
    const result = evaluateWatchdog({
      currentExitCode: UNHEALTHY,
      consecutiveCount: 0,
      threshold: Number.NaN,
    });
    expect(result.triggerRestart).toBe(true);
  });

  it('a fractional threshold is floored', () => {
    // threshold 2.9 floors to 2: two consecutive unhealthy trigger.
    const { triggeredAt } = run([UNHEALTHY, UNHEALTHY], 2.9);
    expect(triggeredAt).toEqual([1]);
  });

  it('a negative/non-finite carry-in count is treated as 0', () => {
    const result = evaluateWatchdog({
      currentExitCode: UNHEALTHY,
      consecutiveCount: -5,
      threshold: 3,
    });
    expect(result.consecutiveCount).toBe(1);
    expect(result.triggerRestart).toBe(false);
  });
});
