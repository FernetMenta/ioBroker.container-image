#!/usr/bin/env bash
# heal-node-modules.sh - reconcile the FULL dependency tree under
# /opt/iobroker/node_modules against /opt/iobroker/package.json.
#
# WHY THIS EXISTS
# ---------------
# node_modules is a persistent volume. Adapter packages depend on shared
# libraries that npm HOISTS to the top level of node_modules (e.g. express,
# @iobroker/adapter-core, http-mitm-proxy, xmlbuilder). If that tree was ever
# left incomplete — most commonly because an earlier `npm install` ran while
# /opt/iobroker/package.json was a reduced subset and PRUNED hoisted packages,
# then a piecemeal reinstall restored the adapters but not every transitive
# dependency — adapters crash at runtime with `Cannot find module '<dep>'`
# (MODULE_NOT_FOUND), even though the adapter's own top-level directory is
# present and looks fine.
#
# Restoring package.json (scripts/persist-package-json.sh) PREVENTS future
# prunes, but it cannot rebuild a tree that is ALREADY incomplete: reconciliation
# sees the top-level adapter dirs present and does nothing, and nobody fills the
# hoisted gaps. This script closes that gap: it runs a single `npm install`
# against the (already-restored, complete) package.json to materialize every
# missing dependency. Because package.json lists the full set, the install
# PRUNES NOTHING; when the tree is already complete it is a fast no-op (npm
# verifies and exits without downloads).
#
# It MUST run in the pre-controller window (before js-controller starts), where
# there is no concurrent writer of package.json/node_modules.
#
# BEST-EFFORT: a failure here (offline registry, partial network) is logged and
# returns 0 so startup is never blocked — the adapters that could not be healed
# simply keep failing to load, which is no worse than before, and a later start
# with connectivity heals them.
#
# Environment:
#   IOB_ROOT              ioBroker install root (default /opt/iobroker)
#   IOB_HEAL_NODE_MODULES set to "false" to skip the self-heal entirely
#   IOB_HEAL_TIMEOUT      max seconds for the npm install (default 1800; 0 = none)
set -u

IOB_ROOT="${IOB_ROOT:-/opt/iobroker}"
IOB_HEAL_NODE_MODULES="${IOB_HEAL_NODE_MODULES:-true}"
IOB_HEAL_TIMEOUT="${IOB_HEAL_TIMEOUT:-1800}"

log() { printf 'heal-node-modules: %s\n' "$*" >&2; }

if [[ "${IOB_HEAL_NODE_MODULES}" == "false" ]]; then
  log "self-heal disabled via IOB_HEAL_NODE_MODULES=false; skipping"
  exit 0
fi

if [[ ! -f "${IOB_ROOT}/package.json" ]]; then
  log "no ${IOB_ROOT}/package.json; skipping self-heal"
  exit 0
fi
if ! command -v npm >/dev/null 2>&1; then
  log "npm not found; skipping self-heal"
  exit 0
fi

log "reconciling node_modules dependency tree against package.json"
log "self-healing in progress - this rebuilds any missing adapter dependencies and MAY TAKE SEVERAL MINUTES on the first run; subsequent starts are fast when the tree is already complete"

# Bound the install so a hung download cannot freeze startup forever.
runner=()
if [[ "${IOB_HEAL_TIMEOUT}" =~ ^[0-9]+$ ]] && [[ "${IOB_HEAL_TIMEOUT}" -gt 0 ]] \
  && command -v timeout >/dev/null 2>&1; then
  runner=(timeout "${IOB_HEAL_TIMEOUT}")
fi

# --omit=dev matches how the image and reconcile install adapters (production
# tree only). unsafe-perm keeps lifecycle scripts runnable when this happens to
# run as root (it normally runs as uid 1000, where it is a no-op). We do NOT
# pass --production/--force: the goal is only to ADD what package.json declares
# but is missing, never to rewrite versions. package.json is already the full
# restored set, so npm prunes nothing.
heal_start="$(date +%s 2>/dev/null || echo 0)"
rc=0
( cd "${IOB_ROOT}" && npm_config_unsafe_perm=true \
    "${runner[@]}" npm install --omit=dev --no-audit --no-fund --loglevel error ) || rc=$?
heal_end="$(date +%s 2>/dev/null || echo 0)"
elapsed=$(( heal_end - heal_start ))
(( elapsed < 0 )) && elapsed=0

if [[ "${rc}" -eq 0 ]]; then
  log "self-heal complete in ${elapsed}s; node_modules dependency tree is consistent with package.json"
elif [[ "${rc}" -eq 124 ]]; then
  log "WARNING self-heal npm install timed out after ${IOB_HEAL_TIMEOUT}s; continuing (adapters missing deps may fail to load; a later start will retry)"
else
  log "WARNING self-heal npm install exited ${rc}; continuing (adapters missing deps may fail to load; a later start will retry)"
fi
exit 0
