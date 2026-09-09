// Property test for the initial-snapshot default resolver (task 4.2).
//
// Feature: rootless-iobroker-container-image, Property 9: Defaults are resolved from the initial captured state only
//
// Property 9: Defaults are resolved from the initial captured state only.
//
// For any initial environment snapshot and any subsequent mutations applied
// after the snapshot, each variable with a defined default resolves to its
// snapshot value when set in the snapshot, or to its default when unset in the
// snapshot, and mutations applied after the snapshot are ignored.
//
// Validates: Requirements 10.4

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import {
  DEFAULT_TABLE,
  DEFAULTED_VARIABLES,
  resolveDefault,
  resolveDefaults,
} from '../lib/defaults.js';

// Names the generators may draw keys from: every defaulted variable plus a few
// unrelated names, so snapshots and mutation maps cover both defaulted keys and
// noise that must not affect resolution of the defaulted set.
const CANDIDATE_KEYS = [...DEFAULTED_VARIABLES, 'PATH', 'HOME', 'FOO', 'SETUID', 'SETGID'];

// A key generator constrained to the candidate space so dictionaries stay
// focused on relevant variables rather than arbitrary unlikely strings.
const keyArb = fc.constantFrom(...CANDIDATE_KEYS);

// Environment values are always strings; include the empty string because the
// resolver treats it as an explicitly-provided (set) value.
const valueArb = fc.string();

// A snapshot is a dictionary of env keys to string values (the captured state).
const snapshotArb = fc.dictionary(keyArb, valueArb);

// A separate mutation map applied AFTER the snapshot is captured. It may add,
// overwrite, or clear keys; clearing is modeled with a null/undefined value.
const mutationArb = fc.dictionary(keyArb, fc.oneof(fc.string(), fc.constant(null), fc.constant(undefined)));

/**
 * Compute the expected resolved value for a single defaulted variable from the
 * snapshot ALONE. Mirrors the resolver's set/unset semantics: a key present
 * with a non-null, non-undefined value (including the empty string) is "set".
 *
 * @param {Record<string, unknown>} snapshot
 * @param {string} name
 * @returns {string}
 */
function expectedFromSnapshot(snapshot, name) {
  const set =
    Object.prototype.hasOwnProperty.call(snapshot, name) &&
    snapshot[name] !== undefined &&
    snapshot[name] !== null;
  return set ? snapshot[name] : DEFAULT_TABLE[name];
}

/**
 * Apply a mutation map to a copy of the snapshot, simulating the live
 * environment being mutated after the snapshot was captured.
 *
 * @param {Record<string, unknown>} snapshot
 * @param {Record<string, unknown>} mutations
 * @returns {Record<string, unknown>}
 */
function applyMutations(snapshot, mutations) {
  const live = { ...snapshot };
  for (const [key, value] of Object.entries(mutations)) {
    if (value === undefined || value === null) {
      delete live[key];
    } else {
      live[key] = value;
    }
  }
  return live;
}

describe('Property 9: defaults are resolved from the initial captured state only', () => {
  it('resolves each defaulted variable to its snapshot value when set, else the encoded default', () => {
    fc.assert(
      fc.property(snapshotArb, (snapshot) => {
        const resolved = resolveDefaults(snapshot);
        for (const name of DEFAULTED_VARIABLES) {
          expect(resolved[name]).toBe(expectedFromSnapshot(snapshot, name));
          // resolveDefault must agree with resolveDefaults for the same input.
          expect(resolveDefault(snapshot, name)).toBe(expectedFromSnapshot(snapshot, name));
        }
      }),
      assertParams,
    );
  });

  it('ignores mutations applied after the snapshot was captured', () => {
    fc.assert(
      fc.property(snapshotArb, mutationArb, (snapshot, mutations) => {
        // Resolve against the captured snapshot.
        const resolvedFromSnapshot = resolveDefaults(snapshot);

        // Mutate a copy of the live env AFTER capturing; the snapshot object
        // itself is untouched, exactly as in the entrypoint pipeline.
        applyMutations(snapshot, mutations);

        // Re-resolving against the same, unmodified snapshot yields identical
        // results regardless of what happened to the live environment.
        const resolvedAgain = resolveDefaults(snapshot);
        for (const name of DEFAULTED_VARIABLES) {
          expect(resolvedAgain[name]).toBe(resolvedFromSnapshot[name]);
          expect(resolvedAgain[name]).toBe(expectedFromSnapshot(snapshot, name));
        }
      }),
      assertParams,
    );
  });
});
