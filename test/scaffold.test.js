// Scaffold smoke test (task 1.1).
//
// Verifies the test framework runs, fast-check is wired up, property tests
// execute at numRuns: 100, and the Build_Config reader exposes the fields the
// build knobs are read from. This is a foundation check, not a feature test.

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams, PROPERTY_TEST_RUNS } from './helpers/fast-check-config.js';
import {
  BUILD_CONFIG_KEY,
  NODE_MAJOR_FIELD,
  DEBIAN_CODENAME_FIELD,
  readBuildConfig,
  readNodeMajor,
  readDebianCodename,
} from '../lib/build-config.js';

describe('test tooling scaffold', () => {
  it('runs the unit test framework', () => {
    expect(1 + 1).toBe(2);
  });

  it('runs fast-check property tests at numRuns: 100', () => {
    expect(PROPERTY_TEST_RUNS).toBe(100);
    expect(assertParams.numRuns).toBe(100);

    let runs = 0;
    // Property: for any two non-negative integers, addition is commutative.
    fc.assert(
      fc.property(fc.nat(), fc.nat(), (a, b) => {
        runs += 1;
        return a + b === b + a;
      }),
      assertParams,
    );
    expect(runs).toBeGreaterThanOrEqual(100);
  });
});

describe('Build_Config reader utility', () => {
  it('reads the build knobs from the package.json containerImage key', () => {
    expect(BUILD_CONFIG_KEY).toBe('containerImage');
    expect(NODE_MAJOR_FIELD).toBe('nodeMajor');
    expect(DEBIAN_CODENAME_FIELD).toBe('debianCodename');
  });

  it('extracts the containerImage build-config object', () => {
    const pkg = { containerImage: { nodeMajor: 22, debianCodename: 'trixie' } };
    expect(readBuildConfig(pkg)).toEqual({ nodeMajor: 22, debianCodename: 'trixie' });
    expect(readBuildConfig({})).toBeUndefined();
  });

  it('reads the nodeMajor and debianCodename fields from a parsed package.json', () => {
    const pkg = { containerImage: { nodeMajor: 22, debianCodename: 'trixie' } };
    expect(readNodeMajor(pkg)).toBe(22);
    expect(readDebianCodename(pkg)).toBe('trixie');
    expect(readNodeMajor({})).toBeUndefined();
    expect(readDebianCodename({})).toBeUndefined();
  });
});
