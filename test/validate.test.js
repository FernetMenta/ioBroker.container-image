// Unit tests for validator edge cases (task 2.5).
//
// These example-based tests complement the property tests (tasks 2.2 and 2.4)
// by pinning down the exact boundary behaviour of the validators in
// `lib/validate.js`: the inclusive range endpoints, the off-by-one rejections
// just outside those endpoints, and the handling of non-integer / non-string
// inputs. Every rejection is asserted to echo back the offending value so the
// entrypoint can name it in an error message.
//
// Requirements: 12.9 (redis port + multihost role validation).

import { describe, it, expect } from 'vitest';
import {
  validateDbPort,
  validateRole,
  validateDbType,
  DB_PORT_MIN,
  DB_PORT_MAX,
} from '../lib/validate.js';

describe('validateDbPort edge cases', () => {
  it('accepts the exact lower boundary 1', () => {
    const result = validateDbPort(DB_PORT_MIN);
    expect(result).toEqual({ accepted: true, value: 1 });
  });

  it('accepts the exact upper boundary 65535', () => {
    const result = validateDbPort(DB_PORT_MAX);
    expect(result).toEqual({ accepted: true, value: 65535 });
  });

  it('accepts the numeric string form of the lower boundary "1"', () => {
    const result = validateDbPort('1');
    expect(result).toEqual({ accepted: true, value: 1 });
  });

  it('accepts the numeric string form of the upper boundary "65535"', () => {
    const result = validateDbPort('65535');
    expect(result).toEqual({ accepted: true, value: 65535 });
  });

  it('accepts a mid-range numeric string, returning the parsed integer', () => {
    const result = validateDbPort('6379');
    expect(result).toEqual({ accepted: true, value: 6379 });
  });

  it('rejects the off-by-one below the lower boundary (0), naming the value', () => {
    const result = validateDbPort(0);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(0);
    expect(result.reason).toBe('out-of-range');
  });

  it('rejects the string off-by-one below the lower boundary ("0"), naming the value', () => {
    const result = validateDbPort('0');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('0');
    expect(result.reason).toBe('out-of-range');
  });

  it('rejects the off-by-one above the upper boundary (65536), naming the value', () => {
    const result = validateDbPort(65536);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(65536);
    expect(result.reason).toBe('out-of-range');
  });

  it('rejects the string off-by-one above the upper boundary ("65536"), naming the value', () => {
    const result = validateDbPort('65536');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('65536');
    expect(result.reason).toBe('out-of-range');
  });

  it('rejects a float (non-integer), naming the value', () => {
    const result = validateDbPort(6379.5);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(6379.5);
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects a non-integer numeric string ("6379.5"), naming the value', () => {
    const result = validateDbPort('6379.5');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('6379.5');
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects a non-numeric string, naming the value', () => {
    const result = validateDbPort('abc');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('abc');
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects an empty string, naming the value', () => {
    const result = validateDbPort('');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('');
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects a whitespace-only string, naming the value', () => {
    const result = validateDbPort('   ');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('   ');
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects NaN', () => {
    const result = validateDbPort(NaN);
    expect(result.accepted).toBe(false);
    expect(Number.isNaN(result.value)).toBe(true);
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects Infinity', () => {
    const result = validateDbPort(Infinity);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(Infinity);
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects null', () => {
    const result = validateDbPort(null);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(null);
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects undefined', () => {
    const result = validateDbPort(undefined);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(undefined);
    expect(result.reason).toBe('not-an-integer');
  });

  it('rejects a boolean', () => {
    const result = validateDbPort(true);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(true);
    expect(result.reason).toBe('not-an-integer');
  });
});

describe('validateRole edge cases', () => {
  it("accepts 'master'", () => {
    const result = validateRole('master');
    expect(result).toEqual({ accepted: true, value: 'master' });
  });

  it("accepts 'slave'", () => {
    const result = validateRole('slave');
    expect(result).toEqual({ accepted: true, value: 'slave' });
  });

  it('rejects an unknown role string, naming the value', () => {
    const result = validateRole('primary');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('primary');
    expect(result.reason).toBe('invalid-role');
  });

  it("rejects a case variant ('Master'), naming the value", () => {
    const result = validateRole('Master');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('Master');
    expect(result.reason).toBe('invalid-role');
  });

  it("rejects an uppercase variant ('SLAVE'), naming the value", () => {
    const result = validateRole('SLAVE');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('SLAVE');
    expect(result.reason).toBe('invalid-role');
  });

  it('rejects an empty string, naming the value', () => {
    const result = validateRole('');
    expect(result.accepted).toBe(false);
    expect(result.value).toBe('');
    expect(result.reason).toBe('invalid-role');
  });

  it('rejects a number', () => {
    const result = validateRole(0);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(0);
    expect(result.reason).toBe('invalid-role');
  });

  it('rejects null', () => {
    const result = validateRole(null);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(null);
    expect(result.reason).toBe('invalid-role');
  });

  it('rejects undefined', () => {
    const result = validateRole(undefined);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(undefined);
    expect(result.reason).toBe('invalid-role');
  });

  it('rejects a boolean', () => {
    const result = validateRole(true);
    expect(result.accepted).toBe(false);
    expect(result.value).toBe(true);
    expect(result.reason).toBe('invalid-role');
  });
});

describe('validateDbType edge cases', () => {
  it("accepts 'jsonl'", () => {
    expect(validateDbType('jsonl')).toEqual({ accepted: true, value: 'jsonl' });
  });
  it("accepts 'file'", () => {
    expect(validateDbType('file')).toEqual({ accepted: true, value: 'file' });
  });
  it("accepts 'redis'", () => {
    expect(validateDbType('redis')).toEqual({ accepted: true, value: 'redis' });
  });
  it('rejects an unknown type, naming the value', () => {
    const r = validateDbType('mongo');
    expect(r.accepted).toBe(false);
    expect(r.value).toBe('mongo');
    expect(r.reason).toBe('invalid-db-type');
  });
  it('rejects non-strings', () => {
    for (const v of [0, null, undefined, true, {}]) {
      expect(validateDbType(v).accepted).toBe(false);
    }
  });
});
