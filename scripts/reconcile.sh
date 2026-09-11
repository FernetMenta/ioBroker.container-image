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
#   init-default-config  -> `iobroker setup first`          (empty Data_Volume; Req 8.6)
#   install-missing      -> `iobroker install <adapter>...` (install desired adapter
#                                                            CODE not present, without
#                                                            creating instances; Req 8.9/8.10)
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
#   IOB_HOSTNAME            this host's ioBroker name used to filter which
#                           adapters (by instance host assignment) are installed
#                           here (default: the container hostname)
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

# IOB_RECONCILE_PHASE selects which part of the plan to execute, so the
# entrypoint can split reconciliation around database configuration:
#   * "init"    run ONLY the init-default-config action (create iobroker.json +
#               local DB on an empty Data_Volume). This must happen BEFORE
#               configure-db patches iobroker.json to point at a multihost
#               master, because there must be a file to patch.
#   * "install" run everything EXCEPT init-default-config (desired-adapter query,
#               install-missing, npm-rebuild, warn-and-start). This runs AFTER
#               configure-db so the desired-adapter query (`iobroker list
#               instances`) reads the master's shared objects DB when configured,
#               not the throwaway local one.
#   * "all"     (default) run the whole plan in one pass — standalone behavior,
#               unchanged, and what tests exercise unless they override it.
IOB_RECONCILE_PHASE="${IOB_RECONCILE_PHASE:-all}"

# Reconcile liveness markers consumed by scripts/healthcheck.sh + lib/health-state.js.
# The entrypoint runs reconciliation BEFORE js-controller starts, so `iobroker
# status` fails for the whole reconcile phase. That phase has no meaningful upper
# time bound (slow link / slow SD card / many adapters), so instead of a fixed
# grace we publish a liveness signal the healthcheck can bound by STALL:
#   * IOB_RECONCILE_MARKER   present => a reconcile is in progress.
#   * IOB_RECONCILE_HEARTBEAT its mtime is advanced around every executed step;
#     while its age stays under Reconcile_Stall_Tolerance the healthcheck treats
#     reconcile as alive and tolerates the failing status check, for any total
#     duration. If the heartbeat goes stale, reconcile is stuck and the check
#     stops being tolerated.
# Both live in the Data_Volume (same dir the healthcheck defaults to) and are
# overridable for tests.
IOB_RECONCILE_MARKER="${IOB_RECONCILE_MARKER:-${IOB_DATA_DIR}/.iob-reconciling}"
IOB_RECONCILE_HEARTBEAT="${IOB_RECONCILE_HEARTBEAT:-${IOB_DATA_DIR}/.iob-reconcile-heartbeat}"

log() { echo "reconcile: $*" >&2; }

# -- Reconcile liveness signalling -------------------------------------------

# heartbeat: advance the heartbeat file's mtime to "now". Best-effort — a
# non-writable Data_Volume must not abort reconciliation, it just means the
# healthcheck falls back to the other tolerance conditions. Creates the file on
# first call and touches it thereafter.
heartbeat() {
  : >>"${IOB_RECONCILE_HEARTBEAT}" 2>/dev/null || return 0
  touch -- "${IOB_RECONCILE_HEARTBEAT}" 2>/dev/null || true
}

# begin_reconcile: mark reconcile in progress and lay down an initial heartbeat.
begin_reconcile() {
  : >>"${IOB_RECONCILE_MARKER}" 2>/dev/null || \
    log "could not create reconcile marker ${IOB_RECONCILE_MARKER} (healthcheck will rely on other tolerance windows)"
  heartbeat
}

# end_reconcile: remove the in-progress marker and the heartbeat. Registered on
# EXIT so the markers are cleared whether reconciliation succeeds, fails, or the
# script is interrupted — a leftover marker must never make a dead reconcile
# look alive.
end_reconcile() {
  rm -f -- "${IOB_RECONCILE_MARKER}" "${IOB_RECONCILE_HEARTBEAT}" 2>/dev/null || true
}
trap end_reconcile EXIT

begin_reconcile

# -- Observations (thin, side-effect-free where possible) --------------------

