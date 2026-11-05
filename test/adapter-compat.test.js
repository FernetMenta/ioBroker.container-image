// Unit tests for the admin / js-controller compatibility resolver.
//
// Covers the cases the task enumerates:
//   * a controller that is older than the admin requirement -> incompatible,
//     and the resolver falls back to an older, compatible admin version;
//   * an adapter version with NO js-controller requirement -> always compatible;
//   * multiple dependency entries and the js-controller key found among them;
//   * a controller version that is itself a prerelease;
//   * malformed / missing ranges -> UNKNOWN (skip), never a silent compatible;
//   * semver sorting picks the numerically-newest version (8.3.10 > 8.3.5).

import { describe, it, expect } from 'vitest';
import {
  COMPAT_RESULTS,
  parseVersion,
  compareVersions,
  isCompatible,
  extractControllerRange,
  resolveCompatibleVersion,
} from '../lib/adapter-compat.js';

describe('parseVersion / compareVersions', () => {
  it('parses a plain release', () => {
    expect(parseVersion('7.2.5')).toMatchObject({ major: 7, minor: 2, patch: 5, prerelease: [] });
  });

  it('tolerates a leading v and strips build metadata', () => {
    expect(parseVersion('v8.3.5+build.9')).toMatchObject({ major: 8, minor: 3, patch: 5 });
  });

  it('parses a prerelease into ordered identifiers', () => {
    expect(parseVersion('8.4.0-beta.1').prerelease).toEqual(['beta', 1]);
  });

  it('returns null for a non-numeric core', () => {
    expect(parseVersion('garbage')).toBeNull();
    expect(parseVersion('')).toBeNull();
  });

  it('orders numeric components correctly (8.3.10 > 8.3.5)', () => {
    expect(compareVersions(parseVersion('8.3.10'), parseVersion('8.3.5'))).toBe(1);
  });

  it('ranks a release above its prerelease', () => {
    expect(compareVersions(parseVersion('8.4.0'), parseVersion('8.4.0-beta.1'))).toBe(1);
  });
});

describe('isCompatible — the motivating case (admin 8.3.5 needs js-controller >=7.2.5)', () => {
  it('7.2.2 does NOT satisfy >=7.2.5', () => {
    expect(isCompatible('7.2.2', '>=7.2.5')).toBe(COMPAT_RESULTS.INCOMPATIBLE);
  });

  it('7.2.5 satisfies >=7.2.5', () => {
    expect(isCompatible('7.2.5', '>=7.2.5')).toBe(COMPAT_RESULTS.COMPATIBLE);
  });

  it('7.3.0 satisfies >=7.2.5', () => {
    expect(isCompatible('7.3.0', '>=7.2.5')).toBe(COMPAT_RESULTS.COMPATIBLE);
  });
});

describe('isCompatible — no requirement is always compatible', () => {
  it('empty / null / undefined range -> compatible', () => {
    expect(isCompatible('7.2.2', '')).toBe(COMPAT_RESULTS.COMPATIBLE);
    expect(isCompatible('7.2.2', null)).toBe(COMPAT_RESULTS.COMPATIBLE);
    expect(isCompatible('7.2.2', undefined)).toBe(COMPAT_RESULTS.COMPATIBLE);
  });
});

describe('isCompatible — range flavours', () => {
  it('supports conjunctions (>=7.0.0 <8.0.0)', () => {
    expect(isCompatible('7.5.0', '>=7.0.0 <8.0.0')).toBe(COMPAT_RESULTS.COMPATIBLE);
    expect(isCompatible('8.0.0', '>=7.0.0 <8.0.0')).toBe(COMPAT_RESULTS.INCOMPATIBLE);
  });

  it('supports || unions', () => {
    expect(isCompatible('6.0.5', '^5.0.0 || ^6.0.0')).toBe(COMPAT_RESULTS.COMPATIBLE);
    expect(isCompatible('7.0.0', '^5.0.0 || ^6.0.0')).toBe(COMPAT_RESULTS.INCOMPATIBLE);
  });

  it('supports caret ranges', () => {
    expect(isCompatible('7.9.9', '^7.2.5')).toBe(COMPAT_RESULTS.COMPATIBLE);
    expect(isCompatible('8.0.0', '^7.2.5')).toBe(COMPAT_RESULTS.INCOMPATIBLE);
  });

  it('supports tilde ranges', () => {
    expect(isCompatible('7.2.9', '~7.2.5')).toBe(COMPAT_RESULTS.COMPATIBLE);
    expect(isCompatible('7.3.0', '~7.2.5')).toBe(COMPAT_RESULTS.INCOMPATIBLE);
  });

  it('supports x-ranges / bare partials', () => {
    expect(isCompatible('7.4.1', '7.x')).toBe(COMPAT_RESULTS.COMPATIBLE);
    expect(isCompatible('8.0.0', '7.x')).toBe(COMPAT_RESULTS.INCOMPATIBLE);
    expect(isCompatible('7.2.9', '7.2')).toBe(COMPAT_RESULTS.COMPATIBLE);
  });

  it('supports hyphen ranges', () => {
    expect(isCompatible('7.5.0', '7.0.0 - 7.9.9')).toBe(COMPAT_RESULTS.COMPATIBLE);
    expect(isCompatible('8.0.0', '7.0.0 - 7.9.9')).toBe(COMPAT_RESULTS.INCOMPATIBLE);
  });

  it('compares a prerelease controller version by semver precedence', () => {
    // 7.2.5-alpha.1 < 7.2.5, so it does not satisfy >=7.2.5.
    expect(isCompatible('7.2.5-alpha.1', '>=7.2.5')).toBe(COMPAT_RESULTS.INCOMPATIBLE);
    // but it does satisfy >=7.2.0.
    expect(isCompatible('7.2.5-alpha.1', '>=7.2.0')).toBe(COMPAT_RESULTS.COMPATIBLE);
  });
});

