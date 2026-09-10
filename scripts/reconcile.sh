#!/usr/bin/env bash
# reconcile.sh - thin shell glue for the reconciliation planner (design §5).
#
# Aligns the installed adapter code (`/opt/iobroker/node_modules`) with the set
# of adapters recorded in the Data_Volume, which is the source of truth
# (Req 8.5). This script performs ONLY the thin, side-effecting parts of
# reconciliation:
#
#   1. observe the environment (is the Data_Volume empty? is node_modules a
#      mount? is the adapter registry reachable? is there a Node ABI mismatch
#      against the persisted native modules?),
#   2. hand those observations to the pure planner `planReconciliation` in
#      `lib/reconcile-plan.js`, and
#   3. execute the ordered actions the planner returns.
#
# All decision logic (which branch to take, what to install, when to warn vs
# rebuild) lives in the pure module so it can be property-tested without a
# container. This mirrors the pattern of `scripts/ensure-npmrc.sh`, which drives
# `lib/npmrc.js` the same way (observe -> plan -> act).
#
# The actions map to the reconciliation flow diagram / pseudocode in design §5:
#   init-default-config  -> `iobroker setup first`      (empty Data_Volume; Req 8.6)
#   install-missing      -> `iobroker add <adapter>...` (install desired adapters
#                                                        not present; Req 8.9/8.10)
#   npm-rebuild          -> `npm rebuild <module>...`   (ABI mismatch;        Req 8.12)
#   warn-and-start       -> log a clear warning and still start               (Req 8.11/8.13)
#
# Reconciliation MUST NEVER fail startup when the persisted modules are usable
# offline (Req 8.11), and MUST warn-and-still-start on an ABI mismatch that
# cannot be rebuilt (Req 8.13). Accordingly this script does not `exit` non-zero
# for those conditions; the planner marks them warn-and-start and the
# entrypoint proceeds to `exec` js-controller afterwards.
#
# Usage:
#   reconcile.sh
#
# Environment overrides (primarily for testing / non-default layouts):
#   IOB_ROOT                ioBroker install root (default /opt/iobroker)
#   IOB_DATA_DIR            Data_Volume dir       (default $IOB_ROOT/iobroker-data)
#   IOB_NODE_MODULES_DIR    node_modules dir      (default $IOB_ROOT/node_modules)
#   IOB_RECONCILE_DRY_RUN   when "true", log the actions instead of running
#                           iobroker/npm (used by tests and diagnostics)
#
# Exit codes:
#   0  reconciliation completed (including the warn-and-start fallback, which is
#      NOT a failure)
#   1  an install/rebuild command the planner required actually failed, or the
#      planner returned an unexpected action
set -euo pipefail

# Resolve this script's directory so we can locate the sibling lib/ module
# regardless of the working directory the entrypoint runs us from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
RECONCILE_MODULE="${REPO_ROOT}/lib/reconcile-plan.js"

IOB_ROOT="${IOB_ROOT:-/opt/iobroker}"
IOB_DATA_DIR="${IOB_DATA_DIR:-${IOB_ROOT}/iobroker-data}"
IOB_NODE_MODULES_DIR="${IOB_NODE_MODULES_DIR:-${IOB_ROOT}/node_modules}"
IOB_RECONCILE_DRY_RUN="${IOB_RECONCILE_DRY_RUN:-false}"

log() { echo "reconcile: $*" >&2; }

# -- Observations (thin, side-effect-free where possible) --------------------

