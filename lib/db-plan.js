// Database-backend / multihost configuration planner (pure module).
//
// Implements the "Database backend configurator" component as a PURE,
// idempotent function. ioBroker stores its objects and its states in two
// SEPARATE databases, each with its own type / host / port (and optional name /
// password). The database type is one of `jsonl` (the ioBroker default, and
// network-capable — a multihost slave simply points its objects/states host at
// the master's `jsonl` server), `file`, or `redis`. Multihost is therefore NOT
// synonymous with Redis: a common multihost setup uses networked `jsonl`.
//
// Given the operator-supplied desired configuration (from `IOB_OBJECTSDB_*`,
// `IOB_STATESDB_*`, `IOB_MULTIHOST`) and the configuration currently applied in
// `iobroker.json`, this planner returns whether a (re-)apply is needed and the
// exact target — WITHOUT side effects (no `iobroker` CLI, no filesystem writes).
// The shell glue (`scripts/configure-db.sh`) interprets the plan.
//
// KEY RULE (Req 12.3): the planner only proposes changes for a database section
// (objects or states) that the operator EXPLICITLY configured. When the
// operator specifies nothing, the plan is a no-op and `iobroker.json` is left
// exactly as `iobroker setup first` wrote it (the local `jsonl` databases).
// This avoids corrupting the working local DB config.
//
// Idempotency (Req 12.7, 12.8): the planner compares the desired specified
// fields against the current values; identical -> no-op, any difference ->
// re-apply the specified fields.
//
// Validation (Req 12.9): each specified DB type MUST be one of jsonl|file|redis,
// each specified port MUST be an integer in 1..65535, and the multihost role (if
// set) MUST be master|slave. Invalid input yields a rejection naming the value.
//
// Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7, 12.8, 12.9

import * as validate from './validate.js';

/** Valid database backend types. @type {readonly ['jsonl','file','redis']} */
export const DB_TYPES = Object.freeze(['jsonl', 'file', 'redis']);

/** Valid multihost roles. @type {readonly ['master','slave']} */
export const MULTIHOST_ROLES = Object.freeze(['master', 'slave']);

/** Inclusive lower bound for a valid database port. @type {number} */
export const DB_PORT_MIN = 1;
/** Inclusive upper bound for a valid database port. @type {number} */
export const DB_PORT_MAX = 65535;

/**
 * Operator-supplied desired config for ONE database (objects or states). Every
 * field is optional; only fields the operator actually set are present. An
 * empty object means "operator specified nothing for this DB" -> leave as-is.
 *
 * @typedef {Object} DbSectionInput
 * @property {string} [type] - Backend type: jsonl | file | redis.
 * @property {string} [host] - Backend host.
 * @property {number|string} [port] - Backend port (numeric string accepted).
 * @property {string} [name] - Optional DB name / namespace.
 * @property {string} [pass] - Optional DB password.
 */

/**
 * @typedef {Object} DbConfigInput
 * @property {DbSectionInput} [objects] - Desired objects-DB fields (IOB_OBJECTSDB_*).
 * @property {DbSectionInput} [states]  - Desired states-DB fields (IOB_STATESDB_*).
 * @property {string} [role] - Multihost role (IOB_MULTIHOST): master | slave.
 *   Unset = standalone (no role change).
 */

/**
 * @typedef {Object} RejectedPlan
 * @property {false} valid
 * @property {unknown} value - The offending value, echoed verbatim.
 * @property {'invalid-objects-type'|'invalid-states-type'|'invalid-objects-port'|'invalid-states-port'|'invalid-role'} reason
 */

/**
 * @typedef {Object} DbPlan
 * @property {true} valid
 * @property {boolean} changed - Whether any specified field differs from current.
 * @property {DbSectionInput} objects - The objects-DB fields to apply (only the
 *   fields the operator specified; empty object = nothing to apply).
 * @property {DbSectionInput} states - The states-DB fields to apply.
 * @property {(''|'master'|'slave')} role - The multihost role to apply (''=none).
 * @property {string[]} changes - Field paths that differ (e.g. "objects.host").
 */

function reject(value, reason) {
  return { valid: false, value, reason };
}

/** True when a value is a non-empty string / defined. */
function isSet(v) {
  return v !== undefined && v !== null && !(typeof v === 'string' && v.trim() === '');
}

