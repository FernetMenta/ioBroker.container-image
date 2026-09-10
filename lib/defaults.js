// Initial-snapshot default resolver (pure module).
//
// The entrypoint captures a snapshot of the environment at container start.
// For every variable that has a defined default, this module resolves the
// effective value from that snapshot only: the snapshot value when the variable
// is set, otherwise the encoded default. Mutations applied to the environment
// AFTER the snapshot was captured (e.g. variables set during early startup
// phases) are ignored for default resolution.
//
// Requirements:
//   10.3 - Retain the reference-image variables covering timezone, language,
//          admin port, web port, and healthcheck-window settings.
//   10.4 - Apply a variable's default from the initial captured state when the
//          variable is unset in that state, ignoring later mutations.
//
// The default table below is the Data Model from design.md. It is the single
// source of truth for the retained environment variable set and its defaults.

/**
 * Default values for the retained environment variable set, transcribed from
 * the Data Model table in design.md. Values are strings because environment
 * variables are always strings; consumers parse/validate them as needed.
 *
 * @type {Readonly<Record<string, string>>}
 */
export const DEFAULT_TABLE = Object.freeze({
  // Conventional (non-IOB_) variables.
  TZ: 'Etc/UTC',
  LANG: 'en_US.UTF-8',
  // ioBroker-specific (IOB_-prefixed) variables.
  IOB_ADMIN_PORT: '8081',
  IOB_WEB_PORT: '8082',
  IOB_STARTUP_GRACE_PERIOD: '300',
  IOB_UPGRADE_TOLERANCE_WINDOW: '600',
  // Max seconds the reconcile heartbeat may go stale before a live reconcile is
  // no longer assumed. Unlike the two windows above this is a STALL bound, not a
  // total-duration bound: a reconcile that keeps advancing its heartbeat is
  // tolerated for any length of time (slow link / slow SD card / many adapters),
  // while a genuinely stuck reconcile is caught once the heartbeat exceeds this.
  IOB_RECONCILE_STALL_TOLERANCE: '120',
});

/**
 * The names of the variables that have a defined default.
 *
 * @type {readonly string[]}
 */
export const DEFAULTED_VARIABLES = Object.freeze(Object.keys(DEFAULT_TABLE));

/**
 * Determine whether a variable is considered "set" in a captured snapshot.
 *
 * A variable is set when the snapshot contains the key with a value that is
 * neither `undefined` nor `null`. An empty string is an explicitly provided
 * value and is therefore treated as set (the operator chose to supply it), so
 * the default is NOT substituted for it.
 *
 * @param {Record<string, unknown>} snapshot - The captured env snapshot.
 * @param {string} name - The variable name to check.
 * @returns {boolean} True if the variable is set in the snapshot.
 */
function isSetInSnapshot(snapshot, name) {
  if (snapshot == null || !Object.prototype.hasOwnProperty.call(snapshot, name)) {
    return false;
  }
  const value = snapshot[name];
  return value !== undefined && value !== null;
}

/**
 * Resolve a single defaulted variable against a captured snapshot.
 *
 * Resolution uses ONLY the snapshot: if the variable is set in the snapshot,
 * its snapshot value is returned; otherwise the encoded default is returned.
 * Variables without a defined default resolve to their snapshot value, or
 * `undefined` when absent from the snapshot.
 *
 * @param {Record<string, unknown>} snapshot - The captured env snapshot.
 * @param {string} name - The variable name to resolve.
 * @param {Record<string, string>} [table] - The default table to use.
 * @returns {string | unknown | undefined} The resolved value.
 */
export function resolveDefault(snapshot, name, table = DEFAULT_TABLE) {
  if (isSetInSnapshot(snapshot, name)) {
    return snapshot[name];
  }
  return Object.prototype.hasOwnProperty.call(table, name) ? table[name] : undefined;
}

/**
 * Resolve the full set of defaulted variables against a captured snapshot.
 *
 * For each variable in the default table, the resolved value is the snapshot
 * value when set, or the encoded default when unset. Only the snapshot is
 * consulted, so any mutation applied to the live environment after the snapshot
 * was captured has no effect on the result.
 *
 * @param {Record<string, unknown>} snapshot - The env snapshot captured at start.
 * @param {Record<string, string>} [table] - The default table to use.
 * @returns {Record<string, string>} A new object mapping every defaulted
 *   variable to its resolved value.
 */
export function resolveDefaults(snapshot, table = DEFAULT_TABLE) {
  const resolved = {};
  for (const name of Object.keys(table)) {
    resolved[name] = resolveDefault(snapshot, name, table);
  }
  return resolved;
}
