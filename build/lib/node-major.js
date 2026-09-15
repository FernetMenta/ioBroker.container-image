// Node.js major version derivation.
//
// This module derives the integer Node.js major version from the `nodeMajor`
// field of the maintainer-owned Build_Config (`package.json` `containerImage`).
// It is the single place that validates that value and turns it into an integer
// major version.
//
// The derivation is intentionally strict and NEVER falls back to a system
// default: a missing field, an empty string, a whitespace-only string, or any
// non-integer value all fail with an error that names the problem and produce
// no derived value. This mirrors the build-time contract that the container
// build must fail immediately rather than silently install some default Node
// version.
//
// This module does NOT read the file itself — it consumes the raw value
// surfaced by `lib/build-config.js` (`readNodeMajor`).
//
// Requirements:
// - 5.4: Read the Node.js major version from the integer value of the
//   `nodeMajor` field of the Build_Config.
// - 5.5: If `nodeMajor` is missing, empty, or not a valid integer, fail with an
//   error and no derived value; never fall back to a system default.

import { NODE_MAJOR_FIELD, readNodeMajor } from './build-config.js';

/**
 * Error thrown when the `nodeMajor` value cannot be derived into a valid
 * integer Node.js major version. Carries the offending raw value so
 * callers/logs can report exactly what was rejected.
 */
export class NodeMajorDerivationError extends Error {
  /**
   * @param {string} message - Human-readable description naming the problem.
   * @param {unknown} rawValue - The rejected raw `nodeMajor` value.
   */
  constructor(message, rawValue) {
    super(message);
    this.name = 'NodeMajorDerivationError';
    /** @type {unknown} */
    this.rawValue = rawValue;
  }
}

/**
 * Determine whether a raw value represents a valid integer Node.js major
 * version, without side effects. A value is valid iff:
 * - it is a JavaScript integer (e.g. `22`), or
 * - it is a string whose trimmed form is a base-10 integer (e.g. `"22"`).
 *
 * Empty strings, whitespace-only strings, decimals, hex, `NaN`/`Infinity`,
 * booleans, `null`, `undefined`, objects, and arrays are all invalid.
 *
 * @param {unknown} rawValue - The raw `nodeMajor` value.
 * @returns {boolean} True iff a valid integer major version can be derived.
 */
export function isValidNodeMajor(rawValue) {
  return parseNodeMajor(rawValue) !== null;
}

/**
 * Attempt to parse a raw `nodeMajor` value into an integer major version.
 * Returns `null` (never a fallback) when the value is not a valid integer.
 * This is the shared, side-effect-free core used by both
 * {@link isValidNodeMajor} and {@link deriveNodeMajor}.
 *
 * @param {unknown} rawValue - The raw `nodeMajor` value.
 * @returns {number | null} The integer major version, or `null` if invalid.
 */
function parseNodeMajor(rawValue) {
  // Accept a real integer number directly (e.g. package.json with `22`).
  if (typeof rawValue === 'number') {
    return Number.isInteger(rawValue) ? rawValue : null;
  }

  // Accept a string that, once trimmed, is a base-10 integer (e.g. `"22"`,
  // `" 22 "`). Reject empty/whitespace-only strings, decimals, signs with no
  // digits, and anything with trailing non-digit characters.
  if (typeof rawValue === 'string') {
    const trimmed = rawValue.trim();
    if (trimmed.length === 0) {
      return null; // empty or whitespace-only
    }
    // Strict integer form: optional leading '+'/'-', then digits only.
    if (!/^[+-]?\d+$/.test(trimmed)) {
      return null;
    }
    const parsed = Number(trimmed);
    return Number.isInteger(parsed) ? parsed : null;
  }

  // Everything else (boolean, null, undefined, object, array, bigint, ...) is
  // not a valid integer major version.
  return null;
}

/**
 * Derive the integer Node.js major version from a raw `nodeMajor` value.
 *
 * Returns the integer major version iff the value is a valid integer.
 * Otherwise throws a {@link NodeMajorDerivationError} naming the problem and
 * produces no derived value — it NEVER falls back to a system default.
 *
 * @param {unknown} rawValue - The raw `nodeMajor` value (typically the result
 *   of {@link readNodeMajor}).
 * @returns {number} The derived integer Node.js major version.
 * @throws {NodeMajorDerivationError} If the value is missing, empty,
 *   whitespace-only, or not a valid integer.
 */
export function deriveNodeMajor(rawValue) {
  const parsed = parseNodeMajor(rawValue);
  if (parsed !== null) {
    return parsed;
  }

  const field = NODE_MAJOR_FIELD;
  let reason;
  if (rawValue === undefined || rawValue === null) {
    reason = `field \`${field}\` is missing`;
  } else if (typeof rawValue === 'string' && rawValue.trim().length === 0) {
    reason =
      rawValue.length === 0
        ? `field \`${field}\` is empty`
        : `field \`${field}\` is whitespace-only`;
  } else {
    reason = `field \`${field}\` is not a valid integer (got ${JSON.stringify(rawValue)})`;
  }

  throw new NodeMajorDerivationError(
    `Cannot derive Node.js major version: ${reason}. ` +
      `Refusing to fall back to a system default.`,
    rawValue,
  );
}

/**
 * Convenience derivation directly from a parsed `package.json` object: reads
 * the raw `nodeMajor` value from the `containerImage` Build_Config via
 * {@link readNodeMajor} and derives the integer major version with the same
 * strict, no-fallback rules as {@link deriveNodeMajor}.
 *
 * @param {Record<string, unknown>} pkg - Parsed package.json object.
 * @returns {number} The derived integer Node.js major version.
 * @throws {NodeMajorDerivationError} If the value is missing, empty,
 *   whitespace-only, or not a valid integer.
 */
export function deriveNodeMajorFromPackageJson(pkg) {
  return deriveNodeMajor(readNodeMajor(pkg));
}
