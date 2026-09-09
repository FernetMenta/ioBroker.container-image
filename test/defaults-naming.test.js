// Unit test for the environment variable naming convention (task 4.3).
//
// Verifies that the retained environment variable set exported from
// `lib/defaults.js` follows the naming rules from the design's Data Model:
//   - Every ioBroker-specific variable is prefixed with `IOB_`.
//   - The conventional variables TZ and LANG are present and are NOT prefixed.
//   - The removed variables SETUID and SETGID are absent from the set.
//
// Requirements:
//   10.1 - Prefix every ioBroker-specific environment variable with `IOB_`.
//   10.2 - Keep conventional non-ioBroker variables (including TZ and LANG)
//          under their conventional names without the `IOB_` prefix.
//   10.6 - Exclude the SETUID variable from the environment variable set.
//   10.7 - Exclude the SETGID variable from the environment variable set.

import { describe, it, expect } from 'vitest';
import { DEFAULT_TABLE, DEFAULTED_VARIABLES } from '../lib/defaults.js';

// The conventional (non-ioBroker) variables that must stay unprefixed. Any
// variable in the set that is not one of these is considered ioBroker-specific
// and must therefore carry the `IOB_` prefix.
const CONVENTIONAL_VARIABLES = ['TZ', 'LANG'];

describe('environment variable naming convention', () => {
  it('prefixes every ioBroker-specific variable with IOB_ (Req 10.1)', () => {
    const iobSpecific = DEFAULTED_VARIABLES.filter((name) => !CONVENTIONAL_VARIABLES.includes(name));

    // There must be at least one ioBroker-specific variable, otherwise the
    // assertion below would pass vacuously.
    expect(iobSpecific.length).toBeGreaterThan(0);

    for (const name of iobSpecific) {
      expect(name.startsWith('IOB_')).toBe(true);
    }
  });

  it('keeps TZ and LANG present and unprefixed (Req 10.2)', () => {
    for (const name of CONVENTIONAL_VARIABLES) {
      expect(DEFAULTED_VARIABLES).toContain(name);
      expect(name.startsWith('IOB_')).toBe(false);
    }
  });

  it('excludes SETUID from the environment variable set (Req 10.6)', () => {
    expect(DEFAULTED_VARIABLES).not.toContain('SETUID');
    expect(Object.prototype.hasOwnProperty.call(DEFAULT_TABLE, 'SETUID')).toBe(false);
  });

  it('excludes SETGID from the environment variable set (Req 10.7)', () => {
    expect(DEFAULTED_VARIABLES).not.toContain('SETGID');
    expect(Object.prototype.hasOwnProperty.call(DEFAULT_TABLE, 'SETGID')).toBe(false);
  });
});
