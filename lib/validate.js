// Configuration validation logic (pure module).
//
// This module contains pure decision logic used by the entrypoint to validate
// operator-supplied configuration BEFORE the Iobroker_Runtime is started. Each
// validator returns a structured result (accepted / rejected) rather than
// throwing, so callers can decide how to surface the failure (the entrypoint
// emits an error naming the invalid value and exits non-zero without starting
// js-controller).
//
// This file implements the database backend port, database type, and multihost
// role validators (task 2.3).
// They share the `accept`/`reject` helpers and the structured result shape so
// callers (the entrypoint and `lib/db-plan.js`) can treat them uniformly.
//
// (UID/GID range validation was removed: the runtime user is selected by the
// container runtime's `--user` / `runAsUser`, not by an in-image variable, so a
// non-root entrypoint cannot honor a UID/GID env var — validating one would be
// misleading. See design: Environment variables.)
//
// Requirements: 12.9.

/**
 * A successful validation result. `value` carries the validated value: the
 * parsed integer for Redis port validation, or the role string for multihost
 * role validation.
 * @typedef {{ accepted: true, value: number | string }} AcceptedResult
 */

/**
 * A failed validation result. `value` echoes back the offending input exactly
 * as supplied so the caller can name it in an error message. `reason` is a
 * short machine-friendly code describing why validation failed.
 * @typedef {{ accepted: false, value: unknown, reason: string }} RejectedResult
 */

/**
 * @typedef {AcceptedResult | RejectedResult} ValidationResult
 */

/**
 * Build an accepted result.
 * @param {number | string} value - The validated value (in-range integer or
 *   validated role string).
 * @returns {AcceptedResult}
 */
function accept(value) {
  return { accepted: true, value };
}

/**
 * Build a rejected result that names the invalid value.
 * @param {unknown} value - The offending input, echoed back verbatim.
 * @param {string} reason - Short code describing the failure.
 * @returns {RejectedResult}
 */
function reject(value, reason) {
  return { accepted: false, value, reason };
}


/**
 * Inclusive lower bound for a valid database backend port.
 * @type {number}
 */
export const DB_PORT_MIN = 1;

/**
 * Inclusive upper bound for a valid database backend port.
 * @type {number}
 */
export const DB_PORT_MAX = 65535;

/**
 * The valid multihost roles (Req 12.9).
 * @type {readonly ['master', 'slave']}
 */
export const MULTIHOST_ROLES = Object.freeze(['master', 'slave']);

/**
 * Validate a database backend port (objects or states DB).
 *
 * A value is accepted if and only if it denotes an integer within the closed
 * range {@link DB_PORT_MIN}–{@link DB_PORT_MAX} (1–65535). This validator
 * accepts a numeric string, since
 * the DB port is read from the environment (always a string) and callers
 * expect the parsed integer back. A non-empty string that parses to an in-range
 * integer is accepted and the accepted result carries the parsed number; any
 * value that is not such an integer (floats, `NaN`, `Infinity`, non-numeric or
 * empty strings, `null`, `undefined`, booleans, objects) or an integer outside
 * the range is rejected, and the rejection names the offending value exactly as
 * supplied.
 *
 * @param {unknown} value - The candidate database backend port.
 * @returns {ValidationResult} An accepted result carrying the integer port, or
 *   a rejected result naming the invalid value.
 */
export function validateDbPort(value) {
  let parsed = value;
  if (typeof value === 'string') {
    if (value.trim() === '') {
      return reject(value, 'not-an-integer');
    }
    parsed = Number(value);
  }

  if (typeof parsed !== 'number' || !Number.isInteger(parsed)) {
    return reject(value, 'not-an-integer');
  }

  if (parsed < DB_PORT_MIN || parsed > DB_PORT_MAX) {
    return reject(value, 'out-of-range');
  }

  return accept(parsed);
}

/**
 * Validate a multihost role.
 *
 * A value is accepted if and only if it is one of the strings in
 * {@link MULTIHOST_ROLES} (`'master'` or `'slave'`). Any other value (a
 * differently-cased or unknown string, `null`, `undefined`, numbers, booleans,
 * objects) is rejected, and the rejection names the offending value exactly as
 * supplied. The accepted result echoes the validated role string back as its
 * `value`.
 *
 * @param {unknown} value - The candidate multihost role.
 * @returns {ValidationResult} An accepted result carrying the role string, or a
 *   rejected result naming the invalid value.
 */
export function validateRole(value) {
  if (typeof value !== 'string' || !MULTIHOST_ROLES.includes(value)) {
    return reject(value, 'invalid-role');
  }

  return accept(value);
}

/**
 * The valid database backend types (Req 12.2).
 * @type {readonly ['jsonl', 'file', 'redis']}
 */
export const DB_TYPES = Object.freeze(['jsonl', 'file', 'redis']);

/**
 * Validate a database backend type.
 *
 * A value is accepted if and only if it is one of {@link DB_TYPES}
 * (`'jsonl'`, `'file'`, `'redis'`). Any other value is rejected, and the
 * rejection names the offending value.
 *
 * @param {unknown} value - The candidate database type.
 * @returns {ValidationResult}
 */
export function validateDbType(value) {
  if (typeof value !== 'string' || !DB_TYPES.includes(value)) {
    return reject(value, 'invalid-db-type');
  }
  return accept(value);
}