/** Normalize a port input to an integer, or null if not a valid integer. */
function toPort(v) {
  if (typeof v === 'number') return Number.isInteger(v) ? v : null;
  if (typeof v === 'string' && /^\d+$/.test(v.trim())) return Number(v.trim());
  return null;
}

function checkType(v) {
  return typeof v === 'string' && DB_TYPES.includes(v);
}

function checkPortValid(v) {
  if (typeof validate.validateDbPort === 'function') {
    return validate.validateDbPort(v).accepted === true;
  }
  const p = toPort(v);
  return p !== null && p >= DB_PORT_MIN && p <= DB_PORT_MAX;
}

function checkRole(v) {
  if (typeof validate.validateRole === 'function') {
    return validate.validateRole(v).accepted === true;
  }
  return typeof v === 'string' && MULTIHOST_ROLES.includes(v);
}

/**
 * Extract only the operator-specified fields of a DB section, normalized
 * (port -> integer). Unspecified fields are omitted so the plan reflects
 * exactly what the operator asked to change.
 *
 * @param {DbSectionInput} [input]
 * @returns {DbSectionInput}
 */
function specifiedSection(input = {}) {
  /** @type {DbSectionInput} */
  const out = {};
  if (isSet(input.type)) out.type = input.type;
  if (isSet(input.host)) out.host = input.host;
  if (isSet(input.port)) out.port = toPort(input.port);
  if (isSet(input.name)) out.name = input.name;
  if (isSet(input.pass)) out.pass = input.pass;
  return out;
}

/**
 * Compare a desired (specified-only) section against the current section,
 * returning the differing field names (prefixed) — only fields present in
 * `desired` are compared (we never "unset" fields the operator didn't mention).
 *
 * @param {string} prefix - "objects" | "states"
 * @param {DbSectionInput} desired
 * @param {DbSectionInput} current
 * @param {string[]} out
 */
function diffSection(prefix, desired, current = {}) {
  const changes = [];
  for (const k of Object.keys(desired)) {
    let cur = current[k];
    if (k === 'port') cur = toPort(cur);
    if (desired[k] !== cur) changes.push(`${prefix}.${k}`);
  }
  return changes;
}

/**
 * Plan the objects/states database + multihost-role configuration.
 *
 * Validates every SPECIFIED field first (Req 12.9). Only fields the operator
 * specified are considered; unspecified DB sections are left untouched
 * (Req 12.3). Produces a no-op plan when the specified fields already match the
 * current config (Req 12.7) and a re-apply plan otherwise (Req 12.8).
 *
 * @param {DbConfigInput} [desired] - Operator-specified config from IOB_* vars.
 * @param {{objects?: DbSectionInput, states?: DbSectionInput, role?: string}} [current]
 *   Current config read back from iobroker.json.
 * @returns {DbPlan | RejectedPlan}
 */
export function planDbConfig(desired = {}, current = {}) {
  const objects = specifiedSection(desired.objects);
  const states = specifiedSection(desired.states);
  const role = isSet(desired.role) ? desired.role : '';

  // --- Validate specified fields (Req 12.9) ---
  if (isSet(desired.objects?.type) && !checkType(desired.objects.type)) {
    return reject(desired.objects.type, 'invalid-objects-type');
  }
  if (isSet(desired.states?.type) && !checkType(desired.states.type)) {
    return reject(desired.states.type, 'invalid-states-type');
  }
  if (isSet(desired.objects?.port) && !checkPortValid(desired.objects.port)) {
    return reject(desired.objects.port, 'invalid-objects-port');
  }
  if (isSet(desired.states?.port) && !checkPortValid(desired.states.port)) {
    return reject(desired.states.port, 'invalid-states-port');
  }
  if (role !== '' && !checkRole(role)) {
    return reject(role, 'invalid-role');
  }

  // --- Diff specified fields against current ---
  const curObjects = current.objects ?? {};
  const curStates = current.states ?? {};
  const changes = [
    ...diffSection('objects', objects, curObjects),
    ...diffSection('states', states, curStates),
  ];
  const curRole = typeof current.role === 'string' ? current.role : '';
  if (role !== '' && role !== curRole) {
    changes.push('role');
  }

  return {
    valid: true,
    changed: changes.length > 0,
    objects,
    states,
    role,
    changes,
  };
}