describe('isCompatible — malformed input fails closed (UNKNOWN, never silent compatible)', () => {
  it('a malformed range -> UNKNOWN', () => {
    expect(isCompatible('7.2.5', 'not-a-range!!')).toBe(COMPAT_RESULTS.UNKNOWN);
  });

  it('an unparseable controller version -> UNKNOWN', () => {
    expect(isCompatible('not-a-version', '>=7.2.5')).toBe(COMPAT_RESULTS.UNKNOWN);
  });
});

describe('extractControllerRange', () => {
  it('finds the js-controller range in an array of dependency objects', () => {
    expect(extractControllerRange([{ 'js-controller': '>=7.2.5' }, 'backitup'])).toBe('>=7.2.5');
  });

  it('scans multiple object entries for the js-controller key', () => {
    expect(extractControllerRange([{ admin: '>=6' }, { 'js-controller': '>=5.0.0' }])).toBe(
      '>=5.0.0',
    );
  });

  it('falls back to globalDependencies', () => {
    expect(extractControllerRange([], [{ 'js-controller': '>=6.0.0' }])).toBe('>=6.0.0');
  });

  it('returns null when nothing constrains js-controller', () => {
    expect(extractControllerRange(['backitup'])).toBeNull();
    expect(extractControllerRange(undefined)).toBeNull();
    expect(extractControllerRange('not-an-array')).toBeNull();
  });
});

describe('resolveCompatibleVersion — the end-to-end fresh-install decision', () => {
  it('picks the newest version the installed controller satisfies', () => {
    const candidates = [
      { version: '8.3.5', controllerRange: '>=7.2.5' }, // needs newer controller
      { version: '8.2.0', controllerRange: '>=7.0.0' }, // compatible with 7.2.2
      { version: '8.1.0', controllerRange: '>=6.0.0' },
    ];
    const res = resolveCompatibleVersion('7.2.2', candidates);
    expect(res.version).toBe('8.2.0');
  });

  it('installs the newest when it is already compatible', () => {
    const candidates = [
      { version: '8.3.5', controllerRange: '>=7.2.5' },
      { version: '8.2.0', controllerRange: '>=7.0.0' },
    ];
    expect(resolveCompatibleVersion('7.3.0', candidates).version).toBe('8.3.5');
  });

  it('treats a version with no requirement as compatible', () => {
    const candidates = [{ version: '9.0.0', controllerRange: null }];
    expect(resolveCompatibleVersion('1.0.0', candidates).version).toBe('9.0.0');
  });

  it('returns null when NOTHING is compatible (the fatal case)', () => {
    const candidates = [
      { version: '8.3.5', controllerRange: '>=7.2.5' },
      { version: '8.3.4', controllerRange: '>=7.2.5' },
    ];
    const res = resolveCompatibleVersion('7.2.2', candidates);
    expect(res.version).toBeNull();
    expect(res.evaluated.length).toBe(2);
  });

  it('skips prerelease candidates', () => {
    const candidates = [
      { version: '9.0.0-beta.1', controllerRange: '>=1.0.0' },
      { version: '8.9.0', controllerRange: '>=1.0.0' },
    ];
    expect(resolveCompatibleVersion('7.0.0', candidates).version).toBe('8.9.0');
  });

  it('sorts numerically so 8.3.10 outranks 8.3.5', () => {
    const candidates = [
      { version: '8.3.5', controllerRange: '>=1.0.0' },
      { version: '8.3.10', controllerRange: '>=1.0.0' },
    ];
    expect(resolveCompatibleVersion('7.0.0', candidates).version).toBe('8.3.10');
  });

  it('skips a candidate with an unparseable requirement rather than choosing it', () => {
    const candidates = [
      { version: '8.3.5', controllerRange: 'garbage!!' }, // UNKNOWN -> skipped
      { version: '8.2.0', controllerRange: '>=7.0.0' }, // compatible
    ];
    const res = resolveCompatibleVersion('7.2.2', candidates);
    expect(res.version).toBe('8.2.0');
    expect(res.evaluated[0]).toMatchObject({ version: '8.3.5', result: COMPAT_RESULTS.UNKNOWN });
  });
});
