// Unit tests for the npm settings manager (task 10.2).
//
// Verifies two things the runtime relies on:
//   1. The rendered `.npmrc` content contains the three required settings —
//      `audit=false`, `update-notifier=false`, `engine-strict=true`
//      (Req 11.1, 11.2, 11.3).
//   2. The fail-closed contract (Req 11.5): a correct file is accepted as-is;
//      an absent/missing file is (re)written rather than blocked; an
//      inaccessible file blocks the install; and a corrupt/malformed file — or
//      one with conflicting values for a required key — blocks the install
//      rather than falling back to default npm behavior.
//
// Requirements: 11.1, 11.2, 11.3, 11.5.

import { describe, it, expect } from 'vitest';
import {
  REQUIRED_NPMRC_MAP,
  DEFAULT_NPMRC_PATH,
  renderNpmrc,
  parseNpmrc,
  checkNpmrc,
  ensureNpmrc,
} from '../lib/npmrc.js';

describe('renderNpmrc content (Req 11.1, 11.2, 11.3)', () => {
  const content = renderNpmrc();

  it('contains audit=false (Req 11.1)', () => {
    expect(content).toContain('audit=false');
  });

  it('contains update-notifier=false (Req 11.2)', () => {
    expect(content).toContain('update-notifier=false');
  });

  it('contains engine-strict=true (Req 11.3)', () => {
    expect(content).toContain('engine-strict=true');
  });

  it('renders exactly the three required settings, one per line, newline-terminated', () => {
    expect(content).toBe('audit=false\nupdate-notifier=false\nengine-strict=true\n');
  });

  it('parses back into the required settings with no corruption', () => {
    const parsed = parseNpmrc(content);
    expect(parsed.malformed).toBe(false);
    expect(parsed.conflicts).toEqual([]);
    expect(parsed.settings).toMatchObject(REQUIRED_NPMRC_MAP);
  });
});

describe('checkNpmrc / ensureNpmrc — correct file is accepted as-is', () => {
  it('a correct .npmrc is valid and needs no action', () => {
    const input = { accessible: true, exists: true, content: renderNpmrc() };

    const check = checkNpmrc(input);
    expect(check.valid).toBe(true);
    expect(check.block).toBe(false);
    expect(check.missing).toEqual([]);
    expect(check.incorrect).toEqual([]);
    expect(check.reason).toBe('ok');

    const plan = ensureNpmrc(input);
    expect(plan.action).toBe('ok');
    expect(plan.path).toBe(DEFAULT_NPMRC_PATH);
  });

  it('extra unrelated settings do not affect validity', () => {
    const input = {
      accessible: true,
      exists: true,
      content: `${renderNpmrc()}fund=false\n# a comment\n`,
    };

    expect(checkNpmrc(input).valid).toBe(true);
    expect(ensureNpmrc(input).action).toBe('ok');
  });
});

describe('checkNpmrc / ensureNpmrc — missing/absent file is written, not blocked', () => {
  it('an absent (accessible) file plans a write, not a block', () => {
    const input = { accessible: true, exists: false };

    const check = checkNpmrc(input);
    expect(check.block).toBe(false);
    expect(check.valid).toBe(false);
    expect(check.reason).toBe('needs-write');

    const plan = ensureNpmrc(input);
    expect(plan.action).toBe('write');
    expect(plan.content).toBe(renderNpmrc());
  });

  it('a well-formed file missing a required setting plans a write, not a block', () => {
    const input = {
      accessible: true,
      exists: true,
      content: 'audit=false\nupdate-notifier=false\n',
    };

    const check = checkNpmrc(input);
    expect(check.block).toBe(false);
    expect(check.valid).toBe(false);
    expect(check.missing).toContain('engine-strict');

    expect(ensureNpmrc(input).action).toBe('write');
  });

  it('a well-formed file with an out-of-date value plans a write, not a block', () => {
    const input = {
      accessible: true,
      exists: true,
      content: 'audit=true\nupdate-notifier=false\nengine-strict=true\n',
    };

    const check = checkNpmrc(input);
    expect(check.block).toBe(false);
    expect(check.valid).toBe(false);
    expect(check.incorrect).toEqual([{ key: 'audit', expected: 'false', actual: 'true' }]);

    expect(ensureNpmrc(input).action).toBe('write');
  });
});

describe('checkNpmrc / ensureNpmrc — inaccessible file blocks install (Req 11.5)', () => {
  it('an inaccessible file blocks the adapter install', () => {
    const input = { accessible: false };

    const check = checkNpmrc(input);
    expect(check.block).toBe(true);
    expect(check.valid).toBe(false);
    expect(check.reason).toBe('inaccessible');

    expect(ensureNpmrc(input).action).toBe('block');
  });
});

describe('checkNpmrc / ensureNpmrc — corrupt file blocks install (Req 11.5)', () => {
  it('a malformed file (unparseable line) blocks the install', () => {
    const input = {
      accessible: true,
      exists: true,
      content: 'audit=false\nthis is not a setting\nengine-strict=true\n',
    };

    const check = checkNpmrc(input);
    expect(check.block).toBe(true);
    expect(check.valid).toBe(false);
    expect(check.reason).toBe('corrupt');

    expect(ensureNpmrc(input).action).toBe('block');
  });

  it('a file with conflicting values for a required key blocks the install', () => {
    const input = {
      accessible: true,
      exists: true,
      content: 'audit=false\naudit=true\nupdate-notifier=false\nengine-strict=true\n',
    };

    const check = checkNpmrc(input);
    expect(check.block).toBe(true);
    expect(check.valid).toBe(false);
    expect(check.reason).toBe('corrupt');

    expect(ensureNpmrc(input).action).toBe('block');
  });
});
