// Feature: rootless-iobroker-container-image, Property 2: Node major version is derived only from a valid integer Build_Config `nodeMajor` field, never falling back
//
// Property-based test for Property 2 (design.md): deriving the Node.js major
// version from the raw `nodeMajor` value yields exactly that integer
// when the value is a valid integer, and fails with a NodeMajorDerivationError
// (producing no derived value — never a system-default fallback) when the value
// is missing, empty, whitespace-only, or not a valid integer.
//
// Validates: Requirements 5.4, 5.5

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import { deriveNodeMajor, NodeMajorDerivationError } from '../lib/node-major.js';

// A raw value that is a valid integer major version and the exact integer it
// must derive to. Covers integer numbers and (possibly whitespace-padded)
// base-10 integer strings — the two forms accepted by deriveNodeMajor.
const validCase = fc
  .integer({ min: -1000, max: 100000 })
  .chain((n) =>
    fc.oneof(
      // Real integer number, e.g. 22
      fc.constant({ raw: n, expected: n }),
      // Base-10 integer string, e.g. "22"
      fc.constant({ raw: String(n), expected: n }),
      // Integer string with surrounding whitespace, e.g. "  22 "
      fc
        .tuple(
          fc.stringOf(fc.constantFrom(' ', '\t', '\n', '\r'), { maxLength: 4 }),
          fc.stringOf(fc.constantFrom(' ', '\t', '\n', '\r'), { maxLength: 4 }),
        )
        .map(([lead, trail]) => ({ raw: `${lead}${n}${trail}`, expected: n })),
    ),
  );

// Raw values that must NEVER derive to a value: absent field, empty string,
// whitespace-only strings, and non-numeric / non-integer strings.
const invalidRaw = fc.oneof(
  // Absent field (readNodeMajor returns undefined for a missing field).
  fc.constant(undefined),
  // Empty string.
  fc.constant(''),
  // Whitespace-only strings.
  fc
    .stringOf(fc.constantFrom(' ', '\t', '\n', '\r'), { minLength: 1, maxLength: 8 }),
  // Non-numeric strings (contain at least one non-digit, non-sign character and
  // are not a bare integer). Filter guards against fast-check producing a
  // coincidental valid integer string.
  fc
    .string({ minLength: 1 })
    .filter((s) => !/^[+-]?\d+$/.test(s.trim()) && s.trim().length > 0),
  // Decimal / non-integer numeric strings, e.g. "22.5", "1e3", "0x10".
  fc.constantFrom('22.5', '1e3', '0x10', '1.0', '.5', '+', '-', '3.14', 'NaN', 'Infinity'),
);

describe('Property 2: Node major derivation from a valid integer, never falling back', () => {
  it('returns exactly the integer for any valid integer value', () => {
    fc.assert(
      fc.property(validCase, ({ raw, expected }) => {
        expect(deriveNodeMajor(raw)).toBe(expected);
      }),
      assertParams,
    );
  });

  it('throws and yields no derived value for missing/empty/whitespace/non-integer values', () => {
    fc.assert(
      fc.property(invalidRaw, (raw) => {
        let derived;
        let thrown;
        try {
          derived = deriveNodeMajor(raw);
        } catch (err) {
          thrown = err;
        }
        // No derived value must ever be produced (no fallback).
        expect(derived).toBeUndefined();
        // It must fail with the dedicated derivation error naming the problem.
        expect(thrown).toBeInstanceOf(NodeMajorDerivationError);
        // The error carries the offending raw value for reporting.
        expect(thrown.rawValue).toBe(raw);
      }),
      assertParams,
    );
  });
});
