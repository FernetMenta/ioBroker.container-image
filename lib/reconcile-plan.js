// Reconciliation decision planner (pure module).
//
// Implements the reconciliation flow from the design document as a PURE
// function: it takes a snapshot of observations and returns a plan describing
// which actions the entrypoint SHOULD perform and the resulting installed
// adapter set — WITHOUT performing any side effects (no npm, no filesystem, no
// network). The real entrypoint (scripts/reconcile.sh) interprets the actions.
//
// The Data_Volume is the source of truth for the desired adapter set (Req 8.5).
// Reconciliation converges the CONTENT of `node_modules` toward that desired
// set. It is CONTENT-BASED, not mount-based: the planner never asks "is
// node_modules a mount?" because mount state is not reliably distinguishable
// across container runtimes (Docker auto-creates an anonymous volume for every
// declared VOLUME, so a `node_modules` VOLUME always looks "mounted" even when
// the operator mounted nothing; Kubernetes ignores image VOLUMEs entirely).
// Instead the planner compares the adapters recorded in the Data_Volume
// (`desiredAdapters`) against the adapters actually present in `node_modules`
// (`installedAdapters`) and installs only the difference. This yields the
// correct result under Docker, Podman and Kubernetes alike (Req 8.9-8.11).
//
// Startup MUST NEVER fail when the registry is unreachable (Req 8.11) or when
// an ABI rebuild cannot be performed (Req 8.13).
//
// Flow: empty-check -> (init) -> converge-install (or warn offline)
//       -> abi-check -> (rebuild | warn) -> done
//
// Requirements: 8.5, 8.6, 8.9, 8.10, 8.11, 8.12, 8.13

/**
 * Reconciliation action identifiers emitted in the plan, in the order the
 * entrypoint would perform them.
 *
 * - `init-default-config`: Data_Volume was empty; initialize default ioBroker
 *   config + state (Req 8.6). The fresh-install `admin` bootstrap is added by
 *   the shell glue to the desired set, so it flows through `install-missing`.
 * - `install-missing`: registry reachable; install the Data_Volume adapters not
 *   already present in `node_modules`. On a fresh/empty `node_modules` this is
 *   the full desired set; on a populated one it is only the difference. This
 *   single content-based action replaces the former mount-based
 *   `install-full-set` / `install-missing` split (Req 8.9, 8.10).
 * - `npm-rebuild`: Node ABI mismatch detected and rebuild resources reachable;
 *   rebuild the affected native modules (Req 8.12).
 * - `warn-and-start`: a condition prevents full reconciliation (registry
 *   unreachable while adapters are still missing, or an ABI mismatch that
 *   cannot be rebuilt); log a warning and still start the runtime (Req 8.11,
 *   8.13).
 *
 * @readonly
 * @enum {string}
 */
export const RECONCILE_ACTIONS = Object.freeze({
  INIT_DEFAULT_CONFIG: 'init-default-config',
  INSTALL_MISSING: 'install-missing',
  NPM_REBUILD: 'npm-rebuild',
  WARN_AND_START: 'warn-and-start',
});

/**
 * @typedef {Object} ReconcileInputs
 * @property {string[]} [desiredAdapters] - Adapter set recorded in the
 *   Data_Volume (the source of truth). Order and duplicates are ignored.
 *   Defaults to an empty set.
 * @property {string[]} [installedAdapters] - Adapter set currently PRESENT in
 *   `node_modules`, observed from its content (independent of mount state).
 *   Defaults to an empty set.
 * @property {boolean} [registryReachable] - Whether the adapter registry is
 *   reachable. Defaults to false.
 * @property {boolean} [dataVolumeEmpty] - Whether the Data_Volume is empty and
 *   needs default initialization. Defaults to false.
 * @property {boolean} [abiMismatch] - Whether the running Node.js ABI differs
 *   from the ABI the present native modules were built for. Defaults to false.
 * @property {boolean} [rebuildResourcesReachable] - Whether the registry / build
 *   resources needed for an `npm rebuild` are reachable. Defaults to false.
 * @property {string[]} [nativeModules] - Names of native modules subject to an
 *   ABI rebuild. Used to name affected modules in the rebuild action / warning.
 *   Defaults to empty.
 */

/**
 * @typedef {Object} ReconcilePlanStep
 * @property {string} action - One of {@link RECONCILE_ACTIONS}.
 * @property {string[]} [adapters] - Adapters this step installs (for
 *   install-missing), sorted.
 * @property {string[]} [modules] - Native modules this step rebuilds (for
 *   npm-rebuild), sorted.
 * @property {string} [reason] - Why a warn-and-start step was emitted.
 */

