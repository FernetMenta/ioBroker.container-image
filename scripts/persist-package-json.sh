#!/usr/bin/env bash
# persist-package-json.sh - keep /opt/iobroker/package.json alive across a
# container RECREATE by mirroring it into the persistent node_modules volume.
#
# THE PROBLEM
# -----------
# node_modules is a persistent VOLUME; package.json is NOT — it lives in the
# image/container layer. js-controller and adapters (e.g. the javascript adapter
# installing script modules) grow package.json's dependency list at runtime to
# match the installed adapter set.
#
#   * `docker restart` reuses the same writable layer, so the grown package.json
#     survives and stays in sync with the node_modules volume -> no issue.
#   * `docker compose up` / recreate starts a FRESH layer, resetting package.json
#     to the image baseline (only iobroker.js-controller) while the node_modules
#     volume still holds every adapter. They are now OUT OF SYNC: the next
#     `npm install` (reconcile OR a runtime adapter install) treats every adapter
#     as EXTRANEOUS and PRUNES it, collapsing node_modules and forcing a full
#     reinstall. This is why the breakage appears only after a RECREATE, never
#     after a restart.
#
# THE FIX
# -------
# Keep an authoritative copy of package.json INSIDE the persistent node_modules
# volume as a DOTFILE (`.iob-package.json`, never mistaken for a package) and:
#
#   restore : on start, BEFORE any npm/reconcile runs, copy the persisted file
#             over /opt/iobroker/package.json so it matches the node_modules the
#             volume actually carries -> no npm invocation prunes the adapters.
#             If no persisted copy exists yet (first start with this volume),
#             SEED it from the current package.json instead.
#   save    : after the install phase, refresh the persisted copy from the live
#             package.json so this start's (re)installs are captured for the next
#             recreate.
#
# A dotfile + COPY (not a symlink) is deliberate: npm/js-controller write
# package.json atomically (write temp + rename), which would silently replace a
# symlink with a regular file and break persistence.
#
# All operations are BEST-EFFORT: failures are logged and exit 0 so package.json
# upkeep never blocks startup (worst case is the pre-fix behavior, which
# reconcile's completeness check still recovers).
#
# Usage:  persist-package-json.sh restore|save
#
# Environment:
#   IOB_ROOT              ioBroker install root (default /opt/iobroker)
#   IOB_NODE_MODULES_DIR  node_modules dir     (default $IOB_ROOT/node_modules)
#   IOB_PKG_JSON          package.json path    (default $IOB_ROOT/package.json)
#   IOB_PKG_JSON_PERSIST  persisted copy path  (default $IOB_NODE_MODULES_DIR/.iob-package.json)
set -u

IOB_ROOT="${IOB_ROOT:-/opt/iobroker}"
IOB_NODE_MODULES_DIR="${IOB_NODE_MODULES_DIR:-${IOB_ROOT}/node_modules}"
IOB_PKG_JSON="${IOB_PKG_JSON:-${IOB_ROOT}/package.json}"
IOB_PKG_JSON_PERSIST="${IOB_PKG_JSON_PERSIST:-${IOB_NODE_MODULES_DIR}/.iob-package.json}"

log() { printf 'persist-package-json: %s\n' "$*"; }

do_restore() {
  [[ -d "${IOB_NODE_MODULES_DIR}" ]] || { log "node_modules dir ${IOB_NODE_MODULES_DIR} absent; nothing to restore"; return 0; }
  if [[ -f "${IOB_PKG_JSON_PERSIST}" ]]; then
    if cp -f -- "${IOB_PKG_JSON_PERSIST}" "${IOB_PKG_JSON}" 2>/dev/null; then
      log "restored package.json from ${IOB_PKG_JSON_PERSIST} (keeps node_modules in sync across recreate; prevents npm prune)"
    else
      log "WARNING could not restore package.json from ${IOB_PKG_JSON_PERSIST}; an install-time npm prune may occur (reconcile will recover)"
    fi
  elif [[ -f "${IOB_PKG_JSON}" ]]; then
    if cp -f -- "${IOB_PKG_JSON}" "${IOB_PKG_JSON_PERSIST}" 2>/dev/null; then
      log "seeded ${IOB_PKG_JSON_PERSIST} from current package.json (first start; will survive future recreates)"
    else
      log "WARNING could not seed ${IOB_PKG_JSON_PERSIST} (continuing)"
    fi
  else
    log "no package.json at ${IOB_PKG_JSON} and no persisted copy; nothing to do"
  fi
  return 0
}

do_save() {
  [[ -d "${IOB_NODE_MODULES_DIR}" ]] || return 0
  [[ -f "${IOB_PKG_JSON}" ]] || { log "no package.json at ${IOB_PKG_JSON} to save"; return 0; }
  if cp -f -- "${IOB_PKG_JSON}" "${IOB_PKG_JSON_PERSIST}" 2>/dev/null; then
    log "saved package.json to ${IOB_PKG_JSON_PERSIST} for recreate persistence"
  else
    log "WARNING could not save package.json to ${IOB_PKG_JSON_PERSIST} (continuing)"
  fi
  return 0
}

case "${1:-}" in
  restore) do_restore ;;
  save) do_save ;;
  *)
    printf 'usage: %s restore|save\n' "${0##*/}" >&2
    exit 2
    ;;
esac
exit 0