# data_volume_empty: an absent or empty Data_Volume needs default init (Req 8.6).
# "empty" means the directory does not exist, or exists but contains no entries.
data_volume_empty() {
  if [[ ! -d "${IOB_DATA_DIR}" ]]; then
    return 0
  fi
  # `find ... -mindepth 1` prints nothing for an empty dir; use it so we do not
  # depend on `ls` output formatting or hidden-file globbing quirks.
  if [[ -z "$(find "${IOB_DATA_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    return 0
  fi
  return 1
}

# registry_reachable: can we reach the adapter registry to install/repair?
# A reachable registry enables install-missing; otherwise the planner falls back
# to warn-and-start (Req 8.9-8.11).
#
# We probe with `npm` itself, NOT raw curl: npm is the tool that actually
# performs the installs and it ships its own CA bundle, so it succeeds over
# HTTPS even on the slim runtime image. A curl-based probe here gave false
# negatives because the slim image's curl could not verify the registry TLS
# certificate, which made every online start wrongly look offline. `npm ping`
# performs a lightweight registry round-trip and honors the configured registry.
registry_reachable() {
  command -v npm >/dev/null 2>&1 || return 1
  # Short timeouts so an genuinely offline start is not delayed. `npm ping`
  # returns non-zero when the registry cannot be reached.
  npm ping --fetch-timeout=5000 --fetch-retries=0 >/dev/null 2>&1
}

# abi_mismatch: does the running Node ABI differ from what the present native
# modules were built for (Req 8.12)? Only meaningful when an ABI marker exists
# beside node_modules (written by the build/install step). We compare the
# running Node ABI (process.versions.modules) against that marker.
abi_mismatch() {
  local marker="${IOB_NODE_MODULES_DIR}/.node-abi"
  [[ -r "${marker}" ]] || return 1
  local built running
  built="$(cat -- "${marker}" 2>/dev/null | tr -dc '0-9')"
  running="$(node -e 'process.stdout.write(String(process.versions.modules))' 2>/dev/null || true)"
  [[ -n "${built}" && -n "${running}" && "${built}" != "${running}" ]]
}

# desired_adapters: the adapter set RECORDED in the Data_Volume (the source of
# truth; Req 8.5) — i.e. the adapters the Data_Volume says SHOULD be installed,
# regardless of what is physically present in node_modules.
#
# This is derived from the configured adapter INSTANCES in the objects DB
# (`system.adapter.<name>.<n>`), NOT from `iobroker list adapters` (which lists
# what is currently INSTALLED in node_modules — the wrong source, and empty on a
# stripped/fresh image). We list instances and reduce them to the unique set of
# adapter names. Missing data yields an empty set, which the planner handles
# gracefully. The fresh-install bootstrap (installing `admin`) is handled
# separately in the init-default-config action, not here.
desired_adapters() {
  command -v iobroker >/dev/null 2>&1 || return 0
  # `iobroker list instances` prints lines like
  # "system.adapter.admin.0 : ... - enabled". Extract the adapter name that
  # sits between "system.adapter." and the trailing ".<instance>".
  iobroker list instances 2>/dev/null \
    | grep -oE 'system\.adapter\.[a-z0-9_-]+\.[0-9]+' \
    | sed -E 's/^system\.adapter\.([a-z0-9_-]+)\.[0-9]+$/\1/' \
    | sort -u || true
}

# installed_adapters: adapter names currently PRESENT under node_modules,
# observed from directory content (independent of mount state). ioBroker adapter
# packages are published as `iobroker.<name>` directories.
installed_adapters() {
  [[ -d "${IOB_NODE_MODULES_DIR}" ]] || return 0
  find "${IOB_NODE_MODULES_DIR}" -maxdepth 1 -type d -name 'iobroker.*' -printf '%f\n' 2>/dev/null |
    sed 's/^iobroker\.//' || true
}

# native_modules: native modules subject to an ABI rebuild. Names the affected
# modules in the rebuild action / warning (Req 8.12, 8.13).
native_modules() {
  [[ -d "${IOB_NODE_MODULES_DIR}" ]] || return 0
  # Native modules are those shipping prebuilt `.node` binaries; list the
  # top-level package dirs that contain one.
  find "${IOB_NODE_MODULES_DIR}" -maxdepth 3 -name '*.node' -printf '%h\n' 2>/dev/null |
    sed "s#^${IOB_NODE_MODULES_DIR}/##; s#/.*##" | sort -u || true
}

# -- Collect observations -----------------------------------------------------

data_empty=false
registry_ok=false
abi_bad=false

if data_volume_empty; then data_empty=true; fi
if registry_reachable; then registry_ok=true; fi
if abi_mismatch; then abi_bad=true; fi

# Newline-separated lists for the observation snapshot.
desired_list="$(desired_adapters)"
installed_list="$(installed_adapters)"
native_list="$(native_modules)"

# Fresh-install bootstrap: on an empty Data_Volume there are no recorded adapter
# instances yet, so seed the desired set with `admin` (only admin) so a brand-new
# container installs the setup UI. `iobroker setup first` (init-default-config)
# runs first via the plan; the admin install then flows through install-missing.
if [[ "${data_empty}" == "true" ]]; then
  desired_list="$(printf '%s\nadmin\n' "${desired_list}")"
fi

log "observed: dataVolumeEmpty=${data_empty} registryReachable=${registry_ok} abiMismatch=${abi_bad}"

# -- Ask the pure planner for the ordered actions -----------------------------
#
# We pass observations via environment variables to avoid shell-quoting hazards,
# and emit the plan as one action per line: "<action>\t<tab-separated args>".
# For install steps the args are adapter names; for npm-rebuild they are the
# native module names; for warn-and-start the single arg is the reason string.
plan="$(
  IOB_R_DATA_EMPTY="${data_empty}" \
  IOB_R_REGISTRY_OK="${registry_ok}" \
  IOB_R_ABI_BAD="${abi_bad}" \
  IOB_R_DESIRED="${desired_list}" \
  IOB_R_INSTALLED="${installed_list}" \
  IOB_R_NATIVE="${native_list}" \
  node --input-type=module -e "
    import { planReconciliation, RECONCILE_ACTIONS } from '${RECONCILE_MODULE}';
    const lines = (v) => (v ?? '').split('\n').map((s) => s.trim()).filter(Boolean);
    const plan = planReconciliation({
      dataVolumeEmpty: process.env.IOB_R_DATA_EMPTY === 'true',
      registryReachable: process.env.IOB_R_REGISTRY_OK === 'true',
      abiMismatch: process.env.IOB_R_ABI_BAD === 'true',
      rebuildResourcesReachable: process.env.IOB_R_REGISTRY_OK === 'true',
      desiredAdapters: lines(process.env.IOB_R_DESIRED),
      installedAdapters: lines(process.env.IOB_R_INSTALLED),
      nativeModules: lines(process.env.IOB_R_NATIVE),
    });
    for (const step of plan.steps) {
      const args =
        step.action === RECONCILE_ACTIONS.WARN_AND_START
          ? [step.reason ?? '']
          : step.action === RECONCILE_ACTIONS.NPM_REBUILD
            ? (step.modules ?? [])
            : (step.adapters ?? []);
      process.stdout.write(step.action + '\t' + args.join('\t') + '\n');
    }
  "
)"

# -- Execute the ordered actions ----------------------------------------------
#
# In dry-run mode we log the concrete command instead of running it, so tests
# and diagnostics can assert the mapping without a real ioBroker install.
run() {
  if [[ "${IOB_RECONCILE_DRY_RUN}" == "true" ]]; then
    log "[dry-run] $*"
    return 0
  fi
  "$@"
}

# Iterate over the plan lines. Empty plan (no steps) is valid and does nothing.
while IFS=$'\t' read -r action args_rest; do
  [[ -n "${action}" ]] || continue
  # Split the tab-separated remainder back into an array of arguments.
  args=()
  if [[ -n "${args_rest}" ]]; then
    IFS=$'\t' read -r -a args <<<"${args_rest}"
  fi

  case "${action}" in
    init-default-config)
      # Empty Data_Volume: initialize default ioBroker config + state (Req 8.6).
      # The fresh-install `admin` bootstrap is NOT done here; `admin` was seeded
      # into the desired set above, so it is installed by the install-missing
      # step below (when the registry is reachable) — a single install path for
      # both the fresh admin bootstrap and normal adapter convergence.
      log "initializing default ioBroker config and state (empty Data_Volume)"
      run iobroker setup first
      ;;

    install-missing)
      # Registry reachable: install the Data_Volume adapters not already present
      # in node_modules (content-based convergence, Req 8.9/8.10). On a fresh
      # node_modules this is the full desired set (including the bootstrapped
      # admin); on a populated one it is only the difference.
      if [[ ${#args[@]} -eq 0 ]]; then
        log "install-missing: node_modules already has the desired adapter set"
      else
        log "installing missing adapters (${#args[@]}): ${args[*]}"
        for adapter in "${args[@]}"; do
          run iobroker add "${adapter}"
        done
      fi
      ;;

    npm-rebuild)
      # Node ABI mismatch and rebuild resources reachable: rebuild the affected
      # native modules (Req 8.12).
      if [[ ${#args[@]} -eq 0 ]]; then
        log "npm-rebuild: no native modules identified; running full npm rebuild"
        run npm rebuild
      else
        log "npm rebuild of affected native modules (${#args[@]}): ${args[*]}"
        run npm rebuild "${args[@]}"
      fi
      # Refresh the ABI marker to the NOW-running Node ABI. The persisted volume
      # still carries the OLD marker (that is what triggered this rebuild); if we
      # left it stale, every subsequent start would detect the same mismatch and
      # rebuild again. Rewriting it makes the rebuild a one-time cost per Node
      # major upgrade. Skipped in dry-run so tests observe only the rebuild call.
      if [[ "${IOB_RECONCILE_DRY_RUN}" != "true" ]]; then
        if node -e 'process.stdout.write(String(process.versions.modules))' \
            > "${IOB_NODE_MODULES_DIR}/.node-abi" 2>/dev/null; then
          log "updated ABI marker to running Node ABI"
        else
          log "could not update ABI marker (continuing; may rebuild again next start)"
        fi
      fi
      ;;

    warn-and-start)
      # A condition prevents full reconciliation (registry unreachable with no
      # persisted modules, or an unrebuildable ABI mismatch). Log a clear
      # warning naming the reason and STILL start (Req 8.11, 8.13). This is not
      # a failure -> do not exit non-zero.
      reason="${args[0]:-reconciliation incomplete}"
      log "WARNING: ${reason}"
      ;;

    *)
      log "unexpected action from reconciliation planner: '${action}'"
      exit 1
      ;;
  esac
done <<<"${plan}"

log "reconciliation complete; starting Iobroker_Runtime"
exit 0