/**
 * @typedef {Object} ReconcilePlan
 * @property {ReconcilePlanStep[]} steps - Ordered actions to perform.
 * @property {string[]} actions - Ordered action identifiers (convenience view
 *   of `steps`, one entry per step).
 * @property {string[]} installedAdapters - Resulting installed adapter set
 *   after applying the plan, sorted and de-duplicated. This is the
 *   `node_modules` content model the next run would observe.
 * @property {string[]} warnings - Human-readable warnings emitted during
 *   planning (never cause startup to fail).
 * @property {boolean} started - Whether the Iobroker_Runtime is started at the
 *   end of the plan. Always true — reconciliation never fails startup in this
 *   model (Req 8.11, 8.13).
 */

/**
 * Normalize a list into a sorted, de-duplicated array of non-empty strings.
 *
 * @param {unknown} list
 * @returns {string[]}
 */
function toSortedSet(list) {
  if (!Array.isArray(list)) {
    return [];
  }
  const seen = new Set();
  for (const item of list) {
    if (typeof item === 'string' && item.length > 0) {
      seen.add(item);
    }
  }
  return [...seen].sort();
}

/**
 * Produce a reconciliation plan from a snapshot of observations.
 *
 * The function is pure and idempotent: given the same inputs it always returns
 * the same plan, and feeding the resulting `installedAdapters` back in as the
 * next run's `installedAdapters` converges to the same set and yields no
 * further install work (an empty `install-missing`).
 *
 * @param {ReconcileInputs} [inputs]
 * @returns {ReconcilePlan}
 */
export function planReconciliation(inputs = {}) {
  const {
    registryReachable = false,
    dataVolumeEmpty = false,
    abiMismatch = false,
    rebuildResourcesReachable = false,
  } = inputs;

  const desired = toSortedSet(inputs.desiredAdapters);
  // Content-based: whatever is actually present in node_modules right now,
  // independent of whether that directory is a mount.
  const present = toSortedSet(inputs.installedAdapters);
  const nativeModules = toSortedSet(inputs.nativeModules);

  /** @type {ReconcilePlanStep[]} */
  const steps = [];
  /** @type {string[]} */
  const warnings = [];

  // 1. Empty Data_Volume -> initialize default config + state (Req 8.6).
  if (dataVolumeEmpty) {
    steps.push({ action: RECONCILE_ACTIONS.INIT_DEFAULT_CONFIG });
  }

  // 2. Converge node_modules content toward the desired set.
  const presentSet = new Set(present);
  const missing = desired.filter((a) => !presentSet.has(a));

  let installed;
  if (missing.length === 0) {
    // Already converged: everything recorded is present (or nothing recorded).
    // No install work, no warning — start with what's present.
    installed = present;
  } else if (registryReachable) {
    // Install only the missing desired adapters (Req 8.9, 8.10). On a fresh
    // node_modules `missing` == the full desired set; on a populated one it is
    // just the difference.
    steps.push({ action: RECONCILE_ACTIONS.INSTALL_MISSING, adapters: missing });
    installed = toSortedSet([...present, ...missing]);
  } else {
    // Registry unreachable and adapters are still missing: cannot fetch them
    // offline. Warn and start with whatever is present; never fail startup
    // (Req 8.11).
    const reason =
      'registry unreachable; ' +
      `cannot install missing adapters (${missing.join(', ')}); ` +
      'starting with adapters currently present';
    steps.push({ action: RECONCILE_ACTIONS.WARN_AND_START, reason, adapters: missing });
    warnings.push(reason);
    installed = present;
  }

  // 3. ABI check -> rebuild or warn-and-start (Req 8.12, 8.13).
  if (abiMismatch) {
    if (rebuildResourcesReachable) {
      steps.push({ action: RECONCILE_ACTIONS.NPM_REBUILD, modules: nativeModules });
    } else {
      const affected = nativeModules.length > 0 ? nativeModules.join(', ') : 'native modules';
      const reason = `ABI mismatch; cannot rebuild ${affected}: rebuild resources unreachable; starting anyway`;
      steps.push({ action: RECONCILE_ACTIONS.WARN_AND_START, reason, modules: nativeModules });
      warnings.push(reason);
    }
  }

  return {
    steps,
    actions: steps.map((s) => s.action),
    installedAdapters: installed,
    warnings,
    // Reconciliation never fails startup in this model (Req 8.11, 8.13).
    started: true,
  };
}