# data_volume_empty: an absent or empty Data_Volume needs default init (Req 8.6).
# "empty" means the directory does not exist, or exists but contains no entries.
data_volume_empty() {
  if [[ ! -d "${IOB_DATA_DIR}" ]]; then
    return 0
  fi
  # `find ... -mindepth 1` prints nothing for an empty dir; use it so we do not
  # depend on `ls` output formatting or hidden-file globbing quirks.
  #
  # Exclude our OWN reconcile liveness markers (.iob-reconciling /
  # .iob-reconcile-heartbeat): begin_reconcile writes them into IOB_DATA_DIR
  # BEFORE this check runs, so counting them would make a genuinely fresh volume
  # look non-empty and skip `iobroker setup first`. We match on the marker file
  # names so the check reflects real ioBroker content only.
  local marker_name heartbeat_name
  marker_name="$(basename -- "${IOB_RECONCILE_MARKER}")"
  heartbeat_name="$(basename -- "${IOB_RECONCILE_HEARTBEAT}")"
  if [[ -z "$(find "${IOB_DATA_DIR}" -mindepth 1 \
    ! -name "${marker_name}" ! -name "${heartbeat_name}" \
    -print -quit 2>/dev/null)" ]]; then
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
# truth; Req 8.5) that must have CODE present ON THIS HOST — i.e. the adapters
# the Data_Volume says SHOULD be installed here, regardless of what is
# physically present in node_modules.
#
# This is derived from the configured adapter INSTANCES in the objects DB
# (`system.adapter.<name>.<n>`), NOT from `iobroker list adapters` (which lists
# what is currently INSTALLED in node_modules — the wrong source, and empty on a
# stripped/fresh image).
#
# MULTIHOST HOST FILTER: `iobroker list instances` lists instances for EVERY
# host in the cluster, and prints the host each instance is assigned to. Adapter
# CODE only needs to be present on the host that actually RUNS the instance, so
# on a multihost slave we install only the adapters whose instances are assigned
# to THIS host — not the whole cluster's adapter set. Without this filter a
# slave would pointlessly install code for every adapter running on the master.
# In a standalone install every instance is assigned to this host, so the filter
# is a no-op there.
#
# This host's ioBroker name is its hostname (ioBroker registers the host under
# the container hostname; e.g. `iobroker-sml`). Overridable via IOB_HOSTNAME for
# testing / non-default layouts.
#
# Output format of `iobroker list instances` (columns separated by " : "):
#   <flag> system.adapter.<name>.<n> : <name> : <host>  -  <status...>
# The <status> tail (after " - ") can itself contain colons (e.g. "port: 8081"),
# so we split on " : " for the three stable columns and strip the " - <status>"
# tail off the host column. Missing data yields an empty set, which the planner
# handles gracefully. The fresh-install bootstrap (installing `admin`) is handled
# separately by the shell glue, not here.
desired_adapters() {
  command -v iobroker >/dev/null 2>&1 || return 0
  local this_host="${IOB_HOSTNAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)}"
  # If we somehow cannot determine our host name, fall back to the unfiltered
  # set rather than installing nothing.
  iobroker list instances 2>/dev/null \
    | awk -F' : ' -v this_host="${this_host}" '
        /system\.adapter\./ {
          name = $2; gsub(/^[ \t]+|[ \t]+$/, "", name)
          host = $3; sub(/[ \t]+-.*$/, "", host); gsub(/^[ \t]+|[ \t]+$/, "", host)
          if (name == "") next
          # No host column parsed, or no known host to match against: do not
          # drop the adapter (keeps standalone / unexpected formats working).
          if (host == "" || this_host == "") { print name; next }
          if (host == this_host) print name
        }
      ' \
    | sort -u || true
}

# adapter_install_source: the recorded install SOURCE for an adapter, i.e. the
# exact npm-url / package spec js-controller installed it from. ioBroker writes
# this into each adapter's io-package.json as `common.installedFrom` when it
# installs (see js-controller setupInstall), and it is mirrored on the adapter
# object `system.adapter.<name>` in the objects DB. We need it because an
# adapter may have been installed from OUTSIDE the standard repository (a GitHub
# tarball, a custom URL, an npm spec, a beta/latest repo). For those,
# `iobroker install <name>` fails with "Unknown packet name <name>" — they must
# be (re)installed via `iobroker url <source>`. The desired set is derived from
# the objects DB, so we read the source from the DB object (present even when
# the adapter code is NOT yet in node_modules — exactly the case we install for)
# and fall back to a locally-present io-package.json.
#
# Prints the raw installedFrom string (may be empty) for one adapter name.
adapter_install_source() {
  local name="$1"
  [[ -n "${name}" ]] || return 0

  # Preferred: the objects DB, which knows the source even for not-yet-installed
  # adapters. `iobroker object get` prints the object JSON on stdout.
  if command -v iobroker >/dev/null 2>&1; then
    local obj
    obj="$(iobroker object get "system.adapter.${name}" 2>/dev/null || true)"
    if [[ -n "${obj}" ]]; then
      local from
      from="$(printf '%s' "${obj}" | IOB_ADAPTER_NAME="${name}" node --input-type=module -e '
        let s = "";
        process.stdin.on("data", (d) => (s += d)).on("end", () => {
          try {
            const o = JSON.parse(s);
            const v = o && o.common && o.common.installedFrom;
            process.stdout.write(typeof v === "string" ? v : "");
          } catch { process.stdout.write(""); }
        });
      ' 2>/dev/null || true)"
      if [[ -n "${from}" ]]; then
        printf '%s' "${from}"
        return 0
      fi
    fi
  fi

  # Fallback: a locally-present io-package.json (adapter already in node_modules).
  local iopack="${IOB_NODE_MODULES_DIR}/iobroker.${name}/io-package.json"
  if [[ -r "${iopack}" ]]; then
    IOB_IOPACK_PATH="${iopack}" node --input-type=module -e '
      import { readFileSync } from "node:fs";
      try {
        const o = JSON.parse(readFileSync(process.env.IOB_IOPACK_PATH, "utf8"));
        const v = o && o.common && o.common.installedFrom;
        process.stdout.write(typeof v === "string" ? v : "");
      } catch { process.stdout.write(""); }
    ' 2>/dev/null || true
  fi
}

# source_is_url: decide whether an install source must go through `iobroker url`
# (non-repo source) rather than `iobroker install <name>` (repo by name).
#
# `common.installedFrom` is the npm install spec js-controller used. For a plain
# repo install it is either absent or a bare/registry form like
# `iobroker.<name>` or `iobroker.<name>@1.2.3`. For a non-repo install it is a
# URL or a spec npm would fetch from outside the configured repository:
#   * http(s):// or git+... or git://       (tarball / git)
#   * contains "/tarball/" or looks like "owner/repo" or "owner/repo#ref" (GitHub)
#   * a filesystem path (/... or file:)      (local install)
# Anything else (empty, or a bare iobroker.<name>[@version]) is treated as a
# normal repo adapter and installed by name.
source_is_url() {
  local src="$1"
  [[ -n "${src}" ]] || return 1
  case "${src}" in
    http://* | https://* | git+* | git://* | file:* | /*) return 0 ;;
    *iobroker.*@* | iobroker.* ) return 1 ;; # bare repo spec (with/without @ver)
    */*) return 0 ;;                          # owner/repo (GitHub shorthand)
    *) return 1 ;;
  esac
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
  # Advance the liveness heartbeat immediately before AND after each executed
  # command. The before-touch resets the stall clock so a long-but-alive command
  # (a slow `iobroker add` / `npm rebuild`) does not look stalled while it runs;
  # the after-touch records that the step made progress. This is the coarse,
  # per-step liveness signal (no per-command output watchdog by design).
  heartbeat
  if [[ "${IOB_RECONCILE_DRY_RUN}" == "true" ]]; then
    log "[dry-run] $*"
    heartbeat
    return 0
  fi
  # Capture the command's exit status without letting `set -e` abort here: the
  # callers decide how to react to a failure (the planner's required install/
  # rebuild steps are invoked bare so their failure still propagates), and we
  # want the after-touch to run regardless. `|| rc=$?` keeps the pipeline's
  # status in `rc` while neutralising set -e for this one line.
  local rc=0
  "$@" || rc=$?
  heartbeat
  return "${rc}"
}

# run_install: like `run`, but retries specifically on the jsonl DB-file LOCK
# race that occurs during the pre-controller install phase.
#
# Why this is needed: on a multihost master the objects/states DB host is
# 0.0.0.0 (network mode). js-controller is NOT running yet during reconcile, so
# every `iobroker install`/`iobroker url` invocation stands up its OWN transient
# in-memory jsonl server that opens and file-LOCKS objects.jsonl / states.jsonl
# for the duration of that one CLI call, then releases the lock as the process
# exits. Because that release is not perfectly synchronous with process exit
# (the server shuts down slightly after the CLI returns), the NEXT sequential
# install can start and try to lock the same file while the previous server is
# still tearing down, and fail with:
#     Server Cannot start inMem-objects on port 9001: Failed to lock DB file "...objects.jsonl"!
# This is a timing race, not a genuine failure — the file is simply held for a
# few more milliseconds. A remote slave that continuously reconnects to the
# master's DB port keeps those transient servers alive a little longer, widening
# the window (which is why it tends to strike only after several successful
# installs). We absorb it by retrying the SAME command a few times with a short
# backoff when — and only when — the output shows the lock error. Any other
# failure returns immediately so real errors still surface to the caller.
#
# Captures combined output so it can both inspect it AND surface it to the log.
IOB_INSTALL_LOCK_RETRIES="${IOB_INSTALL_LOCK_RETRIES:-6}"
IOB_INSTALL_LOCK_BACKOFF="${IOB_INSTALL_LOCK_BACKOFF:-2}"
run_install() {
  if [[ "${IOB_RECONCILE_DRY_RUN}" == "true" ]]; then
    heartbeat
    log "[dry-run] $*"
    heartbeat
    return 0
  fi

  local attempt=1 rc=0 out
  while :; do
    heartbeat
    rc=0
    out="$("$@" 2>&1)" || rc=$?
    # Always echo the tool's own output so `docker logs` keeps its detail.
    [[ -n "${out}" ]] && printf '%s\n' "${out}" >&2
    heartbeat

    if [[ "${rc}" -eq 0 ]]; then
      return 0
    fi

    # Retry ONLY the DB-file lock race; everything else is a real failure.
    if printf '%s' "${out}" | grep -qiE 'Failed to lock DB file|Cannot start inMem-(objects|states)'; then
      if [[ "${attempt}" -lt "${IOB_INSTALL_LOCK_RETRIES}" ]]; then
        log "  DB file lock busy (attempt ${attempt}/${IOB_INSTALL_LOCK_RETRIES}); retrying in ${IOB_INSTALL_LOCK_BACKOFF}s"
        sleep "${IOB_INSTALL_LOCK_BACKOFF}"
        attempt=$((attempt + 1))
        continue
      fi
      log "  DB file lock still busy after ${IOB_INSTALL_LOCK_RETRIES} attempts; giving up on this command"
    fi
    return "${rc}"
  done
}

# Iterate over the plan lines. Empty plan (no steps) is valid and does nothing.
while IFS=$'\t' read -r action args_rest; do
  [[ -n "${action}" ]] || continue
  # Mark progress at the start of every plan step so the heartbeat advances even
  # for steps that do not go through run() (e.g. a pure log line).
  heartbeat
  # Split the tab-separated remainder back into an array of arguments.
  args=()
  if [[ -n "${args_rest}" ]]; then
    IFS=$'\t' read -r -a args <<<"${args_rest}"
  fi

  # Phase gating: the entrypoint may run reconciliation in two passes around
  # database configuration (see IOB_RECONCILE_PHASE above). "init" performs only
  # the init-default-config action; "install" performs everything else; "all"
  # (default) performs the whole plan. Skipping is silent so the two-pass log
  # stays clean.
  case "${IOB_RECONCILE_PHASE}" in
    init)
      [[ "${action}" == "init-default-config" ]] || continue
      ;;
    install)
      [[ "${action}" != "init-default-config" ]] || continue
      ;;
    all) : ;;
    *)
      log "unknown IOB_RECONCILE_PHASE='${IOB_RECONCILE_PHASE}'; treating as 'all'"
      ;;
  esac

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
        install_failures=()
        for adapter in "${args[@]}"; do
          # Choose the install COMMAND based on where the adapter was originally
          # installed FROM (common.installedFrom, recorded in the objects DB):
          #
          #   * repo adapter (bare/empty source) -> `iobroker install <name>`
          #     installs ONLY the adapter code from the configured repository; it
          #     does NOT create an instance. That is exactly what reconciliation
          #     needs: the desired set is derived from the instances already
          #     recorded in the Data_Volume (the source of truth), so the
          #     instances exist already and our job is purely to converge
          #     node_modules to match. (Using `iobroker add` would instead try to
          #     CREATE an instance, duplicating it and hard-failing for singleton
          #     adapters, e.g. on a multihost slave sharing the master's DB.)
          #
          #   * non-repo adapter (GitHub tarball, custom URL, npm spec, a package
          #     not in the active repo) -> `iobroker url <source>`. These CANNOT
          #     be installed by name: `iobroker install <name>` fails with
          #     "Unknown packet name <name>. Please install ... using iobroker
          #     url". We reinstall the code from the SAME source the operator
          #     originally used, so a container recreate faithfully rebuilds the
          #     recorded adapter set regardless of where each adapter came from.
          #     `iobroker url` likewise installs code without creating instances.
          src="$(adapter_install_source "${adapter}")"
          if source_is_url "${src}"; then
            log "  ${adapter}: installing from recorded source: ${src}"
            if ! run_install iobroker url "${src}"; then
              install_failures+=("${adapter} (url: ${src})")
            fi
          else
            [[ -n "${src}" ]] && log "  ${adapter}: repo install (source: ${src})" \
              || log "  ${adapter}: repo install"
            if ! run_install iobroker install "${adapter}"; then
              install_failures+=("${adapter}")
            fi
          fi
        done

        # A single adapter that cannot be (re)installed MUST NOT abort startup.
        # The recorded source may be transiently unreachable (a GitHub outage), a
        # deleted/renamed package, or a private repo. Warn, name the offenders,
        # and start with the adapters that DID install — js-controller simply
        # reports the missing ones as failing instances, which is far better than
        # refusing to start the whole host over one adapter. (Consistent with the
        # warn-and-start policy for offline reconciliation, Req 8.11/8.13.)
        if [[ ${#install_failures[@]} -gt 0 ]]; then
          log "WARNING: ${#install_failures[@]} adapter(s) could not be installed and will be skipped: ${install_failures[*]}"
        fi
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
