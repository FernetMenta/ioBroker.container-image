// Tests for lib/native-preflight.js: policy classification (pure), host
// candidate filtering, and an end-to-end scan against a fake node_modules tree
// containing an unloadable ".node" binary attributed to an adapter.

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  classifyBroken,
  isCandidateForHost,
  scanBrokenNativeModules,
  CORE_OWNER,
} from '../lib/native-preflight.js';

const broken = (pkg, owners) => ({ pkg, owners, error: 'boom' });

describe('classifyBroken', () => {
  const base = { enabledAdapters: ['foo'], enabledQueryOk: true };

  it('strict: everything is fatal, even unattributed', () => {
    const r = classifyBroken([broken('a', ['bar']), broken('b', [])], {
      ...base,
      policy: 'strict',
    });
    expect(r.fatal).toHaveLength(2);
    expect(r.tolerated).toHaveLength(0);
  });

  it('tolerate-all: nothing is fatal', () => {
    const r = classifyBroken([broken('a', ['foo']), broken(CORE_OWNER, [CORE_OWNER])], {
      ...base,
      policy: 'tolerate-all',
    });
    expect(r.fatal).toHaveLength(0);
    expect(r.tolerated).toHaveLength(2);
  });

  it('tolerate-no-instance: fatal only for owners with an enabled instance', () => {
    const r = classifyBroken([broken('a', ['foo']), broken('b', ['bar']), broken('c', [])], {
      ...base,
      policy: 'tolerate-no-instance',
    });
    expect(r.fatal.map((b) => b.pkg)).toEqual(['a']);
    expect(r.tolerated.map((b) => b.pkg)).toEqual(['b', 'c']);
  });

  it('tolerate-no-instance: js-controller natives are always fatal', () => {
    const r = classifyBroken([broken('diskusage', [CORE_OWNER])], {
      policy: 'tolerate-no-instance',
      enabledAdapters: [],
      enabledQueryOk: true,
    });
    expect(r.fatal).toHaveLength(1);
  });

  it('tolerate-no-instance: unknown instance state fails safe for attributed packages', () => {
    const r = classifyBroken([broken('b', ['bar']), broken('c', [])], {
      policy: 'tolerate-no-instance',
      enabledAdapters: [],
      enabledQueryOk: false,
    });
    expect(r.fatal.map((b) => b.pkg)).toEqual(['b']);
    expect(r.tolerated.map((b) => b.pkg)).toEqual(['c']);
  });
});

describe('isCandidateForHost', () => {
  it('excludes other platforms and architectures', () => {
    expect(isCandidateForHost('x/prebuilds/darwin-arm64/x.node', 'x64')).toBe(false);
    expect(isCandidateForHost('x/prebuilds/linux-arm64/x.node', 'x64')).toBe(false);
    expect(isCandidateForHost('x/prebuilds/linux-musl-x64/x.node', 'x64')).toBe(false);
    expect(isCandidateForHost('x/prebuilds/win32-x64/x.node', 'x64')).toBe(false);
  });
  it('keeps host-matching and untagged binaries', () => {
    expect(isCandidateForHost('x/prebuilds/linux-x64/node.abi137.node', 'x64')).toBe(true);
    expect(isCandidateForHost('x/prebuilds/linux-arm64/x.node', 'arm64')).toBe(true);
    expect(isCandidateForHost('x/build/Release/x.node', 'x64')).toBe(true);
  });
});

describe('scanBrokenNativeModules', () => {
  let root;
  beforeAll(() => {
    root = mkdtempSync(join(tmpdir(), 'iob-preflight-'));
    const nm = join(root, 'node_modules');
    const write = (rel, content) => {
      const p = join(nm, rel);
      mkdirSync(join(p, '..'), { recursive: true });
      writeFileSync(p, content);
    };
    // adapter -> depends on hoisted "nativedep" whose binary is not loadable
    write(
      'iobroker.foo/package.json',
      JSON.stringify({ name: 'iobroker.foo', dependencies: { wrapper: '1' } }),
    );
    write(
      'wrapper/package.json',
      JSON.stringify({ name: 'wrapper', dependencies: { nativedep: '1' } }),
    );
    write('nativedep/package.json', JSON.stringify({ name: 'nativedep' }));
    write('nativedep/build/Release/nativedep.node', 'not an ELF file');
    // foreign-platform-only package must be ignored
    write('foreign/package.json', JSON.stringify({ name: 'foreign' }));
    write('foreign/prebuilds/darwin-arm64/foreign.node', 'not an ELF file');
  });
  afterAll(() => rmSync(root, { recursive: true, force: true }));

  it('reports an unloadable native package and attributes it transitively', () => {
    const res = scanBrokenNativeModules(join(root, 'node_modules'));
    expect(res.map((b) => b.pkg)).toEqual(['nativedep']);
    expect(res[0].owners).toEqual(['foo']);
    expect(res[0].error.length).toBeGreaterThan(0);
  });

  it('skips packages the reconciler repairs itself', () => {
    expect(scanBrokenNativeModules(join(root, 'node_modules'), { skip: ['nativedep'] })).toEqual(
      [],
    );
  });
});
